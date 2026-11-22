--
-- bloodstain.lua - blood stains on walls and floors
-- LARC addition (no C++ counterpart): when a hitscan connects, a stain is
-- spawned on the wall behind the entity at the crosshair height and a pool
-- at the entity's feet, like projected decals in the referenced technique.
--
--  * wall stains: drawn per screen column against Raycaster.WallRecords, so
--    they get the exact perspective, fog and static lighting of the wall
--    slice they sit on (the wall stain shader mirrors the wall shader)
--  * floor stains: one screen-space bbox quad per stain; the shader
--    reconstructs the world position per pixel (same math as the floor
--    shader) and tests membership in the rotated stain rectangle, with
--    zbuffer occlusion so walls correctly cover the pool
--
-- The pattern itself is computed per pixel from the stain's seed, with the
-- same hash-placed droplets as the impact burst (src/bloodburst.lua), frozen
-- in local surface space - no stain textures are needed.
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")

local Bloodstain = {}

Bloodstain.MaxStains = 48
Bloodstain.WallHalfWidth = 0.16
Bloodstain.WallHalfHeight = 0.15
Bloodstain.FloorHalfSize = 0.25
-- 0 = hard edged drops piling up in flat steps, 1 = soft round spray
Bloodstain.Blur = 0

-- all stains, oldest first; kind = "wall" | "floor"
Bloodstain.list = {}

-- quads need a texture to draw with; the pattern comes from the shader, so a
-- plain 64x64 white image serves every stain (its size also sets the pixel
-- scale the column quads are built in, see renderWallStains)
local stainTexture

local wallStainShader
local floorStainShader

local quadPool = {}

local function getQuad(i)
	if not quadPool[i] then
		quadPool[i] = love.graphics.newQuad(0, 0, 1, 1, 1, 1)
	end
	return quadPool[i]
end

-- ------------------------------------------------------------------------
-- Shaders (light math mirrors raycaster.lua; array size 9 = MAX_LIGHTS there)
-- ------------------------------------------------------------------------

-- Shared by both stain shaders: the splatter pattern in local space, where
-- local.x/local.y run -1..1 across the stain rectangle.
local stainGLSL = [[
uniform float uBlur;
uniform float uSeed;

float hash(float n) { return fract(sin(n) * 43758.5453); }

vec4 stainPixel(vec2 local)
{
	// no drop reaches past 1.2 of the local radius, so skip the loop entirely
	// for the parts of a quad the stain does not cover
	if (dot(local, local) > 1.44) { return vec4(0.0); }

	// 70 droplets placed by hash: the impact burst's construction with the
	// time uniform dropped, so the spray is frozen against the surface. Drops
	// are thrown out of a dense core and stretched along the throw direction;
	// the last few are narrow vertical streaks (drips on a wall).
	float cover = 0.0;
	float tint = 0.0;
	for (int i = 1; i <= 70; ++i) {
		float fi = float(i);
		float h1 = hash(fi * 12.9898 + uSeed * 78.233);
		float h2 = hash(fi * 39.3467 + uSeed * 11.135);
		float h3 = fract(h1 * 91.31);
		bool streak = (fi > 62.0);
		float ang = h1 * 6.2831853;
		vec2 dir = vec2(cos(ang), sin(ang));
		// dense core, sparse rim ("spread" is how far out the drop was thrown)
		float spread = pow(h2, 1.7);
		vec2 center = dir * spread * 0.85;
		// a fat blob at the point of impact, specks thinning out to the rim
		float rad = mix(0.17, 0.015, spread) * (0.5 + h3);
		vec2 axis = streak ? vec2(0.0, 1.0) : dir;
		float stretch = streak ? 3.0 + 3.0 * h3 : 1.0 + 1.2 * spread;
		if (streak) { rad = 0.012 + 0.018 * h3; }
		vec2 rel = local - center;
		float d = length(vec2(dot(rel, axis) / stretch, dot(rel, vec2(-axis.y, axis.x))));
		// hard discs where uBlur is 0, soft rims where it is 1
		float m = mix(step(d, rad), 1.0 - smoothstep(rad * 0.45, rad, d), uBlur);
		float w = m * mix(1.0, 0.5, spread);
		cover = cover + w;
		tint = tint + w * fract(h1 * 13.37);
	}

	// dense overlaps go opaque, like a stain rather than smoke; at uBlur 0 the
	// coverage snaps to flat steps instead of shading a smooth ramp
	float alpha = 1.0 - exp(-cover * 1.1);
	alpha = mix(floor(alpha * 4.0 + 0.5) * 0.25, alpha, uBlur);
	vec3 col = mix(vec3(0.24, 0.01, 0.015), vec3(0.58, 0.04, 0.04),
		clamp(tint / max(cover, 0.0001), 0.0, 1.0));
	// flat per-texel grain so the stain reads as painted pixels, not a blob
	float grain = hash(floor(local.x * 32.0) * 12.9898 + floor(local.y * 32.0) * 78.233 + uSeed * 5.1);
	return vec4(col * (1.0 - 0.16 * (1.0 - uBlur) * grain), alpha);
}
]]

