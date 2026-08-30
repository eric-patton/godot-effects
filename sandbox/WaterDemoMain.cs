using Godot;
using RAEngine.Water;

namespace Sandbox.Water;

/// <summary>
/// Root of the voxel-water demo (M12): assembles the showcase world (calm lake,
/// river, waterfall, build yard), wires the full water module, and provides
/// creative build tools + live quality/palette/freeze switching.
///
/// Controls: RMB look · WASD/QE move · Tab fly/FPS · LMB use tool ·
/// 1 stone 2 dirt 3 glass 4 water-source 5 remove 6 freeze · P palette ·
/// F1-F4 quality · L sea level · F5/F6/F7 jump to lake/waterfall/river.
/// </summary>
public partial class WaterDemoMain : Node3D
{
    private enum Tool { PlaceBlock, Source, Remove, Freeze }

    private SandboxWorld _world;
    private SandboxVoxelWorldAdapter _adapter;
    private WaterManager _manager;
    private WaterMaterialLibrary _matLib;
    private ShaderMaterial _material;
    private WaterSettings _settings;

    private FreeFlyCamera _freeCam;
    private FpsWalker _walker;
    private bool _fps;

    private Tool _tool = Tool.Source;
    private ushort _block = SandboxBlocks.Stone;
    private int _palette;            // 0 cyan, 1 natural
    private string _tierName = "High";
    private bool _sea;

    private Label _stats, _help;

    public override void _Ready()
    {
        GD.Print("[WaterDemo] Milestone 12 boot — showcases + build tools + UI.");
        SetupEnvironment();

        _world = new SandboxWorld();
        AddChild(_world);

        _settings = WaterSettings.High();
        _adapter = new SandboxVoxelWorldAdapter(_world);
        _manager = new WaterManager(_adapter, _settings);

        var waterRoot = new Node3D { Name = "WaterRoot" };
        AddChild(waterRoot);
        _matLib = new WaterMaterialLibrary("res://water_demo/shaders/water.gdshader");
        _material = _matLib.Create(WaterPalette.Cyan(), _settings);
        _manager.AttachRenderer(waterRoot, _material);
        _manager.AttachFx(waterRoot);
        _manager.AttachSubmergedFx(this, "res://water_demo/shaders/water_underwater.gdshader");
        _manager.AttachAudio(new SandboxWaterAudio(this));

        ShowcaseBuilder.Build(_world, _manager);
        _world.RemeshAll();
        WaterSimSelfTest.Run();

        _freeCam = new FreeFlyCamera();
        AddChild(_freeCam);
        _walker = new FpsWalker();
        AddChild(_walker);
        _walker.GlobalPosition = new Vector3(0f, 6f, 0f);
        _walker.SetSwimmer(_manager.Swimmer);

        SetMode(false);
        JumpTo("lake");
        BuildHud();
    }

    public override void _Process(double delta)
    {
        if (_manager == null) return;
        _manager.Tick(delta);
        if (_stats != null)
            _stats.Text = $"tool: {ToolName()}   palette: {(_palette == 0 ? "cyan" : "natural")}   quality: {_tierName}   sea: {(_sea ? "ON" : "off")}\n"
                        + $"water cells: {_manager.WaterCells}   active: {_manager.ActiveCells}   foam: {_manager.FoamCount}   mesh nodes: {_manager.Renderer?.VisibleChunks}";
    }

    public override void _UnhandledInput(InputEvent ev)
    {
        if (ev is InputEventMouseButton mb && mb.Pressed && mb.ButtonIndex == MouseButton.Left)
        {
            ApplyTool();
            return;
        }
        if (ev is not InputEventKey k || !k.Pressed || k.Echo) return;
        switch (k.Keycode)
        {
            case Key.Tab: SetMode(!_fps); break;
            case Key.Key1: _tool = Tool.PlaceBlock; _block = SandboxBlocks.Stone; break;
            case Key.Key2: _tool = Tool.PlaceBlock; _block = SandboxBlocks.Dirt; break;
            case Key.Key3: _tool = Tool.PlaceBlock; _block = SandboxBlocks.Glass; break;
            case Key.Key4: _tool = Tool.Source; break;
            case Key.Key5: _tool = Tool.Remove; break;
            case Key.Key6: _tool = Tool.Freeze; break;
            case Key.P: CyclePalette(); break;
            case Key.F1: SetTier(WaterSettings.Low(), "Low"); break;
            case Key.F2: SetTier(WaterSettings.Medium(), "Medium"); break;
            case Key.F3: SetTier(WaterSettings.High(), "High"); break;
            case Key.F4: SetTier(WaterSettings.Ultra(), "Ultra"); break;
            case Key.L: ToggleSea(); break;
            case Key.F5: JumpTo("lake"); break;
            case Key.F6: JumpTo("waterfall"); break;
            case Key.F7: JumpTo("river"); break;
        }
    }

