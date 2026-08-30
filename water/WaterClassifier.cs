using System;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Tags each water cell calm / river / waterfall (plus lip / plunge-pool /
/// shoreline / rapids) from the sim state + immediate neighbourhood. The tag is
/// written into the chunk's Class[] and baked into the mesh COLOR so the shader,
/// foam, spray, and audio all read one classification.
/// </summary>
public static class WaterClassifier
{
    private static readonly Vector3I[] Horiz =
        { new(1, 0, 0), new(-1, 0, 0), new(0, 0, 1), new(0, 0, -1) };

    private const int RiverFlowThreshold = 40; // ~0.3 of 127

    public static void Classify(WaterField f, IVoxelWorld w, WaterChunk ch)
    {
        var bc = ch.Coord * WaterChunk.CS;
        ch.Turbulent.Clear();
        for (int i = 0; i < WaterChunk.CV; i++)
        {
            var c = ch.Cells[i];
            if (c.Level == 0) { ch.Class[i] = 0; continue; }
            int lx = i & 15, lz = (i >> 4) & 15, ly = i >> 8;
            var cls = ClassifyCell(f, w, c, bc.X + lx, bc.Y + ly, bc.Z + lz);
            ch.Class[i] = (byte)cls;
            if (cls is WaterClass.PlungePool or WaterClass.Rapids or WaterClass.WaterfallLip)
                ch.Turbulent.Add(i);
        }
        ch.ClassDirty = false;
    }

    private static WaterClass ClassifyCell(WaterField f, IVoxelWorld w, in WaterCell c, int x, int y, int z)
    {
        if (c.IsFalling)
        {
            bool below = w.IsSolid(x, y - 1, z);
            if (!below)
            {
                var b = f.GetCell(x, y - 1, z);
                below = b.Level > 0 && !b.IsFalling;
            }
            return below ? WaterClass.PlungePool : WaterClass.Waterfall;
        }

        bool nearFall = false, nearSolid = false;
        int maxDiff = 0;
        for (int i = 0; i < 4; i++)
        {
            int nx = x + Horiz[i].X, nz = z + Horiz[i].Z;
            if (w.IsSolid(nx, y, nz)) { nearSolid = true; continue; }
            var n = f.GetCell(nx, y, nz);
            if (n.Level > 0)
            {
                if (n.IsFalling) nearFall = true;
                int diff = c.Level - n.Level;
                if (diff > maxDiff) maxDiff = diff;
            }
            else
            {
                // an air neighbour with a drop below it = an edge water can pour over
                if (!w.IsSolid(nx, y - 1, nz) && f.GetCell(nx, y - 1, nz).Level == 0) nearFall = true;
            }
        }

        if (nearFall) return WaterClass.WaterfallLip;
        if (maxDiff >= 2) return WaterClass.Rapids;
        int flowMag = Math.Abs(c.FlowX) + Math.Abs(c.FlowZ);
        if (flowMag > RiverFlowThreshold) return WaterClass.River;
        if (nearSolid) return WaterClass.Shoreline;
        return WaterClass.Calm;
    }
}
