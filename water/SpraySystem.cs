using System;
using System.Collections.Generic;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Airy mist/spray at waterfall lips and plunge pools. A small pool of
/// GpuParticles3D emitters is repositioned each frame to the strongest turbulent
/// sites (never spawned per-site), so the particle budget stays bounded.
/// </summary>
public sealed class SpraySystem
{
    private readonly Node3D _root;
    private readonly WaterField _field;
    private readonly Func<WaterSettings> _settings;

    private GpuParticles3D[] _emitters = Array.Empty<GpuParticles3D>();
    private Texture2D _tex;
    private readonly List<Vector3> _sites = new();

    public SpraySystem(Node3D root, WaterField field, Func<WaterSettings> settings)
    {
        _root = root; _field = field; _settings = settings;
        _tex = MakeSoftTexture();
        Configure(settings());
    }

    public void Configure(WaterSettings s)
    {
        int n = Math.Max(0, s.MaxSprayEmitters);
        foreach (var e in _emitters) e?.QueueFree();
        _emitters = new GpuParticles3D[n];
        for (int i = 0; i < n; i++)
        {
            var e = new GpuParticles3D
            {
                Amount = Math.Max(4, (int)(20 * s.SprayDensity)),
                Lifetime = 1.2,
                Emitting = false,
                LocalCoords = false,        // emitted mist stays in world when emitter moves
                CastShadow = GeometryInstance3D.ShadowCastingSetting.Off,
                ProcessMaterial = MakeProcess(),
                DrawPass1 = MakeQuad(),
            };
            _root.AddChild(e);
            _emitters[i] = e;
        }
    }

    public void Update(double dt)
    {
        if (_emitters.Length == 0) return;
        var s = _settings();
        if (s.SprayDensity <= 0f) { foreach (var e in _emitters) e.Emitting = false; return; }

        // collect spray sites (lip + plunge already in Turbulent)
        _sites.Clear();
        foreach (var ch in _field.Chunks.Values)
        {
            if (ch.Turbulent.Count == 0) continue;
            var bc = ch.Coord * WaterChunk.CS;
            foreach (int idx in ch.Turbulent)
            {
                int lx = idx & 15, lz = (idx >> 4) & 15, ly = idx >> 8;
                _sites.Add(new Vector3(bc.X + lx + 0.5f, bc.Y + ly + 1.0f, bc.Z + lz + 0.5f));
            }
        }

        // assign emitters to spread-out sites; turn the rest off
        int assigned = 0;
        if (_sites.Count > 0)
        {
            int stride = Mathf.Max(1, _sites.Count / _emitters.Length);
            for (int i = 0; i < _emitters.Length && assigned < _sites.Count; i++)
            {
                var e = _emitters[i];
                e.GlobalPosition = _sites[(i * stride) % _sites.Count];
                e.Emitting = true;
                assigned++;
            }
        }
        for (int i = assigned; i < _emitters.Length; i++) _emitters[i].Emitting = false;
    }

    private static ParticleProcessMaterial MakeProcess()
    {
        return new ParticleProcessMaterial
        {
            Direction = new Vector3(0, 1, 0),
            Spread = 38f,
            Gravity = new Vector3(0, -3.5f, 0),
            InitialVelocityMin = 1.8f,
            InitialVelocityMax = 4.2f,
            ScaleMin = 0.35f,
            ScaleMax = 0.9f,
            Color = new Color(1f, 1f, 1f, 0.55f),
            DampingMin = 0.5f,
            DampingMax = 1.2f,
        };
    }

    private QuadMesh MakeQuad()
    {
        return new QuadMesh
        {
            Size = new Vector2(0.6f, 0.6f),
            Material = new StandardMaterial3D
            {
                ShadingMode = BaseMaterial3D.ShadingModeEnum.Unshaded,
                Transparency = BaseMaterial3D.TransparencyEnum.Alpha,
                BlendMode = BaseMaterial3D.BlendModeEnum.Mix,
                BillboardMode = BaseMaterial3D.BillboardModeEnum.Particles,
                AlbedoTexture = _tex,
                VertexColorUseAsAlbedo = true,
                RenderPriority = 3,
                CullMode = BaseMaterial3D.CullModeEnum.Disabled,
            },
        };
    }

    private static Texture2D MakeSoftTexture()
    {
        const int N = 48;
        var img = Image.CreateEmpty(N, N, false, Image.Format.Rgba8);
        float c = (N - 1) * 0.5f;
        for (int y = 0; y < N; y++)
        for (int x = 0; x < N; x++)
        {
            float dx = (x - c) / c, dy = (y - c) / c;
            float d = Mathf.Sqrt(dx * dx + dy * dy);
            float a = Mathf.Clamp(1f - d, 0f, 1f);
            a = a * a; // soft falloff
            img.SetPixel(x, y, new Color(1f, 1f, 1f, a));
        }
        return ImageTexture.CreateFromImage(img);
    }
}
