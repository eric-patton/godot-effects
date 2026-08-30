# Voxel Water System — Porting Guide (→ ra-engine)

A self-contained, Minecraft-style voxel water system: water has discrete levels,
spreads, falls, and a classifier tags every cell **calm / river / waterfall** so
the renderer, foam, spray, and audio all react automatically. Built and tuned in
the `godot-effects` sandbox; this guide drops it into ra-engine.

The whole module lives in `water/` (namespace `RAEngine.Water`) and references
**only `Godot` core types + `System.*`** — it compiles unchanged in both repos.
The single integration point is the `IVoxelWorld` interface.

---

## 1. Files to copy

Copy the **`water/`** folder (18 `.cs` files) into ra-engine, e.g. `scripts/water/`:

| File | Role |
|---|---|
| `IVoxelWorld.cs` | **The seam.** Block reads/writes + change event the module needs. |
| `WaterCell.cs` `WaterChunk.cs` `WaterField.cs` | Side-channel water state (level/flow/flags), sparse per-chunk, host-identical indexing. |
| `WaterSimulation.cs` | Flow algorithm (spread/fall/dry/sources/sea), self-scheduling active set, deterministic. |
| `WaterClassifier.cs` | Per-cell calm/river/waterfall + lip/plunge/rapids/shoreline tags. |
| `WaterMeshBuilder.cs` `WaterMeshData.cs` | Worker-thread water surface meshing (sub-cell heights). |
| `WaterRenderer.cs` | Per-chunk water `MeshInstance3D`, async build/apply, seam-correct. |
| `WaterMaterialLibrary.cs` `WaterPalette.cs` | Builds the water `ShaderMaterial` from a palette + tier. |
| `FoamSystem.cs` `SpraySystem.cs` | Voxel foam cubes (MultiMesh) + GPU mist at turbulent cells. |
| `SubmergedFx.cs` | Underwater fog/tint/caustics full-screen pass. |
| `IWaterAudio.cs` `IWaterSwimmer.cs` `WaterSwimmer.cs` | Optional audio + buoyancy. |
| `WaterManager.cs` | **Façade.** Owns everything; you call `Tick(dt)`. |
| `WaterSettings.cs` | Quality tiers (Low/Medium/High/Ultra). |

Also copy the shader/asset folder (`water_demo/shaders/water.gdshader` and
`water_underwater.gdshader`) somewhere in ra-engine (e.g. `assets/shaders/`).
Paths are injected, so each repo points at its own copy.

---

## 2. The one thing you must write: the adapter

ra-engine's blocks are bare `ushort` ids — exactly what the module expects. Wrap
`VoxelWorld` in an `IVoxelWorld`:

```csharp
using Godot;
using RAEngine.Water;

public sealed class RaEngineWaterWorld : IVoxelWorld
{
    private readonly VoxelWorld _w;
    private readonly ushort _water, _air;

    public RaEngineWaterWorld(VoxelWorld w)
    {
        _w = w;
        _water = BlockRegistry.IdOf("water");
        _air = 0;
        // re-raise ra-engine's BlockChanged, but DROP our own writes (no feedback loop)
        _w.BlockChanged += (pos, oldId, newId, cause) =>
        {
            if (cause == BlockChangeCause.WaterSim) return;  // add this enum value
            BlockChanged?.Invoke(pos, oldId, newId, (int)cause);
        };
    }

    public ushort WaterId => _water;
    public ushort AirId => _air;
    public int MinY => -16;
    public int MaxY => 64;

    public ushort GetBlockId(int x, int y, int z) => _w.GetBlockId(x, y, z);
    public bool IsSolid(int x, int y, int z) => _w.IsSolid(new Vector3I(x, y, z));
    public bool IsAir(int x, int y, int z) => _w.GetBlockId(x, y, z) == _air;

    public void SetBlock(int x, int y, int z, ushort id, bool remesh = true, int cause = WaterCause.WaterSim)
        => _w.SetBlock(x, y, z, id, remesh, BlockChangeCause.WaterSim);  // always tag WaterSim

    public bool Raycast(Vector3 o, Vector3 d, float maxDist,
        out Vector3I cell, out Vector3I faceNormal, out Vector3 hitPos)
    {
        var hit = VoxelRay.Cast(_w, o, d, maxDist);
        cell = hit.Block; faceNormal = hit.Normal; hitPos = o + d.Normalized() * hit.Distance;
        return hit.Hit; // adapt to your VoxelRay.Hit shape
    }

    public event System.Action<Vector3I, ushort, ushort, int> BlockChanged;
}
```

