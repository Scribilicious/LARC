--
-- decals.lua - blood stain decals on walls and floors
-- LARC addition (no C++ counterpart): when a hitscan connects, a splatter is
-- spawned on the wall behind the entity at the crosshair height and a pool
-- at the entity's feet, like projected decals in the referenced technique.
--
--  * wall decals: drawn per screen column against Raycaster.WallRecords, so
--    they get the exact perspective, fog and static lighting of the wall
--    slice they sit on (the wall decal shader mirrors the wall shader)
--  * floor decals: one screen-space bbox quad per decal; the shader
--    reconstructs the world position per pixel (same math as the floor
--    shader) and tests membership in the rotated decal rectangle, with
--    zbuffer occlusion so walls correctly cover the pool
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")

local Decals = {}

Decals.MaxDecals = 48
Decals.WallHalfWidth = 0.16
Decals.WallHalfHeight = 0.15
Decals.FloorHalfSize = 0.25
Decals.TextureVariants = 6

-- all decals, oldest first; kind = "wall" | "floor"
Decals.list = {}

local textures = {}

local wallDecalShader
local floorDecalShader

local quadPool = {}

local function getQuad(i)
	if not quadPool[i] then
		quadPool[i] = love.graphics.newQuad(0, 0, 1, 1, 1, 1)
	end
	return quadPool[i]
end

-- ------------------------------------------------------------------------
-- Textures: procedural fractal variants (straight alpha via ImageData).
-- fBm value noise thresholded by a radial mask gives ragged, branching
-- edges; the mask is exactly 0 a few pixels inside the texture border, so
-- a shape can never be clipped into a hard edge at the boundary.
-- ------------------------------------------------------------------------

-- fractal Brownian motion: random grids at increasing frequency,
-- smoothstep-interpolated, summed with 1/i amplitude
local function makeFbmNoise(rng)
	local rnd = function() return rng:random() end
	local octaves = {}
	local freqs = { 3, 5, 9, 17, 33 }
	local ampSum = 0.0
	for i, freq in ipairs(freqs) do
		local grid = {}
		for gy = 0, freq do
			local row = {}
			for gx = 0, freq do
				row[gx] = rnd()
			end
			grid[gy] = row
		end
		local amp = 1.0 / i
		ampSum = ampSum + amp
		octaves[i] = { freq = freq, grid = grid, amp = amp }
	end
	for _, o in ipairs(octaves) do
		o.amp = o.amp / ampSum
	end

	local function smooth(t)
		return t * t * (3 - 2 * t)
	end

	-- value noise, nx/ny wrapped into [0, 1)
	return function(nx, ny)
		nx = nx - math.floor(nx)
		ny = ny - math.floor(ny)
		local v = 0.0
		for _, o in ipairs(octaves) do
			local gx = nx * o.freq
			local gy = ny * o.freq
			local x0 = math.floor(gx)
			local y0 = math.floor(gy)
			local fx = smooth(gx - x0)
			local fy = smooth(gy - y0)
			local g = o.grid
			local a = g[y0][x0] + (g[y0][x0 + 1] - g[y0][x0]) * fx
			local b = g[y0 + 1][x0] + (g[y0 + 1][x0 + 1] - g[y0 + 1][x0]) * fx
			v = v + o.amp * (a + (b - a) * fy)
		end
		return v
	end
end

local function smooth(t)
	return t * t * (3 - 2 * t)
end

