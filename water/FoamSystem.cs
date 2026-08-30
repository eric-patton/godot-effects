using System;
using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Chunky voxel foam: small white/cyan cubes spawned at turbulent cells
/// (plunge pools, rapids, waterfall lips), updated ballistically and faded out.
/// One MultiMesh, fixed-capacity ring buffer — never allocates per spawn. This
/// is the literal "foam blocks" look from the references.
/// </summary>
public sealed class FoamSystem
{
    private struct Particle
    {
        public Vector3 Pos, Vel;
        public float Age, Ttl, Size;
        public bool Alive;
    }

    private readonly Node3D _root;
    private readonly WaterField _field;
    private readonly Func<WaterSettings> _settings;

    private MultiMeshInstance3D _mmi;
    private MultiMesh _mm;
    private Particle[] _pool = Array.Empty<Particle>();
    private int _cursor;
    private readonly Random _rng = new(0xF0A);
    private float _spawnCarry;
    private readonly List<Vector3> _sites = new();

    private const float Gravity = 7f;
    private const float Drag = 1.4f;

    public int LiveCount { get; private set; }

    public FoamSystem(Node3D root, WaterField field, Func<WaterSettings> settings)
    {
        _root = root; _field = field; _settings = settings;
        Configure(settings());
    }

    public void Configure(WaterSettings s)
    {
        int cap = Math.Max(0, s.FoamCapacity);
        _pool = new Particle[cap];
        _cursor = 0;

        if (_mmi == null)
        {
            _mm = new MultiMesh
            {
                TransformFormat = MultiMesh.TransformFormatEnum.Transform3D,
                UseColors = true,
                Mesh = new BoxMesh { Size = Vector3.One },
            };
            _mmi = new MultiMeshInstance3D
            {
                Multimesh = _mm,
                CastShadow = GeometryInstance3D.ShadowCastingSetting.Off,
                MaterialOverride = new StandardMaterial3D
                {
                    ShadingMode = BaseMaterial3D.ShadingModeEnum.Unshaded,
                    VertexColorUseAsAlbedo = true,
                    Transparency = BaseMaterial3D.TransparencyEnum.Alpha,
                    AlbedoColor = Colors.White,
                    RenderPriority = 2, // draw after the water body
                },
            };
            _root.AddChild(_mmi);
        }
        _mm.InstanceCount = cap;
        for (int i = 0; i < cap; i++) _mm.SetInstanceTransform(i, HiddenXform());
    }

    public void Update(double dt)
    {
        var s = _settings();
        if (_pool.Length == 0 || s.FoamDensity <= 0f)
        {
            if (_mmi != null) _mmi.Visible = false;
            return;
        }
        if (_mmi != null) _mmi.Visible = true;

        Spawn(dt, s);

        float fdt = (float)dt;
        int live = 0;
        for (int i = 0; i < _pool.Length; i++)
        {
            ref var p = ref _pool[i];
            if (!p.Alive) { _mm.SetInstanceTransform(i, HiddenXform()); continue; }
            p.Age += fdt;
            if (p.Age >= p.Ttl) { p.Alive = false; _mm.SetInstanceTransform(i, HiddenXform()); continue; }
            p.Vel.Y -= Gravity * fdt;
            p.Vel *= Mathf.Max(0f, 1f - Drag * fdt);
            p.Pos += p.Vel * fdt;

            float life = 1f - p.Age / p.Ttl;
            float scale = p.Size * (0.5f + 0.5f * life);
            _mm.SetInstanceTransform(i, new Transform3D(Basis.Identity.Scaled(Vector3.One * scale), p.Pos));
            var col = new Color(0.9f, 0.97f, 1.0f, Mathf.Clamp(life * 1.3f, 0f, 0.95f));
            _mm.SetInstanceColor(i, col);
            live++;
        }
        LiveCount = live;
    }

    private void Spawn(double dt, WaterSettings s)
    {
        // collect current turbulent sites
        _sites.Clear();
        foreach (var ch in _field.Chunks.Values)
        {
            if (ch.Turbulent.Count == 0) continue;
            var bc = ch.Coord * WaterChunk.CS;
            foreach (int idx in ch.Turbulent)
            {
                int lx = idx & 15, lz = (idx >> 4) & 15, ly = idx >> 8;
                _sites.Add(new Vector3(bc.X + lx + 0.5f, bc.Y + ly + 0.9f, bc.Z + lz + 0.5f));
            }
        }
        if (_sites.Count == 0) return;

        float rate = 55f * s.FoamDensity;            // cubes per second per site, scaled
        float want = rate * (float)dt * Mathf.Min(_sites.Count, 64) + _spawnCarry;
        int count = (int)want;
        _spawnCarry = want - count;

        for (int n = 0; n < count; n++)
        {
            var site = _sites[_rng.Next(_sites.Count)];
            ref var p = ref _pool[_cursor];
            _cursor = (_cursor + 1) % _pool.Length;
            p.Alive = true;
            p.Age = 0f;
            p.Ttl = 0.45f + (float)_rng.NextDouble() * 0.7f;
            p.Size = 0.16f + (float)_rng.NextDouble() * 0.22f;
            p.Pos = site + new Vector3(Rand(0.4f), Rand(0.2f), Rand(0.4f));
            p.Vel = new Vector3(Rand(1.4f), 1.2f + (float)_rng.NextDouble() * 2.4f, Rand(1.4f));
        }
    }

    private float Rand(float m) => ((float)_rng.NextDouble() * 2f - 1f) * m;

    private static Transform3D HiddenXform() => new(Basis.Identity.Scaled(Vector3.Zero), Vector3.Zero);
}
