using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Owns one water <see cref="MeshInstance3D"/> per chunk. Each frame it applies
/// finished async builds and dispatches new ones for dirty chunks (budgeted),
/// captures a 1-cell-border snapshot on the main thread, builds off-thread, and
/// applies on the main thread. Orphan meshes (chunks the field evicted) are freed.
/// </summary>
public sealed class WaterRenderer
{
    private readonly Node3D _root;
    private readonly WaterField _field;
    private readonly IVoxelWorld _world;
    private readonly Func<WaterSettings> _settings;
    private Material _material;

    private sealed class Vis { public MeshInstance3D Mi; }

    private readonly Dictionary<Vector3I, Vis> _vis = new();
    private readonly Dictionary<Vector3I, Task<WaterMeshData>> _building = new();
    private readonly List<Vector3I> _tmp = new();

    public int VisibleChunks => _vis.Count;
    public int Building => _building.Count;

    public WaterRenderer(Node3D root, WaterField field, IVoxelWorld world,
        Func<WaterSettings> settings, Material material)
    {
        _root = root; _field = field; _world = world; _settings = settings; _material = material;
    }

    public void SetMaterial(Material m)
    {
        _material = m;
        foreach (var v in _vis.Values) v.Mi.MaterialOverride = m;
    }

    public void Update()
    {
        // 1) apply finished builds
        if (_building.Count > 0)
        {
            _tmp.Clear();
            foreach (var kv in _building) if (kv.Value.IsCompleted) _tmp.Add(kv.Key);
            foreach (var cc in _tmp)
            {
                var task = _building[cc];
                _building.Remove(cc);
                if (_field.Chunks.ContainsKey(cc)) ApplyMesh(cc, task.Result); // drop stale builds for evicted chunks
            }
        }

        // 2) dispatch dirty chunks (budgeted)
        int budget = Mathf.Max(1, _settings().MaxRemeshPerFrame);
        int dispatched = 0;
        foreach (var kv in _field.Chunks)
        {
            if (dispatched >= budget) break;
            var ch = kv.Value;
            if (!ch.MeshDirty || _building.ContainsKey(ch.Coord)) continue;
            ch.MeshDirty = false;
            var inp = Capture(ch.Coord);
            _building[ch.Coord] = Task.Run(() => WaterMeshBuilder.Build(inp));
            dispatched++;
        }

        // 3) free orphan meshes (chunk no longer in the field)
        if (_vis.Count > 0)
        {
            _tmp.Clear();
            foreach (var cc in _vis.Keys) if (!_field.Chunks.ContainsKey(cc)) _tmp.Add(cc);
            foreach (var cc in _tmp) { _vis[cc].Mi.QueueFree(); _vis.Remove(cc); }
        }
    }

    private WaterMeshInput Capture(Vector3I cc)
    {
        var inp = new WaterMeshInput { Coord = cc };
        int bx = cc.X * 16, by = cc.Y * 16, bz = cc.Z * 16;
        for (int y = -1; y <= 16; y++)
        for (int z = -1; z <= 16; z++)
        for (int x = -1; x <= 16; x++)
        {
            int wx = bx + x, wy = by + y, wz = bz + z;
            int i = WaterMeshInput.PIdx(x, y, z);
            inp.Cells[i] = _field.GetCell(wx, wy, wz);
            inp.Solid[i] = _world.IsSolid(wx, wy, wz);
            inp.Class[i] = _field.GetClass(wx, wy, wz);
        }
        return inp;
    }

    private void ApplyMesh(Vector3I cc, WaterMeshData md)
    {
        if (md == null || md.Empty)
        {
            if (_vis.TryGetValue(cc, out var v0)) v0.Mi.Mesh = null;
            return;
        }
        if (!_vis.TryGetValue(cc, out var v))
        {
            v = new Vis
            {
                Mi = new MeshInstance3D
                {
                    Position = new Vector3(cc.X * 16, cc.Y * 16, cc.Z * 16),
                    MaterialOverride = _material,
                }
            };
            _root.AddChild(v.Mi);
            _vis[cc] = v;
        }
        v.Mi.Mesh = ToMesh(md);
    }

    private static ArrayMesh ToMesh(WaterMeshData md)
    {
        var arrays = new Godot.Collections.Array();
        arrays.Resize((int)Mesh.ArrayType.Max);
        arrays[(int)Mesh.ArrayType.Vertex] = md.Verts.ToArray();
        arrays[(int)Mesh.ArrayType.Normal] = md.Normals.ToArray();
        arrays[(int)Mesh.ArrayType.TexUV] = md.UVs.ToArray();
        arrays[(int)Mesh.ArrayType.Color] = md.Colors.ToArray();
        arrays[(int)Mesh.ArrayType.Index] = md.Indices.ToArray();

        var mesh = new ArrayMesh();
        mesh.AddSurfaceFromArrays(Mesh.PrimitiveType.Triangles, arrays);
        return mesh;
    }
}
