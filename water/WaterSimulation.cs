using System;
using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// The flow simulator. Minecraft-style discrete levels with a "pull" rule: each
/// active cell recomputes its level from its neighbours, water falls into air
/// below, sources are infinite, and flow dries up when unsupported. It is fully
/// self-scheduling (an active-set that drains as the field settles) and
/// deterministic (fixed processing order, no RNG), so a still lake costs nothing
/// and the same edit sequence always yields the same field.
/// </summary>
public sealed class WaterSimulation
{
    private readonly IVoxelWorld _w;
    private readonly WaterField _f;
    private readonly Func<WaterSettings> _settings;

    private readonly HashSet<Vector3I> _active = new();
    private readonly List<Vector3I> _ordered = new();
    private double _accum;

    public int LastProcessed { get; private set; }
    public int ActiveCount => _active.Count;

    private static readonly Vector3I Up = new(0, 1, 0), Down = new(0, -1, 0);
    private static readonly Vector3I[] Horiz =
        { new(1, 0, 0), new(-1, 0, 0), new(0, 0, 1), new(0, 0, -1) };

    public WaterSimulation(IVoxelWorld w, WaterField f, Func<WaterSettings> settings)
    {
        _w = w; _f = f; _settings = settings;
    }

    // ---- public edits ----

    public void Wake(Vector3I p) => _active.Add(p);

    private void WakeNeighbors(Vector3I p)
    {
        _active.Add(p + Up); _active.Add(p + Down);
        for (int i = 0; i < 4; i++) _active.Add(p + Horiz[i]);
    }

    public void PlaceSource(Vector3I p)
    {
        if (_w.IsSolid(p.X, p.Y, p.Z)) return;
        _w.SetBlock(p.X, p.Y, p.Z, _w.WaterId, false, WaterCause.WaterSim);
        _f.SetCell(p, WaterCell.Source());
        _active.Add(p);
        WakeNeighbors(p);
    }

    public void PlaceSeaSource(Vector3I p)
    {
        if (_w.IsSolid(p.X, p.Y, p.Z)) return;
        _w.SetBlock(p.X, p.Y, p.Z, _w.WaterId, false, WaterCause.WaterSim);
        var c = WaterCell.Source();
        c.Set(WaterFlags.SeaFilled, true);
        _f.SetCell(p, c);
        _active.Add(p);
        WakeNeighbors(p);
    }

    public void RemoveWater(Vector3I p)
    {
        if (_w.GetBlockId(p.X, p.Y, p.Z) == _w.WaterId)
            _w.SetBlock(p.X, p.Y, p.Z, _w.AirId, false, WaterCause.WaterSim);
        _f.ClearCell(p.X, p.Y, p.Z);
        WakeNeighbors(p);
    }

    /// <summary>React to a host edit we didn't make (player/world placed or removed a block).</summary>
    public void OnExternalEdit(Vector3I p, ushort oldId, ushort newId)
    {
        if (_w.IsSolid(p.X, p.Y, p.Z))
        {
            if (_f.HasWater(p.X, p.Y, p.Z)) _f.ClearCell(p.X, p.Y, p.Z); // water displaced by a solid
            WakeNeighbors(p);
        }
        else
        {
            // block became air (or water): if the player cleared a water cell, drop our record
            if (oldId == _w.WaterId && newId == _w.AirId) _f.ClearCell(p.X, p.Y, p.Z);
            _active.Add(p);
            WakeNeighbors(p);
        }
    }

    // ---- stepping ----

    public void Tick(double dt)
    {
        var s = _settings();
        double step = 1.0 / Math.Max(0.001, s.TickHz);
        _accum += dt;
        int n = 0;
        while (_accum >= step && n < s.MaxTicksPerFrame)
        {
            StepOneTick();
            _accum -= step;
            n++;
        }
        // don't let a long stall bank up huge catch-up
        if (_accum > step * 4) _accum = step * 4;
    }

    public void StepOneTick()
    {
        if (_active.Count == 0) { LastProcessed = 0; return; }
        var s = _settings();

        _ordered.Clear();
        _ordered.AddRange(_active);
        _active.Clear();

        // deterministic order: (y, z, x)
        _ordered.Sort(static (a, b) =>
        {
            int c = a.Y.CompareTo(b.Y);
            if (c != 0) return c;
            c = a.Z.CompareTo(b.Z);
            if (c != 0) return c;
            return a.X.CompareTo(b.X);
        });

        int budget = s.MaxCellsPerTick <= 0 ? int.MaxValue : s.MaxCellsPerTick;
        int processed = 0;
        for (int i = 0; i < _ordered.Count; i++)
        {
            if (processed >= budget)
            {
                for (int j = i; j < _ordered.Count; j++) _active.Add(_ordered[j]); // carry remainder
                break;
            }
            UpdateCell(_ordered[i]);
            processed++;
        }
        LastProcessed = processed;
    }

    // ---- the rule ----

