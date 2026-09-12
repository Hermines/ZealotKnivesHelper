# Zealot Knives Helper

A Darktide (Warhammer 40,000: Darktide) mod built on the [Darktide Mod Framework](https://www.nexusmods.com/warhammer40kdarktide/mods/8).

## Overview

While playing a **Zealot** with the **Throwing Knives** throwable equipped, this mod shows an
extra dot crosshair for every **boss / elite / specialist** enemy in range, indicating
**where you need to move your crosshair to hit that enemy**:

- **Ballistic compensation**: the dot position is computed from the knives' real projectile
  behavior — the mod replicates the game's own projectile integrator
  (`projectile_integration.lua`), a semi-implicit Verlet scheme including gravity
  (g = 17.5) and air drag (Cd = 0.2, air_density = 0.7, mass = 0.8, r = 0.2) at an
  initial speed of 75 m/s. Put your crosshair on the dot and the knife hits.
- **Lead prediction** (optional): leading is computed by predicting the enemy's future
  position at the knife's flight time and re-solving, iterating twice.
- **Multiple targets**: one extra dot per qualifying enemy; beyond the cap, dots are
  prioritized Specialist > Elite > Boss, then by distance (nearest first).
- **Depth stack fading**: when several enemies line up on the same sight line, rear dots
  fade out automatically to avoid overlap.
- **Distance scaling**: dots shrink with distance (optional) and are cut off beyond
  max range.
- **Range & angle**: only enemies within the configured distance and angle from the
  crosshair direction are indicated.
- **Per-breed customization**: every enemy breed can be toggled and colored individually;
  the three categories (boss / elite / specialist) each have their own switch and default color.

## Installation

Requires DMF. Put the mod folder into your `mods/` directory and enable it in the launcher:

```
mods/
└── ZealotKnivesHelper/
    ├── ZealotKnivesHelper.mod
    ├── info.json
    └── scripts/mods/ZealotKnivesHelper/...
```

Configure it in-game under `Options → Mod Settings → Zealot Knives Helper`.

## Settings

| Group | Settings |
| --- | --- |
| Mod Settings | Enable toggle, debug mode |
| Indicator Settings | Max distance (m), max angle (deg), max dots, dot size/opacity, scale by distance, lead prediction + multiplier, hide when out of knives, line of sight check |
| Enemy Categories | Per-category switch and color for Boss / Elite / Specialist; per-breed switch and color |

## File Structure

```
ZealotKnivesHelper/
├── ZealotKnivesHelper.mod            mod declaration (DMF entry)
├── info.json                         metadata
├── scripts/mods/ZealotKnivesHelper/
│   ├── ZealotKnivesHelper.lua        main module: settings cache / lifecycle / hook wiring
│   ├── ZealotKnivesHelper_data.lua   DMF settings definition (breed widgets generated dynamically)
│   ├── ZealotKnivesHelper_localization.lua  localization (en / zh-cn)
│   ├── core/
│   │   ├── ballistics.lua            ballistic solver (pure functions, replicates the game
│   │   │                             integrator including drag)
│   │   ├── target_filter.lua         target classification / filtering / sorting (pure)
│   │   ├── breed_config.lua          per-breed show/color resolution (pure)
│   │   └── stack_fade.lua            depth stack fading (pure, ported from enemies_improved)
│   ├── game/
│   │   ├── breed_list.lua            breed lists built from the game's breed settings
│   │   ├── context.lua               broadphase enemy scanning / zealot & knife detection /
│   │   │                             camera / physics world / first-person position / LOS
│   │   └── indicators.lua            per fixed frame: filter → ballistic solve → stack fade →
│   │                                 world-space targets
│   └── draw/
│       ├── marker_template.lua       dot world_marker template (plugs into the engine's
│       │                             world marker system)
│       └── marker_sync.lua           target ↔ engine marker sync (add/remove/position/style)
└── tests/                            luajit test suite
    ├── run.lua                       entry point: luajit tests/run.lua
    ├── helpers.lua                   assertions / Vector3 mock / independent integrator
    ├── test_ballistics.lua           solver (cross-validated against an independent integrator)
    ├── test_target_filter.lua        filtering / sorting
    ├── test_breed_config.lua         breed config fallbacks
    ├── test_stack_fade.lua           depth stack fading
    ├── test_marker_drawing.lua       marker template style updates (RGB regression, etc.)
    ├── test_indicators.lua           end-to-end: aim point → trajectory hit verification
    └── test_module_loading.lua       loads every mod file under stubbed game globals
```

## Tests

```
luajit tests/run.lua
```

The suite covers: drag constant matching the game formula, vacuum-solution seeding,
hit verification across distances/heights (cross-checked with an independently replicated
integrator), flight-time sanity, target filtering/sorting, breed config fallbacks,
stack fading behavior, marker template style updates, and a full module load pass
under stubbed game globals.

## Technical Notes

- **Enemy classification**: `breed.is_boss` / `breed.tags.elite` / `breed.tags.special`,
  same rule set as AutoMark.
- **Enemy scanning**: prefers a `broadphase_system` spatial query (enemy-side relations,
  range-limited; the scan interval automatically relaxes when many enemies are present)
  and falls back to iterating the `health_system` unit map.
- **Ballistic origin**: the first-person position (`first_person` component), matching the
  game's `spawn_projectile` behavior.
- **Rendering**: a custom world_marker template is registered into the engine's
  `HudElementWorldMarkers` (following enemies_improved); projection, frustum culling,
  screen clamping, and distance scaling are handled natively by the engine.
  Each fixed frame the mod only computes ballistic solutions and syncs marker
  data; marker positions are written exclusively from a pre-hook on the element's
  update (before the engine reads them), so the drawn position is the current
  frame's — zero pipeline lag, no fixed/render write races.
  The material reuses the game's default crosshair center dot
  (`content/ui/materials/hud/crosshairs/center_dot`) — no extra packages required.
- **Display hysteresis**: with more eligible enemies than the dot cap, the slot
  boundary would otherwise churn every frame (dots popping in/out). Three stabilizers:
  displayed targets get a small effective-distance advantage in the same category
  and relaxed edge tolerances on the distance/angle filters; targets that drop out
  of the list keep flowing through the pipeline for a short linger window with a
  linear alpha fade, so their markers are reused (no destroy/recreate flicker) and
  keep following the enemy while fading; and the render-frame refresh re-solves the
  elevation as soon as the target moves beyond a small tolerance, keeping fast-moving
  dots smooth instead of stepping at the fixed-frame solve cadence.
- **Depth stack fading**: rear markers on the same sight line fade by depth delta,
  formula ported from enemies_improved.
- **Line of sight check** (optional): dual sample points (head, then spine) with the
  minion line-of-sight collision filter; hits on the target unit itself are treated as
  clear. Raycasts fail open.
