using Godot;

namespace RAEngine.Water;

/// <summary>
/// A swappable look for the water surface. Two stylistic presets plus a frozen
/// variant; fed into <see cref="WaterMaterialLibrary"/> to build a ShaderMaterial.
/// </summary>
public struct WaterPalette
{
    public Color Shallow;
    public Color Deep;
    public Color Foam;
    public Color SkyTint;
    public float Absorption;
    public float MaxDepth;
    public float FresnelPower;
    public float RippleStrength;
    public float RippleScale;
    public float EdgeFoamDist;
    public bool Ice;

    /// <summary>Stylized bright cyan/turquoise with crisp white foam (the reference look).</summary>
    public static WaterPalette Cyan() => new()
    {
        Shallow = new Color(0.30f, 0.78f, 0.88f),
        Deep = new Color(0.05f, 0.34f, 0.62f),
        Foam = new Color(0.93f, 0.98f, 1.0f),
        SkyTint = new Color(0.60f, 0.80f, 0.96f),
        Absorption = 0.26f,
        MaxDepth = 8f,
        FresnelPower = 4.0f,
        RippleStrength = 0.05f,
        RippleScale = 1.4f,
        EdgeFoamDist = 0.7f,
        Ice = false,
    };

    /// <summary>Naturalistic deep blue-green lake/river coloring.</summary>
    public static WaterPalette Natural() => new()
    {
        Shallow = new Color(0.20f, 0.46f, 0.44f),
        Deep = new Color(0.02f, 0.12f, 0.16f),
        Foam = new Color(0.88f, 0.93f, 0.92f),
        SkyTint = new Color(0.52f, 0.66f, 0.72f),
        Absorption = 0.5f,
        MaxDepth = 6f,
        FresnelPower = 5.0f,
        RippleStrength = 0.04f,
        RippleScale = 1.1f,
        EdgeFoamDist = 0.6f,
        Ice = false,
    };

    /// <summary>Frozen cosmetic variant — smooth, bright, opaque-ish.</summary>
    public static WaterPalette IcePreset() => new()
    {
        Shallow = new Color(0.72f, 0.86f, 0.92f),
        Deep = new Color(0.40f, 0.62f, 0.78f),
        Foam = new Color(0.97f, 0.99f, 1.0f),
        SkyTint = new Color(0.80f, 0.90f, 1.0f),
        Absorption = 0.8f,
        MaxDepth = 4f,
        FresnelPower = 6.0f,
        RippleStrength = 0.005f,
        RippleScale = 0.6f,
        EdgeFoamDist = 0.4f,
        Ice = true,
    };
}