    private void UpdateCell(Vector3I p)
    {
        int x = p.X, y = p.Y, z = p.Z;

        // never water inside a solid
        if (_w.IsSolid(x, y, z))
        {
            if (_f.HasWater(x, y, z)) { _f.ClearCell(x, y, z); WakeNeighbors(p); }
            return;
        }
        if (y < _w.MinY || y > _w.MaxY) return;

        WaterCell old = _f.GetCell(x, y, z);

        // sources are stable: keep them full. Their receivers are woken at
        // placement and whenever a neighbour changes, so a settled source costs
        // nothing (no per-tick re-waking — that would never let the field settle).
        if (old.IsSource)
        {
            if (_w.GetBlockId(x, y, z) != _w.WaterId)
                _w.SetBlock(x, y, z, _w.WaterId, false, WaterCause.WaterSim);
            return;
        }

        // compute new level via "pull"
        byte newLevel;
        bool falling = false;
        if (_f.HasWater(x, y + 1, z))
        {
            newLevel = WaterCell.MaxLevel; // fed from above => part of a falling column
            falling = true;
        }
        else
        {
            int best = 0;
            for (int i = 0; i < 4; i++)
            {
                var d = Horiz[i];
                int nx = x + d.X, nz = z + d.Z;
                var n = _f.GetCell(nx, y, nz);
                if (n.Level == 0) continue;
                int contrib;
                if (n.IsSource) contrib = WaterCell.MaxLevel - 1;                 // sources always push sideways
                else if (n.IsFalling) contrib = IsLanding(nx, y, nz) ? WaterCell.MaxLevel - 1 : 0; // only where a fall LANDS
                else contrib = SupportedBelow(nx, y, nz) ? n.Level - 1 : 0;       // flow spreads only across a surface
                if (contrib > best) best = contrib;
            }
            newLevel = (byte)best;
        }

        // infinite-source rule: between 2+ sources, on solid/water, a cell becomes a source
        if (newLevel > 0 && !falling && SupportedBelow(x, y, z))
        {
            int srcCount = 0;
            for (int i = 0; i < 4; i++)
                if (_f.GetCell(x + Horiz[i].X, y, z + Horiz[i].Z).IsSource) srcCount++;
            if (srcCount >= 2)
            {
                ApplyCell(p, old, WaterCell.Source());
                return;
            }
        }

        if (newLevel == 0)
        {
            if (old.Level > 0) // dry up
            {
                if (_w.GetBlockId(x, y, z) == _w.WaterId)
                    _w.SetBlock(x, y, z, _w.AirId, false, WaterCause.WaterSim);
                _f.ClearCell(x, y, z);
                WakeNeighbors(p);
            }
            return;
        }

        var nc = new WaterCell { Level = newLevel };
        nc.Set(WaterFlags.Falling, falling);
        ComputeFlow(ref nc, x, y, z);
        ApplyCell(p, old, nc);
    }

    private void ApplyCell(Vector3I p, WaterCell old, WaterCell nc)
    {
        int x = p.X, y = p.Y, z = p.Z;
        if (_w.GetBlockId(x, y, z) != _w.WaterId)
            _w.SetBlock(x, y, z, _w.WaterId, false, WaterCause.WaterSim);
        _f.SetCell(x, y, z, nc);

        bool changed = old.Level != nc.Level || old.FlowX != nc.FlowX || old.FlowZ != nc.FlowZ
                       || old.IsSource != nc.IsSource || old.IsFalling != nc.IsFalling;
        if (changed) WakeNeighbors(p);
    }

    private bool SupportedBelow(int x, int y, int z) => _w.IsSolid(x, y - 1, z) || _f.HasWater(x, y - 1, z);

    /// <summary>A falling cell is a *landing* (spreads horizontally) only where it
    /// meets solid ground or a non-falling pool — never mid-column.</summary>
    private bool IsLanding(int x, int y, int z)
    {
        if (_w.IsSolid(x, y - 1, z)) return true;
        var below = _f.GetCell(x, y - 1, z);
        return below.Level > 0 && !below.IsFalling;
    }

    private void ComputeFlow(ref WaterCell c, int x, int y, int z)
    {
        if (c.IsFalling) { c.FlowX = 0; c.FlowZ = 0; return; }
        float fx = 0f, fz = 0f;
        for (int i = 0; i < 4; i++)
        {
            var d = Horiz[i];
            int nl;
            if (_w.IsSolid(x + d.X, y, z + d.Z)) nl = c.Level; // wall: no outflow that way
            else nl = _f.GetCell(x + d.X, y, z + d.Z).Level;   // air = 0 => flows toward it
            int diff = c.Level - nl;
            if (diff > 0) { fx += d.X * diff; fz += d.Z * diff; }
        }
        float mag = Mathf.Sqrt(fx * fx + fz * fz);
        if (mag > 0.001f)
        {
            c.FlowX = (sbyte)Mathf.Clamp(Mathf.RoundToInt(fx / mag * 127f), -127, 127);
            c.FlowZ = (sbyte)Mathf.Clamp(Mathf.RoundToInt(fz / mag * 127f), -127, 127);
        }
        else { c.FlowX = 0; c.FlowZ = 0; }
    }
}
