using Godot;

namespace RAEngine.Water;

/// <summary>
/// Worker-thread snapshot of one chunk's water cells + 1-cell border + solidity.
/// Captured on the main thread, then handed to <see cref="WaterMeshBuilder"/>.
/// Indices run x,y,z in -1..16 (18³ padded).
/// </summary>
public sealed class WaterMeshInput
{
    public const int P = 18;
    public Vector3I Coord;
    public readonly WaterCell[] Cells = new WaterCell[P * P * P];
    public readonly bool[] Solid = new bool[P * P * P];
    public readonly byte[] Class = new byte[P * P * P];

    public static int PIdx(int x, int y, int z) => ((y + 1) * P + (z + 1)) * P + (x + 1);
    public WaterCell Cell(int x, int y, int z) => Cells[PIdx(x, y, z)];
    public bool IsSolid(int x, int y, int z) => Solid[PIdx(x, y, z)];
    public byte ClassAt(int x, int y, int z) => Class[PIdx(x, y, z)];
}

/// <summary>
/// Generates a water surface mesh for one chunk: a top quad per cell with
/// corner heights averaged across neighbours (smooth flowing slopes), side quads
/// only against air, and a bottom quad under overhangs. Falling cells render
/// full-height (the waterfall sheet). Pure value-type work — safe off-thread.
/// </summary>
public static class WaterMeshBuilder
{
    private const float Bias = 0.0625f;   // surface sits slightly below the block top
    private const float Span = 0.875f;

    private static float Hf(int level) => level / 8f * Span + Bias;

    private static float RenderHeight(in WaterCell c, bool hasAbove)
    {
        if (hasAbove) return 1f;       // mid/over column => full to the top
        if (c.IsFalling) return 1f;    // topmost falling cell => full sheet
        return Hf(c.Level);
    }

    public static WaterMeshData Build(WaterMeshInput inp)
    {
        var md = new WaterMeshData();

        for (int y = 0; y < 16; y++)
        for (int z = 0; z < 16; z++)
        for (int x = 0; x < 16; x++)
        {
            var c = inp.Cell(x, y, z);
            if (c.Level == 0) continue;

            bool aboveWater = inp.Cell(x, y + 1, z).Level > 0;

            // corner heights shared by top + side tops (seamless surface)
            float h00 = Corner(inp, x, y, z, 0, 0);
            float h10 = Corner(inp, x, y, z, 1, 0);
            float h11 = Corner(inp, x, y, z, 1, 1);
            float h01 = Corner(inp, x, y, z, 0, 1);

            Color col = DataColor(c, inp.ClassAt(x, y, z));

            // TOP (skip if a water cell sits directly above — interior of a column)
            if (!aboveWater)
            {
                md.Quad(
                    new Vector3(x, y + h00, z),
                    new Vector3(x + 1, y + h10, z),
                    new Vector3(x + 1, y + h11, z + 1),
                    new Vector3(x, y + h01, z + 1),
                    Vector3.Up, col);
            }

            // SIDES — only against air (water hides internal, solid occludes)
            if (IsAir(inp, x + 1, y, z))
                md.Quad(
                    new Vector3(x + 1, y, z),
                    new Vector3(x + 1, y, z + 1),
                    new Vector3(x + 1, y + h11, z + 1),
                    new Vector3(x + 1, y + h10, z),
                    new Vector3(1, 0, 0), col);

            if (IsAir(inp, x - 1, y, z))
                md.Quad(
                    new Vector3(x, y, z + 1),
                    new Vector3(x, y, z),
                    new Vector3(x, y + h00, z),
                    new Vector3(x, y + h01, z + 1),
                    new Vector3(-1, 0, 0), col);

            if (IsAir(inp, x, y, z + 1))
                md.Quad(
                    new Vector3(x, y, z + 1),
                    new Vector3(x + 1, y, z + 1),
                    new Vector3(x + 1, y + h11, z + 1),
                    new Vector3(x, y + h01, z + 1),
                    new Vector3(0, 0, 1), col);

            if (IsAir(inp, x, y, z - 1))
                md.Quad(
                    new Vector3(x + 1, y, z),
                    new Vector3(x, y, z),
                    new Vector3(x, y + h00, z),
                    new Vector3(x + 1, y + h10, z),
                    new Vector3(0, 0, -1), col);

            // BOTTOM — only under an overhang (air below)
            if (IsAir(inp, x, y - 1, z))
                md.Quad(
                    new Vector3(x, y, z),
                    new Vector3(x + 1, y, z),
                    new Vector3(x + 1, y, z + 1),
                    new Vector3(x, y, z + 1),
                    new Vector3(0, -1, 0), col);
        }

        return md;
    }

    private static bool IsAir(WaterMeshInput inp, int x, int y, int z)
        => inp.Cell(x, y, z).Level == 0 && !inp.IsSolid(x, y, z);

    private static float Corner(WaterMeshInput inp, int x, int y, int z, int ci, int cj)
    {
        float sum = 0f; int cnt = 0;
        for (int oi = ci - 1; oi <= ci; oi++)
        for (int oj = cj - 1; oj <= cj; oj++)
        {
            var cc = inp.Cell(x + oi, y, z + oj);
            if (cc.Level == 0) continue;
            bool ab = inp.Cell(x + oi, y + 1, z + oj).Level > 0;
            sum += RenderHeight(cc, ab);
            cnt++;
        }
        return cnt > 0 ? sum / cnt : Hf(inp.Cell(x, y, z).Level);
    }

    // RG = flow dir (0..1), B = class tag/8, A = frozen flag
    private static Color DataColor(in WaterCell c, byte cls)
    {
        float fx = c.FlowX / 127f * 0.5f + 0.5f;
        float fz = c.FlowZ / 127f * 0.5f + 0.5f;
        float frozen = c.Has(WaterFlags.Frozen) ? 1f : 0f;
        return new Color(fx, fz, cls / 8f, frozen);
    }
}
