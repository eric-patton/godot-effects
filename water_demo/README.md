# Voxel Water Demo

A standalone showcase of the portable voxel water system in `../water/`
(`RAEngine.Water`). Build & run the `godot-effects` project — `water_demo.tscn`
is the main scene. The water module here is the same code that ports to
ra-engine; everything under `../sandbox/` is the throwaway harness (a tiny voxel
world, cameras, build tools) that exists only to exercise it.

## What it shows

- **Calm lake** — flat, translucent, screen-space-reflective water with depth
  colour and shoreline foam (source-filled basin).
- **Waterfall** — a multi-tier cliff: aerated white falls + voxel foam cubes and
  GPU mist at the plunge pool.
- **River** — water spreading down a stepped channel as flowing rapids.
- Smart classification: each water cell becomes calm / river / waterfall purely
  from the block layout + flow — build with water and it re-classifies live.

## Controls

| Input | Action |
|---|---|
| RMB (hold) | Mouse look |
| WASD / Q E | Move (creative fly) |
| Tab | Toggle free-fly ↔ first-person (swim/buoyancy) |
| LMB | Use selected tool |
| 1 / 2 / 3 | Place stone / dirt / glass |
| 4 | Place water source |
| 5 | Remove block/water |
| 6 | Freeze (ice brush) |
| P | Cycle palette (cyan ↔ natural) |
| F1–F4 | Quality tier (Low / Medium / High / Ultra) |
| L | Toggle sea level (floods the build yard) |
| F5 / F6 / F7 | Jump camera to lake / waterfall / river |

## Run / iterate

```
C:\Godot\Godot_v4.6.3-stable_mono_win64_console.exe --path C:\repos\godot-effects
```
Build C# first if needed: `dotnet build GodotEffects.csproj`.
Headless self-tests: `… --headless --quit-after 30` (prints sim/data PASS/FAIL).

See `../water/PORTING.md` for integrating the module into another voxel engine.
