namespace RAEngine.Water;

public enum ReflectionMode { Off, ScreenSpace, Planar }

/// <summary>
/// Quality-tier knobs. One struct drives sim budget, meshing, reflections,
/// foam/spray, submerged FX, and audio. Swap presets live; the manager
/// reconfigures subsystems without a restart.
/// </summary>
public struct WaterSettings
{
    // --- simulation ---
    public double TickHz;          // flow ticks/second (gameplay feel; same across tiers)
    public int MaxCellsPerTick;    // per-tick budget; overflow carried to next tick
    public int MaxTicksPerFrame;   // catch-up cap so a slow frame can't spiral
    public int SimRadiusChunks;    // only simulate near the viewer
    public bool SeaLevelEnabled;
    public int SeaLevelY;

    // --- meshing ---
    public int MaxRemeshPerFrame;
    public bool GreedyTopMerge;
    public float SurfaceDetail;    // shader ripple/normal sample scale

    // --- reflections ---
    public ReflectionMode Reflection;
    public int SsrSteps;
    public int PlanarResScale;     // SubViewport res = viewport / this

    // --- foam & spray ---
    public float FoamDensity;
    public int FoamCapacity;       // max live foam cubes
    public float SprayDensity;
    public int MaxSprayEmitters;

    // --- submerged & misc ---
    public bool CausticsEnabled;
    public bool UnderwaterBlur;
    public int AudioMaxSources;

    public static WaterSettings Low() => new()
    {
        TickHz = 5, MaxCellsPerTick = 2000, MaxTicksPerFrame = 1, SimRadiusChunks = 4,
        SeaLevelEnabled = false, SeaLevelY = 0,
        MaxRemeshPerFrame = 1, GreedyTopMerge = false, SurfaceDetail = 0.5f,
        Reflection = ReflectionMode.Off, SsrSteps = 0, PlanarResScale = 4,
        FoamDensity = 0f, FoamCapacity = 0, SprayDensity = 0f, MaxSprayEmitters = 0,
        CausticsEnabled = false, UnderwaterBlur = false, AudioMaxSources = 2,
    };

    public static WaterSettings Medium() => new()
    {
        TickHz = 6, MaxCellsPerTick = 6000, MaxTicksPerFrame = 2, SimRadiusChunks = 8,
        SeaLevelEnabled = false, SeaLevelY = 0,
        MaxRemeshPerFrame = 2, GreedyTopMerge = true, SurfaceDetail = 1f,
        Reflection = ReflectionMode.ScreenSpace, SsrSteps = 16, PlanarResScale = 3,
        FoamDensity = 0.5f, FoamCapacity = 256, SprayDensity = 0.5f, MaxSprayEmitters = 4,
        CausticsEnabled = false, UnderwaterBlur = false, AudioMaxSources = 4,
    };

    public static WaterSettings High() => new()
    {
        TickHz = 8, MaxCellsPerTick = 12000, MaxTicksPerFrame = 2, SimRadiusChunks = 12,
        SeaLevelEnabled = false, SeaLevelY = 0,
        MaxRemeshPerFrame = 4, GreedyTopMerge = true, SurfaceDetail = 1f,
        Reflection = ReflectionMode.ScreenSpace, SsrSteps = 24, PlanarResScale = 2,
        FoamDensity = 1f, FoamCapacity = 1024, SprayDensity = 1f, MaxSprayEmitters = 12,
        CausticsEnabled = true, UnderwaterBlur = false, AudioMaxSources = 8,
    };

    public static WaterSettings Ultra() => new()
    {
        TickHz = 10, MaxCellsPerTick = 24000, MaxTicksPerFrame = 3, SimRadiusChunks = 16,
        SeaLevelEnabled = false, SeaLevelY = 0,
        MaxRemeshPerFrame = 6, GreedyTopMerge = true, SurfaceDetail = 1.5f,
        // Screen-space is the shipping reflection method; the shader keeps a
        // planar (mode 2) path that a host can wire with a mirrored-camera rig.
        Reflection = ReflectionMode.ScreenSpace, SsrSteps = 48, PlanarResScale = 1,
        FoamDensity = 1.5f, FoamCapacity = 2048, SprayDensity = 1.5f, MaxSprayEmitters = 24,
        CausticsEnabled = true, UnderwaterBlur = true, AudioMaxSources = 12,
    };
}
