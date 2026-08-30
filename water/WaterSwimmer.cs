using Godot;

namespace RAEngine.Water;

/// <summary>
/// Default swimmer: samples the water field at the body's feet/head and returns
/// buoyancy, drag, and flow push. Buoyancy scales with submersion so the body
/// bobs to the surface and floats; river/waterfall flow nudges it along/down.
/// </summary>
public sealed class WaterSwimmer : IWaterSwimmer
{
    private readonly WaterField _field;

    private const float BuoyPerMetre = 16f;
    private const float DragFactor = 3.0f;
    private const float FlowForce = 2.5f;

    public WaterSwimmer(WaterField field) => _field = field;

    public SwimResponse Sample(Vector3 feet, Vector3 head, Vector3 velocity)
    {
        var r = new SwimResponse();
        var fc = CellAt(feet);
        var hc = CellAt(head);
        if (fc.Level == 0 && hc.Level == 0) return r;

        r.InWater = true;
        float surf = SurfaceY(feet);
        r.SurfaceY = surf;
        float depth = Mathf.Clamp(surf - feet.Y, 0f, 4f);
        r.SubmersionDepth = depth;
        r.HeadSubmerged = head.Y < SurfaceY(head);

        r.Buoyancy = new Vector3(0f, depth * BuoyPerMetre, 0f);
        r.Drag = DragFactor;

        var flow = new Vector3(fc.FlowX / 127f, fc.IsFalling ? -1f : 0f, fc.FlowZ / 127f);
        r.FlowPush = flow * FlowForce;
        return r;
    }

    private WaterCell CellAt(Vector3 p)
        => _field.GetCell(Mathf.FloorToInt(p.X), Mathf.FloorToInt(p.Y), Mathf.FloorToInt(p.Z));

    private float SurfaceY(Vector3 p)
    {
        int x = Mathf.FloorToInt(p.X), z = Mathf.FloorToInt(p.Z);
        int y = Mathf.FloorToInt(p.Y);
        if (_field.GetCell(x, y, z).Level == 0)
        {
            // maybe the head is above the surface; check one up
            if (_field.GetCell(x, y - 1, z).Level == 0) return p.Y;
            y -= 1;
        }
        while (_field.GetCell(x, y + 1, z).Level > 0) y++;
        var top = _field.GetCell(x, y, z);
        return y + (top.IsFalling ? 1f : top.Level / 8f * 0.875f + 0.0625f);
    }
}
