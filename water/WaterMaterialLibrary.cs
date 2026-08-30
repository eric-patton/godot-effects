using Godot;

namespace RAEngine.Water;

/// <summary>
/// Builds and updates the water <see cref="ShaderMaterial"/> from a palette and
/// quality settings. The shader path is injected so each host points at its own
/// copy of the asset.
/// </summary>
public sealed class WaterMaterialLibrary
{
    private readonly Shader _shader;

    public WaterMaterialLibrary(string shaderPath)
    {
        _shader = ResourceLoader.Load<Shader>(shaderPath);
        if (_shader == null)
            GD.PushError($"[water] could not load shader at {shaderPath}");
    }

    public ShaderMaterial Create(WaterPalette p, WaterSettings s)
    {
        var m = new ShaderMaterial { Shader = _shader, RenderPriority = -1 }; // below other transparents
        ApplyPalette(m, p);
        ApplySettings(m, s);
        return m;
    }

    public void ApplyPalette(ShaderMaterial m, WaterPalette p)
    {
        m.SetShaderParameter("shallow_color", p.Shallow);
        m.SetShaderParameter("deep_color", p.Deep);
        m.SetShaderParameter("foam_color", p.Foam);
        m.SetShaderParameter("sky_tint", p.SkyTint);
        m.SetShaderParameter("absorption", p.Absorption);
        m.SetShaderParameter("max_depth", p.MaxDepth);
        m.SetShaderParameter("fresnel_power", p.FresnelPower);
        m.SetShaderParameter("ripple_strength", p.RippleStrength);
        m.SetShaderParameter("ripple_scale", p.RippleScale);
        m.SetShaderParameter("edge_foam_dist", p.EdgeFoamDist);
        m.SetShaderParameter("is_ice", p.Ice);
    }

    public void ApplySettings(ShaderMaterial m, WaterSettings s)
    {
        m.SetShaderParameter("surface_detail", s.SurfaceDetail);
        m.SetShaderParameter("reflection_mode", (int)s.Reflection);
        m.SetShaderParameter("ssr_steps", s.SsrSteps);
    }
}
