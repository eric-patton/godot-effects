using System.Collections.Generic;
using Godot;

namespace Sandbox.Water;

/// <summary>
/// Dead-simple per-chunk mesher for the sandbox scenery: per-face culling with
/// vertex colours, an opaque surface (stone/dirt/grass) and a transparent
/// surface (glass), plus a concave collision shape from the solid faces. Runs
/// on the main thread; it's only scenery, so it isn't optimised or ported.
/// Water blocks are skipped here — the water module renders those.
/// </summary>
public static class SandboxOpaqueMesher
{
    public struct Result
    {
        public ArrayMesh OpaqueMesh;
        public ArrayMesh TransMesh;
        public Shape3D Collision;
    }

    // 6 face directions and their outward normals.
    private static readonly Vector3I[] Dirs =
    {
        new(1, 0, 0), new(-1, 0, 0),
        new(0, 1, 0), new(0, -1, 0),
        new(0, 0, 1), new(0, 0, -1),
    };

    // 4 corners per face (local cube space 0..1), consistent quad winding.
    private static readonly Vector3[][] FaceVerts =
    {
        new[] { new Vector3(1,0,0), new Vector3(1,1,0), new Vector3(1,1,1), new Vector3(1,0,1) }, // +X
        new[] { new Vector3(0,0,1), new Vector3(0,1,1), new Vector3(0,1,0), new Vector3(0,0,0) }, // -X
        new[] { new Vector3(0,1,0), new Vector3(0,1,1), new Vector3(1,1,1), new Vector3(1,1,0) }, // +Y
        new[] { new Vector3(0,0,1), new Vector3(0,0,0), new Vector3(1,0,0), new Vector3(1,0,1) }, // -Y
        new[] { new Vector3(1,0,1), new Vector3(1,1,1), new Vector3(0,1,1), new Vector3(0,0,1) }, // +Z
        new[] { new Vector3(0,0,0), new Vector3(0,1,0), new Vector3(1,1,0), new Vector3(1,0,0) }, // -Z
    };

    public static Result Build(SandboxWorld world, Vector3I cc)
    {
        var op = new SurfaceTool();
        var tr = new SurfaceTool();
        op.Begin(Mesh.PrimitiveType.Triangles);
        tr.Begin(Mesh.PrimitiveType.Triangles);
        bool hasOp = false, hasTr = false;
        var colTris = new List<Vector3>();

        int bx = cc.X * SandboxWorld.CS, by = cc.Y * SandboxWorld.CS, bz = cc.Z * SandboxWorld.CS;

        for (int ly = 0; ly < SandboxWorld.CS; ly++)
        for (int lz = 0; lz < SandboxWorld.CS; lz++)
        for (int lx = 0; lx < SandboxWorld.CS; lx++)
        {
            int wx = bx + lx, wy = by + ly, wz = bz + lz;
            ushort id = world.GetBlockId(wx, wy, wz);
            if (id == SandboxBlocks.Air || SandboxBlocks.IsWater(id)) continue;

            bool glass = id == SandboxBlocks.Glass;
            Color col = SandboxBlocks.ColorOf(id);
            var localBase = new Vector3(lx, ly, lz);

            for (int f = 0; f < 6; f++)
            {
                var d = Dirs[f];
                ushort nb = world.GetBlockId(wx + d.X, wy + d.Y, wz + d.Z);

                bool draw;
                if (glass)
                    // glass shows faces only against air/water (not solids or other glass)
                    draw = nb == SandboxBlocks.Air || SandboxBlocks.IsWater(nb);
                else
                    // opaque shows faces against anything non-opaque
                    draw = !SandboxBlocks.IsOpaque(nb);

                if (!draw) continue;

                var n = new Vector3(d.X, d.Y, d.Z);
                var v = FaceVerts[f];
                var p0 = localBase + v[0];
                var p1 = localBase + v[1];
                var p2 = localBase + v[2];
                var p3 = localBase + v[3];

                var st = glass ? tr : op;
                AddQuad(st, n, col, p0, p1, p2, p3);
                if (glass) hasTr = true; else hasOp = true;

                // collision uses the exposed faces of all solid blocks
                colTris.Add(p0); colTris.Add(p1); colTris.Add(p2);
                colTris.Add(p0); colTris.Add(p2); colTris.Add(p3);
            }
        }

        var result = new Result();
        if (hasOp) result.OpaqueMesh = op.Commit();
        if (hasTr) result.TransMesh = tr.Commit();
        if (colTris.Count > 0)
            result.Collision = new ConcavePolygonShape3D { Data = colTris.ToArray() };
        return result;
    }

    private static void AddQuad(SurfaceTool st, Vector3 n, Color col,
        Vector3 a, Vector3 b, Vector3 c, Vector3 d)
    {
        // two triangles: a,b,c and a,c,d
        Vert(st, n, col, a); Vert(st, n, col, b); Vert(st, n, col, c);
        Vert(st, n, col, a); Vert(st, n, col, c); Vert(st, n, col, d);
    }

    private static void Vert(SurfaceTool st, Vector3 n, Color col, Vector3 p)
    {
        st.SetColor(col);
        st.SetNormal(n);
        st.AddVertex(p);
    }
}