local function makeSplatTexture(rng)
	local rnd = function() return rng:random() end
	local noise = makeFbmNoise(rng)
	local size = 64
	local half = size / 2

	-- satellite droplets and short radial streaks, all faded by the same
	-- radial mask below so they cannot reach the texture edge either
	local drops = {}
	for i = 1, 22 do
		local a = rnd() * math.pi * 2
		local r = (0.15 + rnd() * 0.72) * half
		drops[i] = {
			x = half + math.cos(a) * r,
			y = half + math.sin(a) * r,
			r = 0.8 + rnd() * 2.4,
			w = 0.5 + rnd() * 0.7
		}
	end
	local streaks = {}
	for i = 1, 7 do
		local a = rnd() * math.pi * 2
		local r0 = (0.25 + rnd() * 0.2) * half
		local r1 = r0 + (0.1 + rnd() * 0.35) * half
		streaks[i] = {
			x0 = half + math.cos(a) * r0, y0 = half + math.sin(a) * r0,
			x1 = half + math.cos(a) * r1, y1 = half + math.sin(a) * r1,
			w = 1.0 + rnd() * 1.6
		}
	end

	local tint = 0.85 + rnd() * 0.3
	local data = love.image.newImageData(size, size)
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local dx = x + 0.5 - half
			local dy = y + 0.5 - half
			local r = math.sqrt(dx * dx + dy * dy) / half
			-- 0 beyond 92% of the half-size (3 px inside the border)
			local mask = Utils.clamp((0.92 - r) / 0.32, 0.0, 1.0)
			mask = smooth(mask)
			if mask > 0.0 then
				local n = noise((x + 0.5) / size, (y + 0.5) / size)
				-- solid core gaussian + ragged fBm fringe
				local f = 1.1 * math.exp(-(r * r) / 0.16) + (n - 0.45) * 3.0
				for _, d in ipairs(drops) do
					local ddx = x - d.x
					local ddy = y - d.y
					f = f + d.w * math.exp(-(ddx * ddx + ddy * ddy) / (2 * d.r * d.r))
				end
				for _, s in ipairs(streaks) do
					local ex = s.x1 - s.x0
					local ey = s.y1 - s.y0
					local len2 = ex * ex + ey * ey
					local t = len2 > 0 and ((x - s.x0) * ex + (y - s.y0) * ey) / len2 or 0.0
					t = Utils.clamp(t, 0.0, 1.0)
					local ddx = x - (s.x0 + ex * t)
					local ddy = y - (s.y0 + ey * t)
					f = f + s.w * math.exp(-(ddx * ddx + ddy * ddy) / 2.0)
				end
				local a = Utils.clamp(f * mask, 0.0, 1.0)
				if a > 0.01 then
					-- mottled shading driven by the noise field, not white noise
					local shade = (0.6 + n * 0.5) * tint
					-- ImageData:setPixel takes floats in 0..1 (see AGENTS.md)
					data:setPixel(x, y, 0.42 * shade, 0.02 * shade, 0.02 * shade, a)
				end
			end
		end
	end
	local image = love.graphics.newImage(data)
	image:setFilter("linear", "linear")
	return image
end

-- radial fractal burst (star with jagged fBm rays) for hit impacts;
-- drawn as a short-lived billboard by entities.lua. Same border guarantee
-- as the splats: alpha is exactly 0 in the outer pixels.
function Decals.MakeBurstTexture(rng, size, cr, cg, cb)
	local noise = makeFbmNoise(rng)
	local half = size / 2
	local data = love.image.newImageData(size, size)
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local dx = x + 0.5 - half
			local dy = y + 0.5 - half
			local r = math.sqrt(dx * dx + dy * dy) / half
			-- 0 beyond 92% of the half-size, same 3 px transparent border as the splats
			local mask = Utils.clamp((0.92 - r) / 0.32, 0.0, 1.0)
			mask = smooth(mask)
			if mask > 0.0 then
				local theta = math.atan2(dy, dx)
				-- angular spikes: sample the noise on a ring around the centre
				local spike = noise(0.5 + math.cos(theta) * 1.5, 0.5 + math.sin(theta) * 1.5)
				local n = noise((x + 0.5) / size, (y + 0.5) / size)
				local a = Utils.clamp((n * 1.3 + spike * 1.2 - 1.05) * mask * 2.2, 0.0, 1.0)
				if a > 0.01 then
					local shade = 0.65 + n * 0.55
					data:setPixel(x, y, cr * shade, cg * shade, cb * shade, a)
				end
			end
		end
	end
	local image = love.graphics.newImage(data)
	image:setFilter("linear", "linear")
	return image
end

-- ------------------------------------------------------------------------
-- Shaders (light math mirrors raycaster.lua; array size 9 = MAX_LIGHTS there)
-- ------------------------------------------------------------------------