    private void ApplyTool()
    {
        Camera3D cam = _fps ? _walker.Eye : _freeCam;
        var from = cam.GlobalPosition;
        var dir = -cam.GlobalTransform.Basis.Z;
        float reach = _fps ? 8f : 48f; // short reach on foot, long in creative fly
        if (!_adapter.Raycast(from, dir, reach, out var cell, out var nrm, out _)) return;
        var front = cell + nrm;
        switch (_tool)
        {
            case Tool.PlaceBlock:
                _world.SetBlock(front.X, front.Y, front.Z, _block);
                break;
            case Tool.Source:
                _manager.PlaceSource(front);
                break;
            case Tool.Remove:
                if (_world.GetBlockId(front.X, front.Y, front.Z) == SandboxBlocks.Water) _manager.Remove(front);
                else _world.SetBlock(cell.X, cell.Y, cell.Z, SandboxBlocks.Air);
                break;
            case Tool.Freeze:
                // brush a patch and freeze each column up to its surface so ice reads clearly
                for (int dz = -3; dz <= 3; dz++)
                for (int dx = -3; dx <= 3; dx++)
                for (int dy = 0; dy <= 8; dy++)
                {
                    var fp = front + new Vector3I(dx, dy, dz);
                    if (_world.GetBlockId(fp.X, fp.Y, fp.Z) == SandboxBlocks.Water) _manager.Freeze(fp, true);
                }
                break;
        }
    }

    private void CyclePalette()
    {
        _palette = (_palette + 1) % 2;
        _matLib.ApplyPalette(_material, _palette == 0 ? WaterPalette.Cyan() : WaterPalette.Natural());
    }

    private void SetTier(WaterSettings s, string name)
    {
        _settings = s;
        _tierName = name;
        _manager.Settings = s;
        _manager.ApplySettings();
        _matLib.ApplySettings(_material, s);
    }

    private void ToggleSea()
    {
        _sea = !_sea;
        _manager.SetSeaLevel(_sea, 2, 0, (int)ShowcaseBuilder.YardZ, 13);
    }

    private void SetMode(bool fps)
    {
        _fps = fps;
        _walker.SetActive(fps);
        _freeCam.Current = !fps;
        _freeCam.SetProcess(!fps);
        _manager.SetCamera(fps ? _walker.Eye : _freeCam);
    }

    private void JumpTo(string what)
    {
        if (_fps) SetMode(false);
        switch (what)
        {
            case "lake": _freeCam.SetPose(new Vector3(0f, 12f, 26f), new Vector3(0f, 0f, 0f)); break;
            case "waterfall": _freeCam.SetPose(new Vector3(ShowcaseBuilder.WaterfallX + 2f, 14f, 24f), new Vector3(ShowcaseBuilder.WaterfallX, 6f, -4f)); break;
            case "river": _freeCam.SetPose(new Vector3(ShowcaseBuilder.RiverX + 16f, 14f, 6f), new Vector3(ShowcaseBuilder.RiverX, 3f, 0f)); break;
        }
    }

    private string ToolName() => _tool switch
    {
        Tool.PlaceBlock => $"place {(_block == SandboxBlocks.Stone ? "stone" : _block == SandboxBlocks.Dirt ? "dirt" : "glass")}",
        Tool.Source => "water source",
        Tool.Remove => "remove",
        Tool.Freeze => "freeze",
        _ => "?",
    };

    private void SetupEnvironment()
    {
        var env = new Godot.Environment
        {
            BackgroundMode = Godot.Environment.BGMode.Sky,
            Sky = new Sky { SkyMaterial = new ProceduralSkyMaterial() },
            AmbientLightSource = Godot.Environment.AmbientSource.Sky,
            TonemapMode = Godot.Environment.ToneMapper.Aces,
            SsaoEnabled = true,
        };
        AddChild(new WorldEnvironment { Environment = env });

        var sun = new DirectionalLight3D { ShadowEnabled = true, LightEnergy = 1.25f };
        sun.RotationDegrees = new Vector3(-52f, -41f, 0f);
        AddChild(sun);
    }

    private void BuildHud()
    {
        var ui = new CanvasLayer();
        AddChild(ui);
        _stats = new Label { Position = new Vector2(16f, 12f) };
        ui.AddChild(_stats);
        _help = new Label
        {
            Position = new Vector2(16f, 58f),
            Text = "RMB look · WASD/QE move · Tab fly/FPS · LMB use tool\n"
                 + "1 stone  2 dirt  3 glass  4 water  5 remove  6 freeze\n"
                 + "P palette · F1-F4 quality · L sea level · F5/F6/F7 lake/waterfall/river",
        };
        _help.Modulate = new Color(1, 1, 1, 0.75f);
        ui.AddChild(_help);
    }
}
