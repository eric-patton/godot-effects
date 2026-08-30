using System;
using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Public façade for the water module. Construct it with an <see cref="IVoxelWorld"/>
/// adapter and settings, subscribe it to the host's block changes (done here),
/// and call <see cref="Tick"/> once per frame. Later milestones grow this to own
/// the renderer, audio, and submerged FX too; for now it owns the field + sim.
/// </summary>
public sealed class WaterManager
{
    public WaterField Field { get; } = new();
    public WaterSettings Settings;

    /// <summary>Default swimmer (a host character controller calls Sample each physics frame).</summary>
    public WaterSwimmer Swimmer { get; }

    private readonly IVoxelWorld _world;
    private readonly WaterSimulation _sim;
    private WaterRenderer _renderer;
    private FoamSystem _foam;
    private SpraySystem _spray;
    private SubmergedFx _submerged;
    private IWaterAudio _audio;
    private Camera3D _camera;
    private readonly List<WaterAudioCluster> _clusters = new();
    private int _evictTimer;

    public WaterManager(IVoxelWorld world, WaterSettings settings)
    {
        _world = world;
        Settings = settings;
        _sim = new WaterSimulation(world, Field, () => Settings);
        Swimmer = new WaterSwimmer(Field);
        _world.BlockChanged += OnBlockChanged;
    }

    /// <summary>Create the surface renderer parented under <paramref name="root"/>.</summary>
    public WaterRenderer AttachRenderer(Node3D root, Material material)
    {
        _renderer = new WaterRenderer(root, Field, _world, () => Settings, material);
        return _renderer;
    }

    public WaterRenderer Renderer => _renderer;

    /// <summary>Create the foam-cube + spray particle systems under <paramref name="root"/>.</summary>
    public void AttachFx(Node3D root)
    {
        _foam = new FoamSystem(root, Field, () => Settings);
        _spray = new SpraySystem(root, Field, () => Settings);
    }

    public int FoamCount => _foam?.LiveCount ?? 0;

    /// <summary>Set the active camera (drives submerged FX + audio listener).</summary>
    public void SetCamera(Camera3D cam) => _camera = cam;

    public void AttachSubmergedFx(Node root, string underwaterShaderPath)
        => _submerged = new SubmergedFx(root, Field, () => Settings, underwaterShaderPath);

    public void AttachAudio(IWaterAudio audio)
    {
        _audio = audio;
        _audio.Configure(Settings);
    }

    public void Tick(double dt)
    {
        _sim.Tick(dt);
        ClassifyDirty();      // must run before the renderer captures Class into the mesh
        _renderer?.Update();
        _foam?.Update(dt);
        _spray?.Update(dt);

        bool submerged = _submerged?.Update(dt, _camera) ?? false;
        if (_audio != null)
        {
            var listener = _camera?.GlobalPosition ?? Vector3.Zero;
            BuildAudioClusters(listener);
            _audio.UpdateClusters(listener, _clusters);
            _audio.SetSubmerged(submerged);
        }

        // periodic memory tidy: drop chunks with no water left
        if (++_evictTimer >= 30) { _evictTimer = 0; Field.EvictEmpty(); }
    }

    /// <summary>Re-apply quality settings to all subsystems (live tier switch).</summary>
    public void ApplySettings()
    {
        _foam?.Configure(Settings);
        _spray?.Configure(Settings);
        _audio?.Configure(Settings);
    }

    // pick the loudest nearby sound sources: waterfalls (turbulent sites) + one ambient bed
    private void BuildAudioClusters(Vector3 listener)
    {
        _clusters.Clear();
        float r = 26f;
        float nearestWaterD = float.MaxValue;
        WaterAudioCluster ambient = default;
        bool haveAmbient = false;

        foreach (var ch in Field.Chunks.Values)
        {
            var bc = ch.Coord * WaterChunk.CS;
            // waterfall/turbulent sites -> roar clusters
            foreach (int idx in ch.Turbulent)
            {
                int lx = idx & 15, lz = (idx >> 4) & 15, ly = idx >> 8;
                var pos = new Vector3(bc.X + lx + 0.5f, bc.Y + ly + 0.5f, bc.Z + lz + 0.5f);
                float d = pos.DistanceTo(listener);
                if (d < r)
                    _clusters.Add(new WaterAudioCluster { Pos = pos, Class = WaterClass.Waterfall, Strength = 1f - d / r });
            }
            // nearest plain water cell -> ambient (calm/river) bed
            if (ch.WaterCount > 0)
            {
                var center = new Vector3(bc.X + 8, bc.Y + 8, bc.Z + 8);
                float d = center.DistanceTo(listener);
                if (d < nearestWaterD)
                {
                    nearestWaterD = d;
                    var cls = RepresentativeClass(ch);
                    ambient = new WaterAudioCluster { Pos = center, Class = cls, Strength = Mathf.Clamp(1f - d / 40f, 0f, 0.8f) };
                    haveAmbient = d < 40f;
                }
            }
        }

        // strongest first, then trim to budget, then add the ambient bed
        _clusters.Sort(static (a, b) => b.Strength.CompareTo(a.Strength));
        int budget = Math.Max(0, Settings.AudioMaxSources - (haveAmbient ? 1 : 0));
        if (_clusters.Count > budget) _clusters.RemoveRange(budget, _clusters.Count - budget);
        if (haveAmbient) _clusters.Add(ambient);
    }