local function initShaders()
	wallDecalShader = love.graphics.newShader([[
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
	vec4 texel = Texel(tex, tc);
	if (texel.a < 0.02) { discard; }

	if (!uLighting) { return vec4(texel.rgb, texel.a); }

	// color.r = fog weight, color.g = WallX, color.b/a = map tile coordinates / 256
	float fog = color.r;
	// the decal texture spans wall heights [uHLo, uHLo + uHSpan]
	float wallH = uHLo + fract(tc.y) * uHSpan;
	vec2 lightPos = vec2(color.b * 256.0 + color.g, color.a * 256.0 + wallH);
	float lm = lightRestore(lightPos);

	float weight = 1.0 - (1.0 - fog) * lm;
	return vec4(texel.rgb * weight, texel.a);
}
]])

	floorDecalShader = love.graphics.newShader([[
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
uniform vec2 uFlip;

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
	local = local * uFlip;
	if (abs(local.x) > 1.0 || abs(local.y) > 1.0) { discard; }

	vec4 texel = Texel(tex, local * 0.5 + 0.5);
	if (texel.a < 0.02) { discard; }

	float weight = shadeWeight(currentDist, world);
	return vec4(texel.rgb * weight, texel.a);
}
]])
end

-- ------------------------------------------------------------------------
-- Init / clear / spawn
-- ------------------------------------------------------------------------

function Decals.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "EffectsConfig.ini")
	if ini then
		Decals.MaxDecals = Config.getNumber(ini, "DECALS", "MaxDecals", 48)
		Decals.WallHalfWidth = Config.getNumber(ini, "DECALS", "WallHalfWidth", 0.16)
		Decals.WallHalfHeight = Config.getNumber(ini, "DECALS", "WallHalfHeight", 0.15)
		Decals.FloorHalfSize = Config.getNumber(ini, "DECALS", "FloorHalfSize", 0.25)
		Decals.TextureVariants = Config.getNumber(ini, "DECALS", "TextureVariants", 6)
	end
	textures = {}
	local rng = love.math.newRandomGenerator(love.math.getRandomSeed())
	for i = 1, math.max(1, Decals.TextureVariants) do
		textures[i] = makeSplatTexture(rng)
	end
	initShaders()
end

function Decals.Clear()
	Decals.list = {}
end

