# AGENTS.md - LARC ("LÖVE Another RayCaster")

## What this project is

LARC is a faithful port of **NARC - "Not Another RayCaster"**
(C++/OpenGL/Win32, by Stefan Kubsch, 2017-2020) to Lua + LÖVE 11.5.
The goal is pixel-accurate rendering with the *unmodified* original game
data: `DATA/`, `GFX/`, `SFX/`, `Fonts/` are the original NARC files and must
**never be edited**. All gameplay/content changes happen in Lua code only.

The C++ original lives in `../NARC/` (shared parent folder); each Lua module
corresponds to one C++ header - the mapping table is in `README.md`.
When in doubt about intended behavior, read the C++ counterpart, not this
README: the C++ is the spec.

## Running

```sh
cd /Users/Jens/Projects/love/LARC && /opt/homebrew/bin/love .
# or: /opt/homebrew/bin/love /Users/Jens/Projects/love/LARC
```

Runs vsynced at 60 FPS on the dev machine. Syntax check changed files with
`luac -p <file>` before running.

## Debug / test environment variables (main.lua, all env-gated, keep them)

| Var | Effect |
| --- | --- |
| `LARC_SCREENSHOT=1` | screenshot every 2s to `~/Library/Application Support/LOVE/LARC/screenshot<N>.png`, prints "written, FPS n" and camera debug lines |
| `LARC_NOINPUT=1` | blocks keyboard + mouse deltas - deterministic camera for A/B image comparison |
| `LARC_NOENTITIES=1` | skips entity rendering (dirty scene for pixel verification) |
| `LARC_TESTPOS="x,y,dirx,diry"` | teleport player at start |
| `LARC_TESTVL=<float>` | set vertical look camera at start (e.g. 0.3 / -0.3) for look tests |
| `LARC_LEVEL=n` | start in level n |
| `LARC_DEBUGFLOOR=1/2/3` | floor-shader diagnostics: 1=dist+world fract, 2=shade weight/light factor/texture idx, 3=atlas texel the GPU samples |
| `LARC_TESTDOOR=1`, `LARC_TESTDEATH=1`, `LARC_TESTMENU=1`, `LARC_AUTOFIRE=1`, `LARC_DEBUGMOVE=1` | scenario hooks |

Pixel verification workflow (used for walls/floor/ceiling/lights): run with
`LARC_SCREENSHOT=1 LARC_NOINPUT=1 LARC_NOENTITIES=1` (+ `LARC_TESTPOS` if
needed), then compare the screenshot in Python against a software
reimplementation of the exact C++ formulas (DDA per column, row distance
`currentDist = VLT / (2y - VLT)` etc.). Exclude HUD overlays from stats:
status box (x<222, y<92), fps text+health bar (x>470, y<55), minimap
(bottom-left), weapon viewmodel (bottom-right), crosshair (center).
Match rate should be ~95-99% with tolerance 8; leftovers are overlay
edges and wall-slice boundary rows.

## Domain facts (established by reading the C++, do not re-derive)

- **Map config axes**: in `DATA/Levels/*/LevelData/Map*.conf`, the *line*
  index is X, the *column* index is Y (`LevelMap[layer][X][Y]`, confirmed
  via `Game_LevelHandling.hpp`). Map is 16 lines x 11 values for level 1.
  Texture indices are 1-based into `TexturesData.conf` (line n = texture n).
  Wall value `0` = none; door tiles are a special `Level.DOORWALL` sentinel.
- **Static lights conf** (`StaticLightsData.conf` per line):
  `x y location radius intensity` - **radius comes BEFORE intensity**.
  Location: 0=floor, 1=wall, 2=ceiling, 3=door. Intensities may exceed 1.0
  (level 1 has ceiling lamps with intensity 7.0) - the C++ blend chain is
  unclamped; do NOT clamp the derived weight.
- **Shading math** (matches C++ `ShadeColor` + chained `BlendColor`):
  fog = clamp((Fog - dist)/Fog, 0, 1); lm = Π(1 - intensity_i) over lights
  affecting the pixel's layer; final factor `weight = 1 - (1 - fog) * lm`.
  Walls/doors are lit by **both** wall- and door-layer lights; floor and
  ceiling only by their own layer. Lights are computed **per pixel in the
  shaders** via uniforms (see "Löve gotchas" below for why textures failed).
