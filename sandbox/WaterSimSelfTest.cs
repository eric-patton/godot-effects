using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Headless behaviour + determinism checks for the flow simulation. Runs at boot
/// and prints PASS/FAIL. Uses a fresh off-tree SandboxWorld per case so no
/// meshing happens — pure logic.
/// </summary>
public static class WaterSimSelfTest
{
    public static void Run()
    {
        int pass = 0, fail = 0;
        void Check(string name, bool ok)
        {
            if (ok) { pass++; GD.Print($"[simtest] PASS  {name}"); }
            else { fail++; GD.PrintErr($"[simtest] FAIL  {name}"); }
        }

        // --- Test 1: spread then dry on source removal ---
        {
            var (w, m) = Make();
            Floor(w, 0, 10);                       // stone floor at y=0
            m.PlaceSource(new Vector3I(0, 1, 0));
            m.DebugStep(40);
            int spread = m.WaterCells;
            m.Remove(new Vector3I(0, 1, 0));       // pull the source
            m.DebugStep(80);
            Check("spread then dry", spread > 20 && m.WaterCells == 0);
            w.Free();
        }

        // --- Test 2: two sources regenerate a middle source ---
        {
            var (w, m) = Make();
            Floor(w, 0, 8);
            m.PlaceSource(new Vector3I(0, 1, 0));
            m.PlaceSource(new Vector3I(2, 1, 0));
            m.DebugStep(10);
            Check("two sources regenerate middle", m.Field.GetCell(1, 1, 0).IsSource);
            w.Free();
        }

        // --- Test 3: waterfall falls down a shaft and pools at the base ---
        {
            var (w, m) = Make();
            // single stone floor block at base + a tall air shaft above
            w.SetBlock(0, 0, 0, SandboxBlocks.Stone, false);
            Floor(w, 0, 6); // wider base so the pool can spread
            m.PlaceSource(new Vector3I(0, 9, 0));  // air below all the way to y=1
            m.DebugStep(40);
            var mid = m.Field.GetCell(0, 5, 0);    // mid-column
            var landing = m.Field.GetCell(0, 1, 0); // just above the floor
            Check("waterfall falls + pools",
                  mid.Level > 0 && mid.IsFalling && landing.Level > 0);
            w.Free();
        }

        // --- Test 4: determinism (same edits -> same field checksum) ---
        {
            ulong RunOnce()
            {
                var (w, m) = Make();
                Floor(w, 0, 12);
                m.PlaceSource(new Vector3I(0, 1, 0));
                m.DebugStep(15);
                w.SetBlock(3, 1, 0, SandboxBlocks.Stone, false, WaterCause.PlayerEdit); // dam (external edit)
                m.DebugStep(15);
                ulong sum = m.FieldChecksum();
                w.Free();
                return sum;
            }
            ulong a = RunOnce();
            ulong b = RunOnce();
            Check("determinism (identical checksum)", a == b && a != 0);
        }

        GD.Print($"[simtest] ==== {pass} passed, {fail} failed ====");
    }

    private static (SandboxWorld, WaterManager) Make()
    {
        var w = new SandboxWorld();                 // off-tree: no meshing
        var adapter = new SandboxVoxelWorldAdapter(w);
        var m = new WaterManager(adapter, WaterSettings.High());
        return (w, m);
    }

    private static void Floor(SandboxWorld w, int y, int r)
    {
        for (int z = -r; z <= r; z++)
        for (int x = -r; x <= r; x++)
            w.SetBlock(x, y, z, SandboxBlocks.Stone, false);
    }
}