local function add(decal)
	Decals.list[#Decals.list + 1] = decal
	while #Decals.list > Decals.MaxDecals do
		table.remove(Decals.list, 1)
	end
end

-- entity was hit by the center ray; wallInfo (optional) describes the wall
-- behind it: { mapX, mapY, side, wallX, height }
function Decals.SpawnBloodHit(entity, wallInfo)
	if #textures == 0 then return end
	local dying = entity.KillAnimEnabled or entity.Hitpoints <= 0

	if os.getenv("LARC_DEBUGDECALS") then
		print(string.format("LARC debug decal: entity (%.2f,%.2f) hp=%d wall=%s",
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
			halfW = Decals.WallHalfWidth * (0.8 + love.math.random() * 0.5),
			halfH = Decals.WallHalfHeight * (0.8 + love.math.random() * 0.5),
			flipU = love.math.random() < 0.5,
			flipV = love.math.random() < 0.5,
			tex = textures[love.math.random(#textures)]
		})
	end

	add({
		kind = "floor",
		x = entity.Pos.X + (love.math.random() - 0.5) * 0.2,
		y = entity.Pos.Y + (love.math.random() - 0.5) * 0.2,
		half = Decals.FloorHalfSize * (dying and 1.8 or (0.8 + love.math.random() * 0.5)),
		rot = love.math.random() * math.pi * 2,
		flipU = love.math.random() < 0.5,
		flipV = love.math.random() < 0.5,
		tex = textures[love.math.random(#textures)]
	})
end

-- ------------------------------------------------------------------------
-- Rendering (called from Raycaster.render, after the wall pass)
-- ------------------------------------------------------------------------

local function renderWallDecals(Raycaster)
	local records = Raycaster.WallRecords
	local W = G.Canvas.Width
	local TS = G.TextureSize
	local fog = Raycaster.FogOfWarDistance
	local lighting = Level.LightingFlag

	love.graphics.setBlendMode("alpha")
	love.graphics.setShader(wallDecalShader)
	wallDecalShader:send("uLighting", lighting)
	Raycaster.SendLights(wallDecalShader)

	for _, d in ipairs(Decals.list) do
		if d.kind == "wall" then
			wallDecalShader:send("uHLo", d.height - d.halfH)
			wallDecalShader:send("uHSpan", 2 * d.halfH)
			local tex = d.tex
			local tw, th = tex:getWidth(), tex:getHeight()
			local w0, w1 = d.wallX - d.halfW, d.wallX + d.halfW
			for x = 1, W do
				local rec = records[x]
				if rec and not rec.isDoor
					and rec.mapX == d.mapX and rec.mapY == d.mapY and rec.wallSide == d.side then
					local sliceH = rec.lineEnd - rec.lineStart
					local dv = rec.vBottom - rec.vTop
					if sliceH > 0 and dv > 0 then
						-- unwrap the fract wallX into the decal's neighbourhood:
						-- at the tile edge wallX jumps 1 -> 0 and the splat must
						-- not be split there (blood vanishing while rotating close)
						local wx = rec.wallX
						local off = wx - d.wallX
						if off > 0.5 then
							wx = wx - 1.0
						elseif off < -0.5 then
							wx = wx + 1.0
						end
						-- column footprint along the wall, from neighbour columns
						local c = 0.001
						local prev = records[x - 1]
						if prev and not prev.isDoor
							and prev.mapX == d.mapX and prev.mapY == d.mapY and prev.wallSide == d.side then
							local pd = math.abs(prev.wallX - rec.wallX)
							if pd > 0.5 then pd = 1.0 - pd end
							c = math.max(c, pd)
						end
						local nxt = records[x + 1]
						if nxt and not nxt.isDoor
							and nxt.mapX == d.mapX and nxt.mapY == d.mapY and nxt.wallSide == d.side then
							local nd = math.abs(nxt.wallX - rec.wallX)
							if nd > 0.5 then nd = 1.0 - nd end
							c = math.max(c, nd)
						end
						local lo = math.max(w0, wx - c)
						local hi = math.min(w1, wx + c)
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
							-- mirror inside the texture so each hit reads differently
							if d.flipU then u0, u1 = tw - u1, tw - u0 end
							if d.flipV then v0, v1 = th - v1, th - v0 end
							local fogW = 1.0
							if lighting then
								local f = Utils.shadeFactor(rec.wallDist, fog)
								fogW = (f == -1) and 0.0 or f
							end
							local quad = getQuad(x)
							quad:setViewport(u0, v0, u1 - u0, v1 - v0, tw, th)
							-- identical vertex color as the wall slice beneath
							love.graphics.setColor(fogW, rec.wallX, rec.mapX / 256, rec.mapY / 256)
							love.graphics.draw(tex, quad, x - 1, y0, 0, 1, (y1 - y0) / (v1 - v0))
						end
					end
				end
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

local function renderFloorDecals(Raycaster)
	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local VLT = H + G.VerticalLook
	local fog = Raycaster.FogOfWarDistance

	love.graphics.setBlendMode("alpha")
	love.graphics.setShader(floorDecalShader)
	floorDecalShader:send("uPos", { Player.Pos.X, Player.Pos.Y })
	floorDecalShader:send("uDir", { Player.Dir.X, Player.Dir.Y })
	floorDecalShader:send("uPlane", { G.Plane.X, G.Plane.Y })
	floorDecalShader:send("uVLT", VLT)
	floorDecalShader:send("uViewport", { W, H })
	floorDecalShader:send("uFogFloorCeiling", fog + fog * G.VerticalLookCamera)
	floorDecalShader:send("uLighting", Level.LightingFlag)
	Raycaster.SendLights(floorDecalShader)
	floorDecalShader:send("uZBufTex", Raycaster.ZBufferImage)

	local dirX, dirY = Player.Dir.X, Player.Dir.Y
	local planeX, planeY = G.Plane.X, G.Plane.Y
	local pp = planeX * planeX + planeY * planeY

	for _, d in ipairs(Decals.list) do
		if d.kind == "floor" then
			floorDecalShader:send("uCenter", { d.x, d.y })
			floorDecalShader:send("uHalf", d.half)
			floorDecalShader:send("uCos", math.cos(d.rot))
			floorDecalShader:send("uSin", math.sin(d.rot))
			floorDecalShader:send("uFlip", { d.flipU and -1.0 or 1.0, d.flipV and -1.0 or 1.0 })

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
				local tex = d.tex
				love.graphics.draw(tex, minX, minY, 0, bw / tex:getWidth(), bh / tex:getHeight())
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

function Decals.Render()
	if #Decals.list == 0 then return end
	local Raycaster = Game.Raycaster
	renderWallDecals(Raycaster)
	renderFloorDecals(Raycaster)
	love.graphics.setShader()
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(1, 1, 1, 1)
end

Game.Decals = Decals
return Decals