- **Wall light sample position**: `GetIntensity(MapPos.X + WallX, MapPos.Y + WallY)`
  where WallY is the *screen-row* fraction `fract((y+y-VLT+lh)/(2*lh))`, not
  the ray's hit fraction. LARC's wall shader reconstructs this from vertex
  colors: `lightPos = (color.b*256 + color.g, color.a*256 + fract(tc.y))`.
- The C++ appends a duplicated last line to the ceiling map at load (a
  lighting bounds guard); it has no output effect and is intentionally not
  ported.
- **Vertical look** (floor/ceiling): the C++ does NOT use
  `world = pos + ray * rowDist` during look-up/down. It lerps towards
  `FloorWall` with `FactorW = CurrentDist / (WallDist * (1 + VerticalLookCamera))`,
  which simplifies to `world = pos + ray * CurrentDist / (1 + VLC)`, and
  occludes the floor where `CurrentDist >= WallDist * (1 + VLC)`.
  `(1 + VLC) == VLT / H`, computed in the shader as `lookScale = uVLT / uViewport.y`.
  Fog shading keeps the RAW `CurrentDist` with `FloorCeilingShading = fog + fog*VLC`.
  (Missing the division was the "floor/ceiling swim during vertical look" bug.)

## Löve gotchas already paid for (don't rediscover these)

- `ImageData:setPixel` takes floats in **0..1** and *clamps* outside. Any
  index-to-texture encoding must divide by 255 on write (and the shader
  multiplies by 255 on read) - storing raw indices silently clamps
  everything to 1.0 (this was the flat-gray floor/ceiling bug).
- `Shader:send` for vec2/vec4 uniforms needs Lua tables
  (`send("uPos", {x, y})`), not multiple scalars.
- Uniform **arrays**: send up to N values in one call
  (`send("uLights", t1, t2, ...)`), pad to the declared size.
- In Lua, **0 is truthy**. Never port boolean-ish defaults with
  `x and 1.0 or 0.0` if x can be the number 0.
- `love.filesystem.read("data", path)` - container type string is the FIRST
  argument in Löve 11.
- The LÖVE sandbox blocks `load()` (bit ops fall back to a Lua
  implementation in `src/transitions.lua`).
- Canvas used as minimap background must be cleared to `(0,0,0,0)`, or
  realtime entity dots won't show through.
- Float ImageData formats (`rgba16f`) support negative/out-of-range values
  via setPixel/getPixel; regular ImageData clamps.

## Architecture notes

- `src/game.lua` holds a shared registry (`Game.Player`, `Game.Raycaster`,
  `Game.Doors`, ...) that modules populate at init to break require cycles.
  Follow that pattern; do not introduce cross-requires between the modules
  registered there.
- One DDA per screen column feeds: per-column wall quads (drawn with the
  wall shader), a 1D zbuffer texture (rg16f `{wallDist, lineStart}`) that
  the fullscreen floor/ceiling shader samples, and the entity renderer's
  z-test (`src/entities.lua`).
- `Level.mapTexture` is a small RGBA texture holding per-tile texture
  indices: R=wall (255=door), G=floor, B=ceiling, A=door, each stored /255.
  Level atlas is 8 tiles wide, `slot = index - 1`.
- Lighting uniforms live in `sendLights()` in `src/raycaster.lua`; the
  shader arrays are sized 9 (max lights per level in the shipped data);
  if larger level data ever needs more, bump `MAX_LIGHTS` in lockstep with
  both shaders' array declarations.

## Editing rules

- Match existing style: tabs for indentation, compact error handling,
  comments describe behavior (not the author's deliberation).
- Keep diffs minimal; reference C++ by header/line when porting a detail.
- Content-identical port: if the original draws something differently than
  LARC does, the C++ wins. Verify with the screenshot workflow above, not
  eyeballing.
- After renderer/lighting changes: rerun the spawn verification (level 1
  default spawn pos 14.5,1.5 dir -1,0) and levels 2/3 (they have zero
  lights, so they exercise the count=0 shader path).
