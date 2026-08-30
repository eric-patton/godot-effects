using Godot;

namespace RAEngine.Water;

/// <summary>What the water does to a body sampling it this physics frame.</summary>
public struct SwimResponse
{
    public bool InWater;
    public bool HeadSubmerged;
    public float SubmersionDepth; // metres the feet are below the surface
    public Vector3 Buoyancy;      // upward acceleration to add
    public float Drag;            // velocity damping factor (per second)
    public Vector3 FlowPush;      // acceleration from river/waterfall flow
    public float SurfaceY;        // water surface height at the body
}

/// <summary>
/// Lets a character controller ask the water how to move it. The module provides
/// <see cref="WaterSwimmer"/>; a host controller calls Sample each physics frame.
/// Optional — purely additive to whatever movement the host already has.
/// </summary>
public interface IWaterSwimmer
{
    SwimResponse Sample(Vector3 feet, Vector3 head, Vector3 velocity);
}
