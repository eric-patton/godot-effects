using System.Collections.Generic;
using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Throwaway debug visualizer for M4: draws each water cell as a coloured cube
/// (height = level/8, blue→cyan by level, whitened when falling) via a single
/// MultiMesh, rebuilt each frame. Replaced by the real WaterRenderer in M5.
/// </summary>
public partial class WaterDebugView : MultiMeshInstance3D
{
    private MultiMesh _mm;
    private readonly List<Vector3> _pos = new();
    private readonly List<float> _h = new();
    private readonly List<Color> _col = new();

    public override void _Ready()
    {
        _mm = new MultiMesh
        {
            TransformFormat = MultiMesh.TransformFormatEnum.Transform3D,
            UseColors = true,
            Mesh = new BoxMesh { Size = new Vector3(0.9f, 1f, 0.9f) },
        };
        Multimesh = _mm;
        MaterialOverride = new StandardMaterial3D
        {
            VertexColorUseAsAlbedo = true,
            Transparency = BaseMaterial3D.TransparencyEnum.Alpha,
            AlbedoColor = Colors.White,
            Roughness = 0.15f,
        };
    }

    public void Rebuild(WaterField field)
    {
        _pos.Clear(); _h.Clear(); _col.Clear();

        var deep = new Color(0.05f, 0.30f, 0.75f);
        var shallow = new Color(0.45f, 0.85f, 1.0f);
        var foam = new Color(0.92f, 0.97f, 1.0f);

        foreach (var c in field.Chunks.Values)
        {
            var bc = c.Coord * WaterChunk.CS;
            for (int i = 0; i < WaterChunk.CV; i++)
            {
                var cell = c.Cells[i];
                if (cell.Level == 0) continue;
                int lx = i & 15, lz = (i >> 4) & 15, ly = i >> 8;

                float t = cell.Level / 8f;
                float h = cell.IsFalling ? 1f : Mathf.Max(0.12f, t);
                Color col = shallow.Lerp(deep, t);
                if (cell.IsFalling) col = col.Lerp(foam, 0.5f);
                if (cell.IsSource) col = col.Lerp(new Color(0.6f, 1f, 0.9f), 0.4f);
                col.A = 0.78f;

                _pos.Add(new Vector3(bc.X + lx + 0.5f, bc.Y + ly + h * 0.5f, bc.Z + lz + 0.5f));
                _h.Add(h);
                _col.Add(col);
            }
        }

        _mm.InstanceCount = _pos.Count;
        for (int i = 0; i < _pos.Count; i++)
        {
            var basis = Basis.Identity.Scaled(new Vector3(1f, _h[i], 1f));
            _mm.SetInstanceTransform(i, new Transform3D(basis, _pos[i]));
            _mm.SetInstanceColor(i, _col[i]);
        }
    }
}
