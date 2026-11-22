# LARC - "LÖVE Another RayCaster"

A port of **NARC - "Not Another RayCaster"** (© 2017-2020 Stefan Kubsch, https://github.com/StefanKubsch/NARC)
from C++/OpenGL/Win32 to **Lua + LÖVE** ("LOVE 2D", tested with LÖVE 11.5).

## Running

```sh
love LARC        # or: cd LARC && love .
```

## Controls

| Key | Action |
| --- | --- |
| Mouse | Look left/right/up/down (relative mode) |
| Left mouse button | Fire single shot |
| Right mouse button | Rapid fire |
| Mouse wheel | Change weapon |
| W / S | Move forward / backward |
| A / D | Strafe left / right |
| R | Reload weapon |
| Space | Open doors |
| N | Select next level |
| L | Toggle lighting/fog |
| H | Toggle HUD |
| M | Toggle minimap |
| + / - (numpad) | Increase / decrease mouse sensitivity |
| ESC | Pause menu / back |

Gamepads are supported (any XInput-compatible controller recognized by SDL):
left stick moves, right stick looks, right shoulder fires single shots,
left shoulder rapid fire, X opens doors, DPAD up/down changes weapons,
DPAD right reloads. Switch between mouse and gamepad via menu
("Toogle Mouse / GameController").

## Port structure

| Lua file | Original C++ counterpart |
| --- | --- |
| `main.lua` | `NARC.cpp` (main loop, WndProc, player movement) |
| `conf.lua` | `GFX_Window.hpp` (window setup from `WindowConfig.ini`) |
| `src/config.lua` | `lwmf::ReadINIValue` + INI handling |
| `src/globals.lua` | `Game_GlobalDefinitions.hpp`, `Game_Folder.hpp` |
| `src/level.lua` | `Game_LevelHandling.hpp`, `GFX_LightingClass.hpp` |
| `src/raycaster.lua` | `Game_Raycaster.hpp` |
| `src/entities.lua` | `Game_EntityHandling.hpp` |
| `src/pathfinding.lua` | `Game_PathFinding.hpp` (A*) |
| `src/doors.lua` | `Game_Doors.hpp` |
| `src/weapons.lua` | `Game_WeaponHandling.hpp` |
| `src/player.lua` | `Game_PlayerClass.hpp` |
| `src/bloodhud.lua` | LARC addition: replaces the `Game_Effects.hpp` screen bloodstain overlay (shader-drawn HUD splats + low-health tint) |
| `src/skybox.lua` | `Game_SkyboxHandling.hpp` |
| `src/transitions.lua` | `Game_Transitions.hpp` (fizzle fade / death sequence) |
| `src/menu.lua` | `Game_MenuClass.hpp` |
| `src/hud.lua` | `Game_HealthBarClass.hpp`, `Game_WeaponDisplayClass.hpp`, `Game_MinimapClass.hpp` |
| `src/input.lua` | `HID_Keyboard.hpp`, `HID_Mouse.hpp`, `HID_Gamepad.hpp` |
| `src/video.lua` | LARC addition (fullscreen / window scale / 16:9 and 16:10 widescreen render; the C++ asked "Fullscreen (y/n)" on the console) |

## Rendering design

The original renders per-pixel into a software "Canvas" (multi-threaded C++).
Pure-Lua per-pixel rendering would be far too slow, so this port performs the
identical math but rasterizes on the GPU:

- **Walls / doors**: one DDA per screen column (same algorithm as the
  original, including the sliding-door ray collision), drawn as per-column
  textured quads. Fog shading and static lights are applied in a fragment
  shader using the same `ShadeColor`/`BlendColor` math (fog weight and light
  restore factor) as the C++ per-pixel code.
- **Floor / ceiling**: one fullscreen shader pass replicates the original
  floor/ceiling casting per pixel (row distance, per-tile texture lookup via
  an atlas + a map-index texture, a 1D z-buffer texture per column, fog and
  transparent-ceiling-to-skybox support).
- **Static lights** are computed per pixel in the shaders, exactly like the
  original `GetIntensity` blend chain (`lm` = product of `1 - intensity`,
  `weight = 1 - (1 - fog) * lm`); walls/doors are lit by both wall and door
  lights, floors and ceilings only by their own layer, like the C++ code.
- **Entities** are drawn as per-column-span quads with the same zbuffer test
  and flash/fog handling as the original `RenderEntities`.

## Deviations from the original

- The little pre-game console (level select / fullscreen / vsync questions)
  is replaced by sensible defaults (windowed 640x480 from `WindowConfig.ini`,
  vsync on, level 1); levels can be switched at runtime with N.
- Door texture sliding is emulated with texture coordinates instead of a
  CPU-side copy of the texture per frame (visually equivalent).
- The A* path is recalculated every 0.25s per entity instead of every frame
  (it is only used for the minimap waypoint debug display).
- Footsteps play as a loop while moving instead of restarting an MP3 chunk.
- The fixed `GFX/Effects/Bloodstains.png` screen overlay of the original is
  replaced by `src/bloodhud.lua`: every hit spawns its own screen-space blood
  splat (shader-placed drops that slowly glide down the screen) plus a red
  tint that ramps in below 10% health. Both are tuned in the `[BLOODHUD]`
  section of `DATA/GameConfig/EffectsConfig.ini`.
- Death uses single-shot bits of the Feistel network like the original; on
  640x480 the original Feistel permutation only covers about 29% of screen
  pixels, which is kept faithfully.
- Reads the original data nearly 1:1; `LARC_LEVEL`, `LARC_TESTPOS` and other
  `LARC_*` environment variables exist for automated testing (see `main.lua`).

## Credits

- Original engine, art, sounds and level data: Stefan Kubsch (NARC,
  public domain). Parts of this port reuse the logic structure of his C++
  code 1:1.
- This port: structure-preserving rewrite in Lua for the LÖVE framework.
