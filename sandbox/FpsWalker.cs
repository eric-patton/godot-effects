using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// First-person walker (CharacterBody3D) that integrates the water swimmer:
/// on land it walks/jumps with gravity; in water it floats (buoyancy), is
/// slowed (drag), pushed by flow, and swims up on jump.
/// </summary>
public partial class FpsWalker : CharacterBody3D
{
    [Export] public float WalkSpeed = 6f;
    [Export] public float SwimSpeed = 5f;
    [Export] public float JumpSpeed = 6f;
    [Export] public float Gravity = 18f;
    [Export] public float Sensitivity = 0.0025f;

    public Camera3D Eye { get; private set; }
    private IWaterSwimmer _swimmer;
    private float _yaw, _pitch;
    private bool _look;

    public override void _Ready()
    {
        var caps = new CapsuleShape3D { Radius = 0.35f, Height = 1.7f };
        var col = new CollisionShape3D { Shape = caps };
        AddChild(col);
        Eye = new Camera3D { Position = new Vector3(0f, 0.7f, 0f) };
        AddChild(Eye);
    }

    public void SetSwimmer(IWaterSwimmer s) => _swimmer = s;

    public void SetActive(bool active)
    {
        SetPhysicsProcess(active);
        if (Eye != null) Eye.Current = active;
    }

    public override void _UnhandledInput(InputEvent ev)
    {
        if (ev is InputEventMouseButton mb && mb.ButtonIndex == MouseButton.Right)
        {
            _look = mb.Pressed;
            Input.MouseMode = _look ? Input.MouseModeEnum.Captured : Input.MouseModeEnum.Visible;
        }
        else if (ev is InputEventMouseMotion mm && _look)
        {
            _yaw -= mm.Relative.X * Sensitivity;
            _pitch = Mathf.Clamp(_pitch - mm.Relative.Y * Sensitivity, -1.5f, 1.5f);
            RotationDegrees = new Vector3(0f, Mathf.RadToDeg(_yaw), 0f);
            Eye.RotationDegrees = new Vector3(Mathf.RadToDeg(_pitch), 0f, 0f);
        }
    }

    public override void _PhysicsProcess(double delta)
    {
        float dt = (float)delta;
        var vel = Velocity;

        var basis = new Basis(Vector3.Up, _yaw);
        var input = Vector3.Zero;
        if (Input.IsKeyPressed(Key.W)) input -= basis.Z;
        if (Input.IsKeyPressed(Key.S)) input += basis.Z;
        if (Input.IsKeyPressed(Key.A)) input -= basis.X;
        if (Input.IsKeyPressed(Key.D)) input += basis.X;
        input = input.Normalized();

        var feet = GlobalPosition;
        var head = GlobalPosition + new Vector3(0f, 1.5f, 0f);
        var resp = _swimmer?.Sample(feet, head, vel) ?? default;

        if (resp.InWater)
        {
            // float + swim
            vel.Y += (-Gravity * 0.25f + resp.Buoyancy.Y) * dt;
            vel += resp.FlowPush * dt;
            vel += input * SwimSpeed * dt * 4f;
            if (Input.IsKeyPressed(Key.Space)) vel.Y += SwimSpeed * dt * 3f;
            // drag
            float damp = 1f / (1f + resp.Drag * dt);
            vel *= damp;
        }
        else
        {
            vel.X = input.X * WalkSpeed;
            vel.Z = input.Z * WalkSpeed;
            if (IsOnFloor())
            {
                if (Input.IsKeyPressed(Key.Space)) vel.Y = JumpSpeed;
                else vel.Y = -0.1f;
            }
            else vel.Y -= Gravity * dt;
        }

        Velocity = vel;
        MoveAndSlide();
    }
}
