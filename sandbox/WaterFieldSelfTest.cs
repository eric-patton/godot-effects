using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Sandbox-only correctness checks for the data-model layer. Runs at boot and
/// prints PASS/FAIL to the log. Not ported — it just guards the seam + field
/// math (cross-chunk, negative coords, WaterCount, eviction, raycast, adapter).
/// </summary>
public static class WaterFieldSelfTest
{
    public static void Run(SandboxWorld world)
    {
        int pass = 0, fail = 0;
        void Check(string name, bool ok)
        {
            if (ok) { pass++; GD.Print($"[selftest] PASS  {name}"); }
            else { fail++; GD.PrintErr($"[selftest] FAIL  {name}"); }
        }

        // ---- WaterField: chunk math ----
        Check("ChunkOf positive", WaterField.ChunkOf(0, 0, 0) == new Vector3I(0, 0, 0)
                                   && WaterField.ChunkOf(15, 15, 15) == new Vector3I(0, 0, 0)
                                   && WaterField.ChunkOf(16, 0, 0) == new Vector3I(1, 0, 0));
        Check("ChunkOf negative", WaterField.ChunkOf(-1, 0, 0) == new Vector3I(-1, 0, 0)
                                   && WaterField.ChunkOf(-16, 0, 0) == new Vector3I(-1, 0, 0)
                                   && WaterField.ChunkOf(-17, 0, 0) == new Vector3I(-2, 0, 0));

        var field = new WaterField();

        // ---- cross-chunk neighbour get/set ----
        field.SetCell(15, 0, 0, WaterCell.Flow(7));   // chunk 0, local x=15
        field.SetCell(16, 0, 0, WaterCell.Source());  // chunk 1, local x=0 (neighbour across boundary)
        Check("read across +X boundary", field.GetCell(15, 0, 0).Level == 7
                                          && field.GetCell(16, 0, 0).Level == 8
                                          && field.GetCell(16, 0, 0).IsSource);
        Check("neighbour of 15 is 16", field.GetCell(new Vector3I(15, 0, 0) + new Vector3I(1, 0, 0)).IsSource);

        // ---- negative coords ----
        field.SetCell(-1, -1, -1, WaterCell.Flow(4));
        Check("negative coord store", field.GetCell(-1, -1, -1).Level == 4);
        Check("negative chunk created", field.GetChunk(new Vector3I(-1, -1, -1)) != null);

        // ---- WaterCount + eviction ----
        var f2 = new WaterField();
        f2.SetCell(100, 5, 100, WaterCell.Flow(3));
        f2.SetCell(101, 5, 100, WaterCell.Flow(2));
        bool count2 = f2.TotalWaterCells == 2;
        f2.ClearCell(100, 5, 100);
        f2.ClearCell(101, 5, 100);
        int evicted = f2.EvictEmpty();
        Check("WaterCount + evict empty", count2 && f2.TotalWaterCells == 0 && evicted >= 1 && f2.ChunkCount == 0);

        // ---- flags round-trip ----
        var cell = WaterCell.Flow(5);
        cell.Set(WaterFlags.Falling, true);
        cell.Set(WaterFlags.Settled, true);
        cell.Set(WaterFlags.Falling, false);
        Check("flags set/clear", cell.IsFalling == false && cell.Has(WaterFlags.Settled) && cell.Level == 5);

        // ---- adapter + BlockChanged round-trip ----
        var adapter = new SandboxVoxelWorldAdapter(world);
        Vector3I changedAt = default; int changeCause = -1; ushort newId = 0;
        adapter.BlockChanged += (p, o, n, c) => { changedAt = p; changeCause = c; newId = n; };
        adapter.SetBlock(50, 50, 50, adapter.WaterId, remesh: false, cause: WaterCause.PlayerEdit);
        Check("adapter writes + event fires", adapter.GetBlockId(50, 50, 50) == adapter.WaterId
                                               && changedAt == new Vector3I(50, 50, 50)
                                               && changeCause == WaterCause.PlayerEdit
                                               && newId == adapter.WaterId);
        adapter.SetBlock(50, 50, 50, adapter.AirId, remesh: false); // cleanup

        // ---- adapter raycast straight down onto an open patch of grass slab (y=0) ----
        bool hit = adapter.Raycast(new Vector3(-12.5f, 20f, 12.5f), Vector3.Down, 64f,
                                   out var hc, out var hn, out _);
        Check("raycast hits ground", hit && hn == new Vector3I(0, 1, 0)
                                          && hc == new Vector3I(-13, 0, 12)
                                          && world.IsSolid(hc.X, hc.Y, hc.Z));

        GD.Print($"[selftest] ==== {pass} passed, {fail} failed ====");
    }
}