local function initShaders()
	wallStainShader = love.graphics.newShader(stainGLSL .. [[
uniform bool uLighting;
uniform int uLightCount;
uniform vec4 uLights[9];
uniform float uLightLoc[9];
uniform float uHLo;
uniform float uHSpan;

// per-pixel light attenuation, identical to the C++ GetIntensity blend chain
// walls and doors are lit by wall AND door lights (see Game_Raycaster.hpp)
float lightRestore(vec2 world)
{
	float lm = 1.0;
	for (int i = 0; i < 9; ++i) {
		if (i >= uLightCount) { break; }
		float loc = uLightLoc[i];
		if (abs(loc - 1.0) > 0.5 && abs(loc - 3.0) > 0.5) { continue; }
		vec4 light = uLights[i];
		float d = length(world - light.xy);
		if (d < light.z && light.w > 0.0) {
			lm *= 1.0 - light.w * (light.z - d) / light.z;
		}
	}
	return lm;
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
	vec4 stain = stainPixel(tc * 2.0 - 1.0);
	if (stain.a < 0.02) { discard; }

	if (!uLighting) { return stain; }

	// color.r = fog weight, color.g = WallX, color.b/a = map tile coordinates / 256
	float fog = color.r;
	// the stain spans wall heights [uHLo, uHLo + uHSpan]
	float wallH = uHLo + fract(tc.y) * uHSpan;
	vec2 lightPos = vec2(color.b * 256.0 + color.g, color.a * 256.0 + wallH);
	float lm = lightRestore(lightPos);

	float weight = 1.0 - (1.0 - fog) * lm;
	return vec4(stain.rgb * weight, stain.a);
}
]])

	floorStainShader = love.graphics.newShader(stainGLSL .. [[
uniform vec2 uPos;
uniform vec2 uDir;
uniform vec2 uPlane;
uniform float uVLT;
uniform vec2 uViewport;
uniform float uFogFloorCeiling;
uniform bool uLighting;
uniform int uLightCount;
uniform vec4 uLights[9];
uniform float uLightLoc[9];
uniform Image uZBufTex;
uniform vec2 uCenter;
uniform float uHalf;
uniform float uCos;
uniform float uSin;

// per-pixel light attenuation, floor layer only (location 0)
float lightRestore(vec2 world)
{
	float lm = 1.0;
	for (int i = 0; i < 9; ++i) {
		if (i >= uLightCount) { break; }
		if (abs(uLightLoc[i] - 0.0) > 0.5) { continue; }
		vec4 light = uLights[i];
		float d = length(world - light.xy);
		if (d < light.z && light.w > 0.0) {
			lm *= 1.0 - light.w * (light.z - d) / light.z;
		}
	}
	return lm;
}

float shadeWeight(float currentDist, vec2 world)
{
	if (!uLighting) { return 1.0; }
	float fog = clamp((uFogFloorCeiling - currentDist) / uFogFloorCeiling, 0.0, 1.0);
	float lm = lightRestore(world);
	return 1.0 - (1.0 - fog) * lm;
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
	float x = sc.x;
	float y = sc.y;
	if (y + y <= uVLT) { discard; }

	float cam = (x + x) / uViewport.x - 1.0;
	vec2 raydir = uDir + uPlane * cam;

	float wallDist = Texel(uZBufTex, vec2((x + 0.5) / uViewport.x, 0.5)).r;
	float currentDist = uVLT / max(y + y - uVLT, 0.0001);
	float lookScale = uVLT / uViewport.y;

	// same visibility test as the floor pass: covered by a wall slice
	if (currentDist >= wallDist * lookScale) { discard; }

	vec2 world = uPos + raydir * (currentDist / lookScale);
	vec2 d = world - uCenter;
	vec2 local = vec2(d.x * uCos + d.y * uSin, -d.x * uSin + d.y * uCos) / uHalf;
	if (abs(local.x) > 1.0 || abs(local.y) > 1.0) { discard; }

	vec4 stain = stainPixel(local);
	if (stain.a < 0.02) { discard; }

	float weight = shadeWeight(currentDist, world);
	return vec4(stain.rgb * weight, stain.a);
}
]])
end