Two ra-engine edits this implies:
- Add `WaterSim` to `BlockChangeCause` (so the adapter can tag the module's own writes and ignore them on the way back).
- The module calls `SetBlock(..., remesh:false, ...)` for water — water surfaces are rendered by `WaterRenderer`, not your opaque/greedy mesher. Tell your mesher to **emit nothing for `RenderType.Water` faces** (it already special-cases water; just make it skip the water surface so you don't draw it twice).

---

## 3. Wire it up (once, at world load)

```csharp
var adapter = new RaEngineWaterWorld(voxelWorld);
var water = new WaterManager(adapter, WaterSettings.High());

var root = new Node3D { Name = "WaterRoot" };
AddChild(root);

var matLib = new WaterMaterialLibrary("res://assets/shaders/water.gdshader");
water.AttachRenderer(root, matLib.Create(WaterPalette.Cyan(), water.Settings));
water.AttachFx(root);                                                   // foam + spray
water.AttachSubmergedFx(this, "res://assets/shaders/water_underwater.gdshader");
water.AttachAudio(new RaEngineWaterAudio());                            // optional, see §5
water.SetCamera(playerCamera);                                          // submerged FX + audio listener
```

Then **call `water.Tick(delta)` once per frame** (the only ongoing requirement —
ra-engine has no per-block tick, so the module schedules itself).

Place/remove water:
```csharp
water.PlaceSource(cell);   // infinite source; spreads/falls/dries automatically
water.Remove(cell);        // remove water at a cell
water.Freeze(cell, true);  // cosmetic ice
```
External edits (player digging/building) flow in automatically via `BlockChanged`.

---

## 4. Mesh integration

`WaterRenderer` creates one `MeshInstance3D` per water chunk under the root you
pass. **Recommended:** keep these separate from ra-engine's chunk `_water`
node and just disable host water-face meshing (above). No change to your greedy
mesher's vertex format is needed. The water material draws in the transparent
pass with `render_priority = -1`; foam cubes (`+2`) and spray (`+3`) sort in
front of the water body.

---

## 5. Optional host hooks

- **Audio** (`IWaterAudio`): the module tells you *what* should sound (calm /
  river / waterfall) and *where* (`WaterAudioCluster`s). ra-engine implements it
  with its runtime synth. See `SandboxWaterAudio` for a reference impl.
- **Swim/buoyancy** (`IWaterSwimmer`): `water.Swimmer.Sample(feet, head, vel)`
  returns buoyancy/drag/flow each physics frame — call it from your character
  controller and add the response to its velocity. See `FpsWalker`.
- **Submerged FX**: `AttachSubmergedFx` + `SetCamera`; cross-fades a blue
  fog/caustics overlay when the eye goes underwater.

All three are additive and optional.

---

## 6. Determinism

The water state is a pure function of (edit log + `WaterSettings` + sea level):
fixed `(y,z,x)` processing order, no RNG in the sim, per-tick budget carried
FIFO. For replays, apply the same edits in the same order and use the same
`MaxCellsPerTick` / `TickHz`. (Foam/spray/audio use cosmetic RNG that never feeds
back into sim state.)

---

## 7. Performance & tuning

`WaterSettings.Low()/Medium()/High()/Ultra()` scale sim budget + radius,
remesh/frame, reflection (SSR steps), foam/spray density + capacity, caustics,
and audio voices. Swap live with `water.Settings = …; water.ApplySettings();`
(and `matLib.ApplySettings(material, settings)` for the shader). A **settled
body of water costs nothing** — cells leave the active set when they stop
changing, so a still lake is free until something nearby changes.

---

## 8. Extension points (deliberately left open)

- **Planar reflection**: the shader has a `reflection_mode == 2` path that
  samples `reflection_tex` via `reflection_vp`. Wire a mirrored-camera
  `SubViewport` rig and push those two uniforms for hero-quality mirrors.
  (Screen-space is the shipping default and needs nothing.)
- **Sea level**: `water.SetSeaLevel(on, y, cx, cz, half)` floods a bounded
  region; swap for a flood-fill-from-edges if you want true global oceans.
- **"Find nearest drop" river bias**: the sim spreads water evenly on flat
  ground (Minecraft-accurate). Add a bounded downhill BFS in
  `WaterSimulation.UpdateCell` if you want water to *prefer* flowing toward the
  nearest ledge.