    private static WaterClass RepresentativeClass(WaterChunk ch)
    {
        int river = 0, calm = 0;
        for (int i = 0; i < WaterChunk.CV; i++)
        {
            if (ch.Cells[i].Level == 0) continue;
            var c = (WaterClass)ch.Class[i];
            if (c == WaterClass.River || c == WaterClass.Rapids) river++;
            else if (c == WaterClass.Calm || c == WaterClass.Shoreline) calm++;
        }
        return river > calm ? WaterClass.River : WaterClass.Calm;
    }

    private void ClassifyDirty()
    {
        foreach (var ch in Field.Chunks.Values)
            if (ch.ClassDirty) WaterClassifier.Classify(Field, _world, ch);
    }

    public void PlaceSource(Vector3I p) => _sim.PlaceSource(p);
    public void Remove(Vector3I p) => _sim.RemoveWater(p);

    /// <summary>Set/clear the cosmetic frozen flag on a water cell.</summary>
    public void Freeze(Vector3I p, bool on)
    {
        var c = Field.GetCell(p);
        if (c.Level == 0) return;
        c.Set(WaterFlags.Frozen, on);
        Field.SetCell(p, c); // marks the chunk for remesh
    }

    /// <summary>Flood (or drain) a bounded region up to <paramref name="seaY"/> with sea water.</summary>
    public void SetSeaLevel(bool on, int seaY, int cx, int cz, int half)
    {
        Settings.SeaLevelEnabled = on;
        Settings.SeaLevelY = seaY;
        if (on)
        {
            for (int z = cz - half; z <= cz + half; z++)
            for (int x = cx - half; x <= cx + half; x++)
            for (int y = seaY; y >= Math.Max(_world.MinY, seaY - 6); y--)
                if (_world.IsAir(x, y, z)) _sim.PlaceSeaSource(new Vector3I(x, y, z));
        }
        else
        {
            var rm = new List<Vector3I>();
            foreach (var kv in Field.Chunks)
            {
                var bc = kv.Value.Coord * WaterChunk.CS;
                var cells = kv.Value.Cells;
                for (int i = 0; i < WaterChunk.CV; i++)
                    if (cells[i].Has(WaterFlags.SeaFilled))
                        rm.Add(new Vector3I(bc.X + (i & 15), bc.Y + (i >> 8), bc.Z + ((i >> 4) & 15)));
            }
            foreach (var p in rm) _sim.RemoveWater(p);
        }
    }

    /// <summary>Step the sim a fixed number of ticks (tests / deterministic replay).</summary>
    public void DebugStep(int ticks)
    {
        for (int i = 0; i < ticks; i++) _sim.StepOneTick();
    }

    // stats
    public int ActiveCells => _sim.ActiveCount;
    public int LastProcessed => _sim.LastProcessed;
    public int WaterCells => Field.TotalWaterCells;
    public int WaterChunks => Field.ChunkCount;

    private void OnBlockChanged(Vector3I p, ushort oldId, ushort newId, int cause)
    {
        if (cause == WaterCause.WaterSim) return; // ignore our own writes (no feedback loop)
        _sim.OnExternalEdit(p, oldId, newId);
    }

    /// <summary>Order-independent checksum of the whole field (determinism tests).</summary>
    public ulong FieldChecksum()
    {
        ulong sum = 0;
        foreach (var kv in Field.Chunks)
        {
            var c = kv.Value;
            var bc = c.Coord * WaterChunk.CS;
            for (int i = 0; i < WaterChunk.CV; i++)
            {
                var cell = c.Cells[i];
                if (cell.Level == 0) continue;
                int lx = i & 15, lz = (i >> 4) & 15, ly = i >> 8;
                ulong h = Mix((ulong)(uint)(bc.X + lx), (ulong)(uint)(bc.Y + ly), (ulong)(uint)(bc.Z + lz),
                              cell.Level, cell.Flags, (byte)cell.FlowX, (byte)cell.FlowZ);
                sum += h; // commutative => order-independent
            }
        }
        return sum;
    }

    private static ulong Mix(ulong x, ulong y, ulong z, params int[] extra)
    {
        ulong h = 1469598103934665603UL;
        void Step(ulong v) { h ^= v; h *= 1099511628211UL; }
        Step(x); Step(y); Step(z);
        foreach (var e in extra) Step((ulong)(uint)e);
        return h;
    }
}