-- ------------------------------------------------------------------------
-- Init / clear / spawn
-- ------------------------------------------------------------------------

function Bloodstain.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "EffectsConfig.ini")
	if ini then
		Bloodstain.MaxStains = Config.getNumber(ini, "BLOODSTAIN", "MaxStains", 48)
		Bloodstain.WallHalfWidth = Config.getNumber(ini, "BLOODSTAIN", "WallHalfWidth", 0.16)
		Bloodstain.WallHalfHeight = Config.getNumber(ini, "BLOODSTAIN", "WallHalfHeight", 0.15)
		Bloodstain.FloorHalfSize = Config.getNumber(ini, "BLOODSTAIN", "FloorHalfSize", 0.25)
		Bloodstain.Blur = Utils.clamp(Config.getNumber(ini, "BLOODSTAIN", "Blur", 0), 0, 1)
	end
	if not stainTexture then
		local data = love.image.newImageData(64, 64)
		data:mapPixel(function() return 1, 1, 1, 1 end)
		stainTexture = love.graphics.newImage(data)
		stainTexture:setFilter("nearest", "nearest")
	end
	initShaders()
end

function Bloodstain.Clear()
	Bloodstain.list = {}
end

local function add(stain)
	stain.seed = love.math.random() * 100
	Bloodstain.list[#Bloodstain.list + 1] = stain
	while #Bloodstain.list > Bloodstain.MaxStains do
		table.remove(Bloodstain.list, 1)
	end
end

-- entity was hit by the center ray; wallInfo (optional) describes the wall
-- behind it: { mapX, mapY, side, wallX, height }
function Bloodstain.Spawn(entity, wallInfo)
	local dying = entity.KillAnimEnabled or entity.Hitpoints <= 0

	if os.getenv("LARC_DEBUGBLOODSTAIN") then
		print(string.format("LARC debug bloodstain: entity (%.2f,%.2f) hp=%d wall=%s",
			entity.Pos.X, entity.Pos.Y, entity.Hitpoints,
			wallInfo and string.format("(%d,%d) side=%s wallX=%.2f h=%.2f",
				wallInfo.mapX, wallInfo.mapY, tostring(wallInfo.side), wallInfo.wallX, wallInfo.height) or "none"))
	end

	if wallInfo then
		add({
			kind = "wall",
			mapX = wallInfo.mapX,
			mapY = wallInfo.mapY,
			side = wallInfo.side,
			wallX = wallInfo.wallX,
			height = wallInfo.height,
			halfW = Bloodstain.WallHalfWidth * (0.8 + love.math.random() * 0.5),
			halfH = Bloodstain.WallHalfHeight * (0.8 + love.math.random() * 0.5)
		})
		-- a kill throws a second, wider splatter up the wall
		if dying then
			add({
				kind = "wall",
				mapX = wallInfo.mapX,
				mapY = wallInfo.mapY,
				side = wallInfo.side,
				wallX = Utils.clamp(wallInfo.wallX + (love.math.random() - 0.5) * 0.5, 0.05, 0.95),
				height = Utils.clamp(wallInfo.height + (love.math.random() - 0.5) * 0.4, 0.05, 0.95),
				halfW = Bloodstain.WallHalfWidth * (0.5 + love.math.random() * 0.5),
				halfH = Bloodstain.WallHalfHeight * (0.5 + love.math.random() * 0.5)
			})
		end
	end

	-- blood on the floor at the entity's feet: a second, wider pool per hit
	-- and a third one when the target drops
	for i = 1, (dying and 3 or 2) do
		local spread = 0.2 + 0.3 * (i - 1)
		add({
			kind = "floor",
			x = entity.Pos.X + (love.math.random() - 0.5) * spread,
			y = entity.Pos.Y + (love.math.random() - 0.5) * spread,
			half = Bloodstain.FloorHalfSize * (dying and 1.8 or (0.8 + love.math.random() * 0.5)) / (1 + 0.35 * (i - 1)),
			rot = love.math.random() * math.pi * 2
		})
	end
end

-- ------------------------------------------------------------------------
-- Rendering (called from Raycaster.render, after the wall pass)
-- ------------------------------------------------------------------------

local function renderWallStains(Raycaster)
	local records = Raycaster.WallRecords
	local W = G.Canvas.Width
	local TS = G.TextureSize
	local fog = Raycaster.FogOfWarDistance
	local lighting = Level.LightingFlag
	local tw, th = stainTexture:getWidth(), stainTexture:getHeight()

	love.graphics.setBlendMode("alpha")
	love.graphics.setShader(wallStainShader)
	wallStainShader:send("uLighting", lighting)
	wallStainShader:send("uBlur", Bloodstain.Blur)
	Raycaster.SendLights(wallStainShader)

	for _, d in ipairs(Bloodstain.list) do
		if d.kind == "wall" then
			wallStainShader:send("uHLo", d.height - d.halfH)
			wallStainShader:send("uHSpan", 2 * d.halfH)
			wallStainShader:send("uSeed", d.seed)
			local w0, w1 = d.wallX - d.halfW, d.wallX + d.halfW
			for x = 1, W do
				local rec = records[x]
				if rec and not rec.isDoor
					and rec.mapX == d.mapX and rec.mapY == d.mapY and rec.wallSide == d.side then
					local sliceH = rec.lineEnd - rec.lineStart
					local dv = rec.vBottom - rec.vTop
					if sliceH > 0 and dv > 0 then
						-- column footprint along the wall, from neighbour columns
						local c = 0.001
						local prev = records[x - 1]
						if prev and not prev.isDoor
							and prev.mapX == d.mapX and prev.mapY == d.mapY and prev.wallSide == d.side then
							c = math.max(c, math.abs(prev.wallX - rec.wallX))
						end
						local nxt = records[x + 1]
						if nxt and not nxt.isDoor
							and nxt.mapX == d.mapX and nxt.mapY == d.mapY and nxt.wallSide == d.side then
							c = math.max(c, math.abs(nxt.wallX - rec.wallX))
						end
						local lo = math.max(w0, rec.wallX - c)
						local hi = math.min(w1, rec.wallX + c)
						-- visible wall height range in this column
						local hLo = math.max(d.height - d.halfH, rec.vTop / TS)
						local hHi = math.min(d.height + d.halfH, rec.vBottom / TS)
						if hi > lo and hHi > hLo then
							local u0 = (lo - w0) / (w1 - w0) * tw
							local u1 = (hi - w0) / (w1 - w0) * tw
							local y0 = rec.lineStart + (hLo * TS - rec.vTop) / dv * sliceH
							local y1 = rec.lineStart + (hHi * TS - rec.vTop) / dv * sliceH
							local v0 = (hLo - (d.height - d.halfH)) / (2 * d.halfH) * th
							local v1 = (hHi - (d.height - d.halfH)) / (2 * d.halfH) * th
							local fogW = 1.0
							if lighting then
								local f = Utils.shadeFactor(rec.wallDist, fog)
								fogW = (f == -1) and 0.0 or f
							end
							local quad = getQuad(x)
							quad:setViewport(u0, v0, u1 - u0, v1 - v0, tw, th)
							-- the column's slice of the stain is (u1-u0) texels of a 64px
							-- image, i.e. a fraction of a pixel; stretch it back out to the
							-- one screen column it stands for, or it rasterizes away
							local span = u1 - u0
							-- identical vertex color as the wall slice beneath
							love.graphics.setColor(fogW, rec.wallX, rec.mapX / 256, rec.mapY / 256)
							love.graphics.draw(stainTexture, quad, x - 1, y0, 0, 1 / math.max(span, 1e-6), (y1 - y0) / (v1 - v0))
						end
					end
				end
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

local function renderFloorStains(Raycaster)
	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local VLT = H + G.VerticalLook
	local fog = Raycaster.FogOfWarDistance

	love.graphics.setBlendMode("alpha")
	love.graphics.setShader(floorStainShader)
	floorStainShader:send("uPos", { Player.Pos.X, Player.Pos.Y })
	floorStainShader:send("uDir", { Player.Dir.X, Player.Dir.Y })
	floorStainShader:send("uPlane", { G.Plane.X, G.Plane.Y })
	floorStainShader:send("uVLT", VLT)
	floorStainShader:send("uViewport", { W, H })
	floorStainShader:send("uFogFloorCeiling", fog + fog * G.VerticalLookCamera)
	floorStainShader:send("uLighting", Level.LightingFlag)
	floorStainShader:send("uBlur", Bloodstain.Blur)
	Raycaster.SendLights(floorStainShader)
	floorStainShader:send("uZBufTex", Raycaster.ZBufferImage)

	local dirX, dirY = Player.Dir.X, Player.Dir.Y
	local planeX, planeY = G.Plane.X, G.Plane.Y
	local pp = planeX * planeX + planeY * planeY

	for _, d in ipairs(Bloodstain.list) do
		if d.kind == "floor" then
			floorStainShader:send("uCenter", { d.x, d.y })
			floorStainShader:send("uHalf", d.half)
			floorStainShader:send("uCos", math.cos(d.rot))
			floorStainShader:send("uSin", math.sin(d.rot))
			floorStainShader:send("uSeed", d.seed)

			-- screen bbox of the rotated world-space square; a floor point at
			-- perpendicular distance d projects to (W/2*(1+cam), VLT/2 + H/(2d))
			local cosR, sinR = math.cos(d.rot), math.sin(d.rot)
			local minX, minY = math.huge, math.huge
			local maxX, maxY = -math.huge, -math.huge
			for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
				local lx, ly = corner[1] * d.half, corner[2] * d.half
				local wx = d.x + lx * cosR - ly * sinR
				local wy = d.y + lx * sinR + ly * cosR
				local vx, vy = wx - Player.Pos.X, wy - Player.Pos.Y
				local dist = vx * dirX + vy * dirY
				if dist < 0.08 then dist = 0.08 end
				local cam = (vx * planeX + vy * planeY) / (dist * pp)
				local sx = W / 2 * (1 + cam)
				local sy = VLT / 2 + H / (2 * dist)
				minX = math.min(minX, sx)
				maxX = math.max(maxX, sx)
				minY = math.min(minY, sy)
				maxY = math.max(maxY, sy)
			end
			minX = Utils.clamp(minX, 0, W)
			maxX = Utils.clamp(maxX, 0, W)
			minY = Utils.clamp(minY, 0, H)
			maxY = Utils.clamp(maxY, 0, H)
			local bw, bh = maxX - minX, maxY - minY
			if bw > 0 and bh > 0 then
				love.graphics.draw(stainTexture, minX, minY, 0, bw / stainTexture:getWidth(), bh / stainTexture:getHeight())
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

function Bloodstain.Render()
	if #Bloodstain.list == 0 then return end
	local Raycaster = Game.Raycaster
	renderWallStains(Raycaster)
	renderFloorStains(Raycaster)
	love.graphics.setShader()
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(1, 1, 1, 1)
end

Game.Bloodstain = Bloodstain
return Bloodstain
