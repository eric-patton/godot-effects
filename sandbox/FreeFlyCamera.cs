using Godot;

namespace Sandbox.Water;

/// <summary>
/// Creative free-fly camera: WASD to move on the view plane, Q/E down/up,
/// hold Shift to boost, hold right mouse button to look around. Yaw/pitch are
/// tracked explicitly so the camera never accumulates roll.
/// </summary>
public partial class FreeFlyCamera : Camera3D
{
    [Export] public float Speed = 14f;
    [Export] public float Boost = 4f;
    [Export] public float Sensitivity = 0.0025f;

    private float _yaw;
    private float _pitch;
    private Vector3 _pos;
    private bool _looking;

    private bool _posed;

    public override void _Ready()
    {
        if (_posed) return;
        _pos = GlobalPosition;
        var e = GlobalBasis.GetEuler(); // YXZ
        _yaw = e.Y;
        _pitch = e.X;
    }

    /// <summary>Place the camera and aim it at a target. Safe to call any time
    /// (drives the same yaw/pitch/pos state that <see cref="_Process"/> uses).</summary>
    public void SetPose(Vector3 pos, Vector3 lookAt)
    {
        _pos = pos;
        var dir = (lookAt - pos).Normalized();
        _pitch = Mathf.Asin(Mathf.Clamp(dir.Y, -1f, 1f));
        _yaw = Mathf.Atan2(-dir.X, -dir.Z);
        _posed = true;
        GlobalTransform = new Transform3D(Basis.FromEuler(new Vector3(_pitch, _yaw, 0f)), _pos);
    }

    public override void _UnhandledInput(InputEvent ev)
    {
        if (ev is InputEventMouseButton mb && mb.ButtonIndex == MouseButton.Right)
        {
            _looking = mb.Pressed;
            Input.MouseMode = _looking ? Input.MouseModeEnum.Captured : Input.MouseModeEnum.Visible;
        }
        else if (ev is InputEventMouseMotion mm && _looking)
        {
            _yaw -= mm.Relative.X * Sensitivity;
            _pitch = Mathf.Clamp(_pitch - mm.Relative.Y * Sensitivity, -1.55f, 1.55f);
        }
    }

    public override void _Process(double delta)
    {
        var basis = Basis.FromEuler(new Vector3(_pitch, _yaw, 0f));

        var dir = Vector3.Zero;
        if (Input.IsKeyPressed(Key.W)) dir -= basis.Z;
        if (Input.IsKeyPressed(Key.S)) dir += basis.Z;
        if (Input.IsKeyPressed(Key.A)) dir -= basis.X;
        if (Input.IsKeyPressed(Key.D)) dir += basis.X;
        if (Input.IsKeyPressed(Key.E)) dir += Vector3.Up;
        if (Input.IsKeyPressed(Key.Q)) dir -= Vector3.Up;

        if (dir != Vector3.Zero)
        {
            float s = Speed * (Input.IsKeyPressed(Key.Shift) ? Boost : 1f);
            _pos += dir.Normalized() * s * (float)delta;
        }

        GlobalTransform = new Transform3D(basis, _pos);
    }
}
