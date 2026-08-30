using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Plain-data result of <see cref="WaterMeshBuilder"/>. Built on a worker thread
/// (only value types, no Godot resources), turned into an ArrayMesh on the main
/// thread by <see cref="WaterRenderer"/>. The COLOR channel carries water data
/// the shader consumes: RG = flow direction (0..1), B = class tag, A = edge foam.
/// </summary>
public sealed class WaterMeshData
{
    public readonly List<Vector3> Verts = new();
    public readonly List<Vector3> Normals = new();
    public readonly List<Vector2> UVs = new();
    public readonly List<Color> Colors = new();
    public readonly List<int> Indices = new();

    public bool Empty => Verts.Count == 0;

    /// <summary>Add a quad a→b→c→d (UVs 00,10,11,01). Two triangles.</summary>
    public void Quad(Vector3 a, Vector3 b, Vector3 c, Vector3 d, Vector3 n, Color col)
    {
        int i = Verts.Count;
        Add(a, n, col, new Vector2(0, 0));
        Add(b, n, col, new Vector2(1, 0));
        Add(c, n, col, new Vector2(1, 1));
        Add(d, n, col, new Vector2(0, 1));
        Indices.Add(i); Indices.Add(i + 1); Indices.Add(i + 2);
        Indices.Add(i); Indices.Add(i + 2); Indices.Add(i + 3);
    }

    private void Add(Vector3 v, Vector3 n, Color c, Vector2 uv)
    {
        Verts.Add(v); Normals.Add(n); Colors.Add(c); UVs.Add(uv);
    }
}
