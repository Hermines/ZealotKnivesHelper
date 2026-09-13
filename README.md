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
- **Display toggle & hotkeys**: "Always Show" master switch (off = no dots) with two
  keybinds — a press key that toggles Always Show in game, and a hold key that
  temporarily force-shows the dots while "Always Show" is off (release hides again).
- **Hide nearby enemies** (on by default): no dots for enemies closer than 10 m — at
  point-blank range the dots sit on top of the enemy and the plain crosshair is enough.
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
| Display Toggle | Always show (on by default), toggle key (press), force-show key (hold) |
| Indicator Settings | Max distance (m), hide nearby enemies (fixed 10 m), max angle (deg), max dots, dot size/opacity, scale by distance, lead prediction + multiplier, hide when out of knives, line of sight check |
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
│   ├── compat/
│   │   └── main_path_guard.lua       game main-path race guard (keeps mods that replace the
│   │                                 player unit mid-run, e.g. character changers, from
│   │                                 crashing the game)
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
- **Main-path crash guard**: the game's main-path progress update hard-crashes when a
  player unit is replaced mid-run and has no main-path group index yet (no respawn
  beacon on the map, no navmesh position, no previous frame, no teammates). Vanilla
  never hits this, but mods that replace the player unit mid-run — e.g.
  InstantCharacterChange hot-switching characters on beacon-less maps like the
  shooting range — do. This mod shields that one update call so the race can no
  longer take the game down (one throttled chat line when it fires).

## Version history

### 1.0.1

- **Added**: combat display control - "Always Show" (on by default) with a press key
  to toggle it in game, and a hold key that force-shows the dots while "Always Show"
  is off (bind it to your block key to show dots only while blocking).
- **Added**: "Hide Nearby" (on by default) - no dots for enemies within 10 m, so
  point-blank melee stays clean. Note for upgraders: dots now disappear inside 10 m
  by default.
- **Fixed**: dots were silently hidden in the top of the range - the engine's
  max-distance cutoff is measured against the marker position (the aim point, i.e.
  target + 10 m trajectory extension + lead), so with the default 50 m setting
  nothing was drawn beyond ~40 m. The engine cutoff is now re-based onto target
  distance with lead headroom.
- **Fixed**: dots could stay frozen on screen after dying (the game despawns the
  player unit ~5 s into the death sequence while the mission continues). They are
  now reclaimed while dead and rebuilt on respawn.
- **Added**: main-path crash guard (see Technical Notes) - fixes game crashes when
  other mods replace the player unit mid-run, e.g. InstantCharacterChange character
  switching in the shooting range / psykhanium.

### 1.0.0

- Initial release.
