using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Builds the deterministic demo world: a calm reflective lake, a river running
/// down a slope into a rapids, a tall multi-tier waterfall into a plunge pool,
/// and an open build yard. Solids go into the SandboxWorld; water sources are
/// placed through the WaterManager so the sim takes over from there.
/// </summary>
public static class ShowcaseBuilder
{
    public const float LakeX = 0f, WaterfallX = -52f, RiverX = 52f, YardZ = 46f;

    public static void Build(SandboxWorld w, WaterManager m)
    {
        Lake(w, m, 0, 0);
        Waterfall(w, m, (int)WaterfallX, 0);
        River(w, m, (int)RiverX, 0);
        BuildYard(w, 0, (int)YardZ);
    }

    // ---- calm reflective lake ----
    private static void Lake(SandboxWorld w, WaterManager m, int cx, int cz)
    {
        Ground(w, cx, cz, 18, 0);
        // circular basin, 4 deep
        const int R = 13;
        for (int z = -R; z <= R; z++)
        for (int x = -R; x <= R; x++)
        {
            if (x * x + z * z > R * R) continue;
            for (int y = 0; y >= -4; y--) w.SetBlock(cx + x, y, cz + z, SandboxBlocks.Air, false);
            w.SetBlock(cx + x, -5, cz + z, SandboxBlocks.Stone, false);
        }
        // a couple of rocks + an arch for reflections
        Pillar(w, cx - 8, cz - 6, 1, 5);
        Pillar(w, cx + 9, cz + 5, 1, 4);
        Arch(w, cx + 4, cz - 11);
        // fill with sources
        for (int z = -R; z <= R; z++)
        for (int x = -R; x <= R; x++)
        {
            if (x * x + z * z > R * R) continue;
            for (int y = -4; y <= 0; y++) m.PlaceSource(new Vector3I(cx + x, y, cz + z));
        }
    }

    // ---- river: source pool at top of a slope, flows down through rapids ----
    private static void River(SandboxWorld w, WaterManager m, int cx, int cz)
    {
        Ground(w, cx, cz, 16, 0);
        // a descending stair channel in +x... actually carve a sloping trench in -z to +z
        // top is high ground, ramp down to a low pool
        for (int s = 0; s < 12; s++)
        {
            int z = cz - 14 + s * 2;
            int top = 8 - s;                  // descending bed height
            // bed + walls of a 5-wide channel
            for (int dz = 0; dz < 2; dz++)
            for (int x = -3; x <= 3; x++)
            {
                int by = top;
                // raise terrain to bed height, carve channel above
                for (int y = 1; y <= by; y++) w.SetBlock(cx + x, y, z + dz, SandboxBlocks.Stone, false);
                // walls
                if (x == -3 || x == 3)
                    for (int y = by + 1; y <= by + 3; y++) w.SetBlock(cx + x, y, z + dz, SandboxBlocks.Stone, false);
            }
        }
        // source pool at the very top
        for (int x = -2; x <= 2; x++)
        for (int dz = 0; dz < 2; dz++)
            m.PlaceSource(new Vector3I(cx + x, 9, cz - 14 + dz));
    }

    // ---- tall multi-tier waterfall into a plunge pool ----
    private static void Waterfall(SandboxWorld w, WaterManager m, int cx, int cz)
    {
        Ground(w, cx, cz, 16, 0);
        // a big cliff block on the -z side, 16 tall, with two ledges
        for (int z = cz - 14; z <= cz - 6; z++)
        for (int x = cx - 10; x <= cx + 10; x++)
        for (int y = 1; y <= 16; y++)
            w.SetBlock(x, y, z, SandboxBlocks.Stone, false);
        // carve two stepped ledges into the cliff face (z = cz-6 face)
        Ledge(w, cx, cz - 6, 11);
        Ledge(w, cx, cz - 6, 6);

        // plunge basin at the base in front of the cliff
        const int R = 9;
        for (int z = -R; z <= R; z++)
        for (int x = -R; x <= R; x++)
        {
            if (x * x + z * z > R * R) continue;
            int wz = cz + 3 + z;
            for (int y = 0; y >= -3; y--) w.SetBlock(cx + x, y, wz, SandboxBlocks.Air, false);
            w.SetBlock(cx + x, -4, wz, SandboxBlocks.Stone, false);
        }
        // source channel on top of the cliff feeding the fall
        for (int x = cx - 3; x <= cx + 3; x++)
        for (int z = cz - 12; z <= cz - 7; z++)
            m.PlaceSource(new Vector3I(x, 17, z));
    }

    private static void Ledge(SandboxWorld w, int cx, int faceZ, int y)
    {
        // shallow shelf so water tiers as it falls
        for (int x = cx - 6; x <= cx + 6; x++)
            for (int z = faceZ; z <= faceZ + 1; z++)
            {
                w.SetBlock(x, y, z, SandboxBlocks.Air, false);
                w.SetBlock(x, y - 1, z, SandboxBlocks.Stone, false);
            }
    }

    private static void BuildYard(SandboxWorld w, int cx, int cz)
    {
        Ground(w, cx, cz, 14, 0);
    }

    // ---- helpers ----
    private static void Ground(SandboxWorld w, int cx, int cz, int r, int topY)
    {
        for (int z = -r; z <= r; z++)
        for (int x = -r; x <= r; x++)
        {
            for (int y = topY - 5; y <= topY - 1; y++) w.SetBlock(cx + x, y, cz + z, SandboxBlocks.Stone, false);
            w.SetBlock(cx + x, topY - 1, cz + z, SandboxBlocks.Dirt, false);
            w.SetBlock(cx + x, topY, cz + z, SandboxBlocks.Grass, false);
        }
    }

    private static void Pillar(SandboxWorld w, int x, int z, int r, int h)
    {
        for (int dz = -r; dz <= r; dz++)
        for (int dx = -r; dx <= r; dx++)
        for (int y = 1; y <= h; y++)
            w.SetBlock(x + dx, y, z + dz, SandboxBlocks.Stone, false);
    }

    private static void Arch(SandboxWorld w, int x, int z)
    {
        for (int y = 1; y <= 5; y++) { w.SetBlock(x - 3, y, z, SandboxBlocks.Stone, false); w.SetBlock(x + 3, y, z, SandboxBlocks.Stone, false); }
        for (int dx = -3; dx <= 3; dx++) w.SetBlock(x + dx, 6, z, SandboxBlocks.Stone, false);
    }
}
