using System;
using Godot;

namespace RAEngine.Water;

/// <summary>
/// Full-screen underwater pass: when the camera goes below a water surface, a
/// blue fog/tint + caustics overlay cross-fades in. Detection uses the water
/// field (camera cell is water and the eye is below that cell's surface height).
/// </summary>
public sealed class SubmergedFx
{
    private readonly WaterField _field;
    private readonly Func<WaterSettings> _settings;
    private readonly CanvasLayer _layer;
    private readonly ColorRect _rect;
    private readonly ShaderMaterial _mat;
    private float _blend;

    public SubmergedFx(Node root, WaterField field, Func<WaterSettings> settings, string shaderPath)
    {
        _field = field; _settings = settings;
        _layer = new CanvasLayer { Layer = 10 };
        root.AddChild(_layer);

        _mat = new ShaderMaterial { Shader = ResourceLoader.Load<Shader>(shaderPath) };
        _rect = new ColorRect { Material = _mat, MouseFilter = Control.MouseFilterEnum.Ignore };
        _rect.SetAnchorsPreset(Control.LayoutPreset.FullRect);
        _rect.Visible = false;
        _layer.AddChild(_rect);
    }

    /// <returns>true while the camera is underwater.</returns>
    public bool Update(double dt, Camera3D cam)
    {
        bool sub = cam != null && IsSubmerged(cam.GlobalPosition);
        _blend = Mathf.MoveToward(_blend, sub ? 1f : 0f, (float)dt * 5f);
        _rect.Visible = _blend > 0.001f;
        if (_rect.Visible)
        {
            _mat.SetShaderParameter("submerge", _blend);
            _mat.SetShaderParameter("caustics_on", _settings().CausticsEnabled);
        }
        return sub;
    }

    private bool IsSubmerged(Vector3 p)
    {
        int x = Mathf.FloorToInt(p.X), y = Mathf.FloorToInt(p.Y), z = Mathf.FloorToInt(p.Z);
        var cell = _field.GetCell(x, y, z);
        if (cell.Level == 0) return false;
        float surf = y + (cell.IsFalling ? 1f : cell.Level / 8f * 0.875f + 0.0625f);
        return p.Y < surf;
    }
}
