using System;
using System.Collections.Generic;
using Godot;

namespace Sandbox.Water;

/// <summary>
/// Minimal voxel world for the demo harness. 16³ chunks of <c>ushort[4096]</c>
/// in a sparse dictionary, host-identical indexing <c>(y*16+z)*16+x</c>, a
/// <c>BlockChanged</c> event, and per-chunk opaque/transparent meshes. This is
/// the analogue of ra-engine's VoxelWorld for our purposes — deliberately tiny
/// and NOT ported. The water module never touches this directly; it talks to
/// <see cref="SandboxVoxelWorldAdapter"/> which implements the portable seam.
/// </summary>
public partial class SandboxWorld : Node3D
{
    public const int CS = 16;          // chunk size
    public const int CV = CS * CS * CS; // 4096

    /// <summary>(pos, oldId, newId, cause) — raised for every edit.</summary>
    public event Action<Vector3I, ushort, ushort, int> BlockChanged;

    private sealed class Chunk
    {
        public Vector3I Coord;
        public ushort[] Blocks = new ushort[CV];
        public int SolidCount;
        public MeshInstance3D Opaque;
        public MeshInstance3D Trans;
        public StaticBody3D Body;
        public CollisionShape3D Col;
    }

    private readonly Dictionary<Vector3I, Chunk> _chunks = new();
    private readonly HashSet<Vector3I> _dirty = new();

    private StandardMaterial3D _opaqueMat;
    private StandardMaterial3D _glassMat;

    public override void _Ready()
    {
        _opaqueMat = new StandardMaterial3D
        {
            VertexColorUseAsAlbedo = true,
            // Sandbox scenery is throwaway: render double-sided so the quads are
            // visible regardless of winding (the real water mesher in M5 is
            // winding-correct). No interior faces are emitted, so this looks
            // identical to single-sided from the outside.
            CullMode = BaseMaterial3D.CullModeEnum.Disabled,
            Roughness = 0.95f,
        };
        _glassMat = new StandardMaterial3D
        {
            VertexColorUseAsAlbedo = true,
            Transparency = BaseMaterial3D.TransparencyEnum.Alpha,
            CullMode = BaseMaterial3D.CullModeEnum.Disabled,
            Roughness = 0.1f,
            Metallic = 0.0f,
        };
    }

    // ---- coordinate helpers (host-identical) ----
    public static Vector3I ChunkOf(int x, int y, int z) => new(x >> 4, y >> 4, z >> 4);
    public static int Index(int lx, int ly, int lz) => (ly * CS + lz) * CS + lx;

    // ---- reads ----
    public ushort GetBlockId(int x, int y, int z)
        => _chunks.TryGetValue(ChunkOf(x, y, z), out var c) ? c.Blocks[Index(x & 15, y & 15, z & 15)] : (ushort)0;

    public bool IsSolid(int x, int y, int z) => SandboxBlocks.IsSolid(GetBlockId(x, y, z));
    public bool IsOpaque(int x, int y, int z) => SandboxBlocks.IsOpaque(GetBlockId(x, y, z));
    public bool IsAir(int x, int y, int z) => GetBlockId(x, y, z) == 0;

    // ---- writes ----
    public void SetBlock(int x, int y, int z, ushort id, bool remesh = true, int cause = 0)
    {
        var cc = ChunkOf(x, y, z);
        var c = GetOrCreate(cc);
        int i = Index(x & 15, y & 15, z & 15);
        ushort old = c.Blocks[i];
        if (old == id) return;
        c.Blocks[i] = id;
        if (old == 0 && id != 0) c.SolidCount++;
        else if (old != 0 && id == 0) c.SolidCount--;

        BlockChanged?.Invoke(new Vector3I(x, y, z), old, id, cause);

        if (remesh)
        {
            MarkDirty(cc);
            int lx = x & 15, ly = y & 15, lz = z & 15;
            if (lx == 0) MarkDirty(cc + new Vector3I(-1, 0, 0));
            if (lx == 15) MarkDirty(cc + new Vector3I(1, 0, 0));
            if (ly == 0) MarkDirty(cc + new Vector3I(0, -1, 0));
            if (ly == 15) MarkDirty(cc + new Vector3I(0, 1, 0));
            if (lz == 0) MarkDirty(cc + new Vector3I(0, 0, -1));
            if (lz == 15) MarkDirty(cc + new Vector3I(0, 0, 1));
        }
    }

    private Chunk GetOrCreate(Vector3I cc)
    {
        if (_chunks.TryGetValue(cc, out var c)) return c;
        c = new Chunk { Coord = cc };
        _chunks[cc] = c;
        return c;
    }

    public void MarkDirty(Vector3I cc)
    {
        if (_chunks.ContainsKey(cc)) _dirty.Add(cc);
    }

    /// <summary>Mark every existing chunk dirty (used after a bulk build).</summary>
    public void RemeshAll()
    {
        foreach (var k in _chunks.Keys) _dirty.Add(k);
        FlushDirty();
    }

    public override void _Process(double delta) => FlushDirty();

    private void FlushDirty()
    {
        if (_dirty.Count == 0) return;
        // copy to avoid mutation during iteration
        var todo = new List<Vector3I>(_dirty);
        _dirty.Clear();
        foreach (var cc in todo)
            if (_chunks.TryGetValue(cc, out var c))
                RemeshChunk(c);
    }

    private void RemeshChunk(Chunk c)
    {
        var result = SandboxOpaqueMesher.Build(this, c.Coord);
        var origin = new Vector3(c.Coord.X * CS, c.Coord.Y * CS, c.Coord.Z * CS);

        // opaque surface
        if (result.OpaqueMesh != null)
        {
            c.Opaque ??= MakeChild(origin, _opaqueMat, out _);
            c.Opaque.Mesh = result.OpaqueMesh;
        }
        else if (c.Opaque != null) c.Opaque.Mesh = null;

        // transparent (glass) surface
        if (result.TransMesh != null)
        {
            c.Trans ??= MakeChild(origin, _glassMat, out _);
            c.Trans.Mesh = result.TransMesh;
        }
        else if (c.Trans != null) c.Trans.Mesh = null;

        // collision
        if (result.Collision != null)
        {
            if (c.Body == null)
            {
                c.Body = new StaticBody3D { Position = origin };
                AddChild(c.Body);
                c.Col = new CollisionShape3D();
                c.Body.AddChild(c.Col);
            }
            c.Col.Shape = result.Collision;
        }
        else if (c.Col != null) c.Col.Shape = null;
    }

    private MeshInstance3D MakeChild(Vector3 origin, Material mat, out MeshInstance3D mi)
    {
        mi = new MeshInstance3D { Position = origin, MaterialOverride = mat };
        AddChild(mi);
        return mi;
    }
}
