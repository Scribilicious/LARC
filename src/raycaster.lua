--
-- raycaster.lua - DDA raycasting engine
-- Ported from Game_Raycaster.hpp; rendering is GPU based (LÖVE):
--  * floor + ceiling: one fullscreen shader pass, per-pixel identical math
--  * walls + doors: one textured quad per screen column, fog via vertex color
--  * lighting: exact per-pixel static-light attenuation in the shaders
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")

local Raycaster = {}

Raycaster.VerticalLookLimitMin = 0.0
Raycaster.VerticalLookLimitMax = 0.4
Raycaster.PlaneStartValue = { X = 0.0, Y = 0.66 }
Raycaster.VerticalLookUpLimit = 0.4
Raycaster.VerticalLookDownLimit = 0.4
Raycaster.VerticalLookStep = 0.02
Raycaster.FogOfWarDistance = 2.5

Raycaster.ZBuffer = {}
Raycaster.diagMode = tonumber(os.getenv("LARC_DEBUGFLOOR") or "0") or 0
-- per column records for the wall pass
local WallRecords = {}
-- door list (set by doors module after level load)
Raycaster.Doors = {}

local floorShader
local wallShader
local zbufImageData
local zbufImage
local quadPool = {}

-- ------------------------------------------------------------------------
-- Init / config
-- ------------------------------------------------------------------------

function Raycaster.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "RaycasterConfig.ini")
	if ini then
		Raycaster.PlaneStartValue = {
			X = Config.getNumber(ini, "RAYCASTER", "PlaneXStartValue", 0.0),
			Y = Config.getNumber(ini, "RAYCASTER", "PlaneYStartValue", 0.66)
		}
		Raycaster.VerticalLookUpLimit = Utils.clamp(Config.getNumber(ini, "RAYCASTER", "VerticalLookUpLimit", 0.4),
			Raycaster.VerticalLookLimitMin, Raycaster.VerticalLookLimitMax)
		Raycaster.VerticalLookDownLimit = Utils.clamp(Config.getNumber(ini, "RAYCASTER", "VerticalLookDownLimit", 0.4),
			Raycaster.VerticalLookLimitMin, Raycaster.VerticalLookLimitMax)
		Raycaster.VerticalLookStep = Config.getNumber(ini, "RAYCASTER", "VerticalLookStep", 0.02)
		Raycaster.FogOfWarDistance = Config.getNumber(ini, "RAYCASTER", "FogOfWarDistance", 2.5)
	end
	G.FogOfWarDistance = Raycaster.FogOfWarDistance

	local w = G.Canvas.Width

	-- zbuffer texture: per column wall distance (r) and wall slice top (g)
	for _, format in ipairs({ "rg16f", "rgba16f" }) do
		local ok, data = pcall(love.image.newImageData, w, 1, format)
		if ok then
			zbufImageData = data
			break
		end
	end
	if not zbufImageData then
		zbufImageData = love.image.newImageData(w, 1)
	end
	zbufImage = love.graphics.newImage(zbufImageData)
	zbufImage:setFilter("nearest", "nearest")

	for x = 1, w do
		quadPool[x] = love.graphics.newQuad(0, 0, 1, 1, 1, 1)
		Raycaster.ZBuffer[x] = 1e30
	end
	Raycaster.ZBufferImage = zbufImage

	Raycaster.initShaders()
end

function Raycaster.RefreshSettings()
	G.Plane.X = Raycaster.PlaneStartValue.X
	G.Plane.Y = Raycaster.PlaneStartValue.Y
	G.VerticalLook = 0
	G.VerticalLookCamera = 0.0
end

-- ------------------------------------------------------------------------
-- Shaders
-- ------------------------------------------------------------------------

function Raycaster.initShaders()
	wallShader = love.graphics.newShader([[
uniform bool uLighting;
uniform int uLightCount;
uniform vec4 uLights[9];
uniform float uLightLoc[9];

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
	if (texel.a < 0.5) { discard; }

	if (!uLighting) { return vec4(texel.rgb, 1.0); }

	// color.r = fog weight, color.g = WallX, color.b/a = map tile coordinates / 256
	float fog = color.r;
	vec2 lightPos = vec2(color.b * 256.0 + color.g, color.a * 256.0 + fract(tc.y));
	float lm = lightRestore(lightPos);

	float weight = 1.0 - (1.0 - fog) * lm;
	return vec4(texel.rgb * weight, 1.0);
}
]])

	floorShader = love.graphics.newShader([[
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
uniform Image uMapTex;
uniform Image uAtlas;
uniform Image uZBufTex;
uniform vec2 uMapTiles;
uniform vec2 uAtlasTiles;
uniform float uTextureSize;
uniform float uDiag;

// per-pixel light attenuation, identical to the C++ GetIntensity blend chain
float lightRestore(vec2 world, float layer)
{
	float lm = 1.0;
	for (int i = 0; i < 9; ++i) {
		if (i >= uLightCount) { break; }
		if (abs(uLightLoc[i] - layer) > 0.5) { continue; }
		vec4 light = uLights[i];
		float d = length(world - light.xy);
		if (d < light.z && light.w > 0.0) {
			lm *= 1.0 - light.w * (light.z - d) / light.z;
		}
	}
	return lm;
}

float shadeWeight(float currentDist, vec2 world, float layer)
{
	if (!uLighting) { return 1.0; }
	float fog = clamp((uFogFloorCeiling - currentDist) / uFogFloorCeiling, 0.0, 1.0);
	float lm = lightRestore(world, layer);
	return 1.0 - (1.0 - fog) * lm;
}

// sample level texture atlas at a world position; slot = texture index - 1
vec4 atlasTexel(vec2 world, float slot)
{
	vec2 texelUV = floor(fract(world) * uTextureSize);
	vec2 atlasTile = vec2(mod(slot, uAtlasTiles.x), floor(slot / uAtlasTiles.x));
	vec2 uv = (atlasTile * uTextureSize + texelUV + vec2(0.5)) / (uAtlasTiles * uTextureSize);
	return Texel(uAtlas, uv);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sccoord)
{
	float x = sccoord.x;
	float y = sccoord.y;
	float cam = (x + x) / uViewport.x - 1.0;
	vec2 raydir = uDir + uPlane * cam;

	vec4 zbuf = Texel(uZBufTex, vec2((x + 0.5) / uViewport.x, 0.5));
	float wallDist = zbuf.r;
	float lineStart = zbuf.g;

	bool isFloor = (y + y > uVLT);

	float currentDist;
	if (isFloor) {
		currentDist = uVLT / max(y + y - uVLT, 0.0001);
	} else {
		currentDist = uVLT / max(uVLT - y - y, 0.0001);
	}

	// vertical look stretches the row distances; texture world positions use
	// the C++ lerp towards FloorWall: pos + ray * CurrentDist / (1 + VerticalLookCamera),
	// where (1 + VerticalLookCamera) == uVLT / uViewport.y
	float lookScale = uVLT / uViewport.y;

	// DIAGNOSTIC MODES (LARC_DEBUGFLOOR=1/2/3): output intermediates as colors
	// 1: R = dist/8, G = fract(world.x), B = fract(world.y)
	if (uDiag > 0.5 && uDiag < 1.5) {
		vec2 worldDiag = uPos + raydir * (currentDist / lookScale);
		return vec4(currentDist / 8.0, fract(worldDiag.x), fract(worldDiag.y), 1.0);
	}
	// 2: R = shade weight, G = light restore factor, B = texture index / 16
	if (uDiag > 1.5 && uDiag < 2.5) {
		vec2 worldD = uPos + raydir * (currentDist / lookScale);
		vec2 tileD = floor(worldD);
		float idxD;
		float layerD;
		if (isFloor) {
			idxD = floor(Texel(uMapTex, (tileD + vec2(0.5)) / uMapTiles).g * 255.0 + 0.5);
			layerD = 0.0;
		} else {
			idxD = floor(Texel(uMapTex, (tileD + vec2(0.5)) / uMapTiles).b * 255.0 + 0.5);
			layerD = 2.0;
		}
		float lmD = lightRestore(worldD, layerD);
		float wgtD = shadeWeight(currentDist, worldD, layerD);
		return vec4(wgtD, lmD, idxD / 16.0, 1.0);
	}
	// 3: R/G/B = atlas texel the shader samples at the computed slot
	if (uDiag > 2.5) {
		vec2 worldD = uPos + raydir * (currentDist / lookScale);
		vec2 tileD = floor(worldD);
		float idxD;
		if (isFloor) {
			idxD = floor(Texel(uMapTex, (tileD + vec2(0.5)) / uMapTiles).g * 255.0 + 0.5);
		} else {
			idxD = floor(Texel(uMapTex, (tileD + vec2(0.5)) / uMapTiles).b * 255.0 + 0.5);
		}
		if (idxD < 1.0) { return vec4(0.0, 0.0, 0.0, 1.0); }
		return vec4(atlasTexel(worldD, idxD - 1.0).rgb, 1.0);
	}

	vec2 world = uPos + raydir * (currentDist / lookScale);
	vec2 tile = floor(world);
	vec2 mapUV = (tile + vec2(0.5)) / uMapTiles;

	if (isFloor) {
		if (currentDist < wallDist * lookScale) {
			float floorIdx = floor(Texel(uMapTex, mapUV).g * 255.0 + 0.5);
			if (floorIdx < 1.0) { return vec4(0.0, 0.0, 0.0, 1.0); }
			vec4 texel = atlasTexel(world, floorIdx - 1.0);
			float weight = shadeWeight(currentDist, world, 0.0);
			return vec4(texel.rgb * weight, 1.0);
		}
		// covered by a wall slice
		return vec4(0.0, 0.0, 0.0, 1.0);
	}

	// ceiling: only rows above the wall slice top are visible
	if (y > lineStart) { return vec4(0.0, 0.0, 0.0, 1.0); }
	float ceilingIdx = floor(Texel(uMapTex, mapUV).b * 255.0 + 0.5);
	if (ceilingIdx < 1.0) { return vec4(0.0, 0.0, 0.0, 0.0); } // transparent: skybox shows
	vec4 texel = atlasTexel(world, ceilingIdx - 1.0);
	float weight = shadeWeight(currentDist, world, 2.0);
	return vec4(texel.rgb * weight, 1.0);
}
]])
end

-- ------------------------------------------------------------------------
-- DDA column casting (port of CastGraphics, all renderparts combined)
-- ------------------------------------------------------------------------

local EPS = 1e-6

-- runs the DDA for one column and fills a record; returns nothing
local function castColumn(x, rec)
	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local posX, posY = Player.Pos.X, Player.Pos.Y
	local VLT = H + G.VerticalLook
	local cam = (x + x) / W - 1.0

	local rayX = Player.Dir.X + G.Plane.X * cam
	local rayY = Player.Dir.Y + G.Plane.Y * cam

	local deltaDX = math.sqrt(rayX * rayX + rayY * rayY) / math.abs(rayX + EPS) -- ~inf when rayX==0
	local deltaDY = math.sqrt(rayX * rayX + rayY * rayY) / math.abs(rayY + EPS)
	if math.abs(rayX) < EPS then deltaDX = 1e30 end
	if math.abs(rayY) < EPS then deltaDY = 1e30 end

	local mapX = math.floor(posX)
	local mapY = math.floor(posY)

	local stepX, sideX, stepY, sideY
	if rayX < 0.0 then
		stepX = -1.0
		sideX = (posX - mapX) * deltaDX
	else
		stepX = 1.0
		sideX = (mapX + 1.0 - posX) * deltaDX
	end
	if rayY < 0.0 then
		stepY = -1.0
		sideY = (posY - mapY) * deltaDY
	else
		stepY = 1.0
		sideY = (mapY + 1.0 - posY) * deltaDY
	end

	local wallHit = false
	local wallSide = false
	local doorNumber = -1
	local doors = Raycaster.Doors
	local wallLayer = Level.layers[Level.WALL]

	while not wallHit do
		if sideX < sideY then
			sideX = sideX + deltaDX
			mapX = mapX + stepX
			wallSide = false
		else
			sideY = sideY + deltaDY
			mapY = mapY + stepY
			wallSide = true
		end

		for i = 1, #doors do
			local door = doors[i]
			if math.abs(door.Pos.X - mapX) < EPS and math.abs(door.Pos.Y - mapY) < EPS then
				local mp2X, mp2Y = mapX, mapY
				if posX < mp2X then mp2X = mp2X - 1.0 end
				if posY > mp2Y then mp2Y = mp2Y + 1.0 end

				local rayMulti
				if wallSide then
					rayMulti = (mp2Y - posY) / rayY
				else
					rayMulti = ((mp2X - posX) + 1.0) / rayX
				end
				local resX = posX + rayX * rayMulti
				local resY = posY + rayY * rayMulti
				local openPercent = door.CurrentOpenPercent

				if not wallSide then
					local stepYY = math.sqrt(deltaDX * deltaDX - 1.0)
					local probeY = resY + (stepY * stepYY) * 0.5
					if math.abs(math.floor(probeY) - mapY) < EPS and (probeY - mapY > openPercent / 100.0) then
						wallHit = true
						doorNumber = i
					end
				else
					local stepXX = math.sqrt(deltaDY * deltaDY - 1.0)
					local probeX = resX + (stepX * stepXX) * 0.5
					if math.abs(math.floor(probeX) - mapX) < EPS and (probeX - mapX > openPercent / 100.0) then
						wallHit = true
						doorNumber = i
					end
				end
			end
		end

		local wallValue = wallLayer[mapX + 1] and wallLayer[mapX + 1][mapY + 1] or 0
		if wallValue and wallValue > 0 and wallValue ~= Level.DOORWALL then
			wallHit = true
		end
	end

	local wallDist
	if not wallSide then
		if doorNumber > -1 then
			mapX = mapX + stepX * 0.5
		end
		wallDist = (mapX - posX + (1.0 - stepX) * 0.5) / rayX
	else
		if doorNumber > -1 then
			mapY = mapY + stepY * 0.5
		end
		wallDist = (mapY - posY + (1.0 - stepY) * 0.5) / rayY
	end

	local lineHeight = math.floor(H / wallDist)
	local temp = math.floor(VLT / 2)
	local lineStart = math.max(-math.floor(lineHeight / 2) + temp, 0)
	local lineEnd = math.min(math.floor(lineHeight / 2) + temp, H)

	local wallX
	if wallSide then
		wallX = posX + wallDist * rayX
	else
		wallX = posY + wallDist * rayY
	end
	wallX = wallX - math.floor(wallX)

	local TS = G.TextureSize
	local textureX = math.floor(wallX * TS) % TS

	local isDoor = doorNumber > -1
	if isDoor then
		local door = doors[doorNumber]
		local doorType = Game.Doors.DoorTypes[door.DoorType]
		-- Game_Raycaster.hpp: +1 while the door is not fully closed, then the
		-- (truncated) percent offset; the content slide itself comes from the
		-- per-door AnimTexture written by ModifyDoorTexture (Game_Doors.hpp)
		if door.CurrentOpenPercent > doorType.MinimumOpenPercent then
			textureX = textureX + 1
		end
		textureX = textureX - math.floor(door.CurrentOpenPercent / doorType.MaximumOpenPercent)
	end

	-- fill record
	rec.x = x
	rec.isDoor = isDoor
	rec.doorNumber = doorNumber
	rec.wallSide = wallSide
	rec.lineStart = lineStart
	rec.lineEnd = lineEnd
	rec.wallDist = wallDist
	rec.textureX = textureX
	rec.mapX = math.floor(mapX)
	rec.mapY = math.floor(mapY)
	rec.wallX = wallX

	-- vertical texture coordinates ("v") over the full wall slice
	local vTop = ((2 * lineStart - VLT + lineHeight) * TS) / (2 * lineHeight)
	local vBottom = ((2 * lineEnd - VLT + lineHeight) * TS) / (2 * lineHeight)
	rec.vTop = vTop
	rec.vBottom = vBottom
end

-- casts all columns; fills WallRecords + zbuffer texture/arrays
function Raycaster.castWalls()
	local W = G.Canvas.Width
	local Player = Game.Player
	local VLT = G.Canvas.Height + G.VerticalLook

	for x = 1, W do
		local rec = WallRecords[x]
		if not rec then
			rec = {}
			WallRecords[x] = rec
		end
		castColumn(x - 1, rec)
		Raycaster.ZBuffer[x] = rec.wallDist
		zbufImageData:setPixel(x - 1, 0, rec.wallDist, rec.lineStart, 0, 1)
	end
	zbufImage:replacePixels(zbufImageData)
end

-- ZBuffer lookup: 1 based column, returns wall distance
function Raycaster.getZBuffer(x)
	return Raycaster.ZBuffer[x]
end

-- ------------------------------------------------------------------------
-- Rendering
-- ------------------------------------------------------------------------

-- Maximum number of static lights supported by the shaders
local MAX_LIGHTS = 9

-- sends the level's static lights to a shader (exact C++ GetIntensity math)
local function sendLights(shader)
	local lights = Level.StaticLights
	local lightVecs, lightLocs = {}, {}
	local count = math.min(#lights, MAX_LIGHTS)
	for i = 1, count do
		local light = lights[i]
		lightVecs[i] = { light.Pos.X, light.Pos.Y, light.Radius, light.Intensity }
		lightLocs[i] = light.Location
	end
	for i = count + 1, MAX_LIGHTS do
		lightVecs[i] = { 0, 0, 0, 0 }
		lightLocs[i] = -1
	end
	shader:send("uLightCount", count)
	shader:send("uLights", unpack(lightVecs))
	shader:send("uLightLoc", unpack(lightLocs))
end

-- draws the full floor + ceiling pass
function Raycaster.renderFloorCeiling()
	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local VLT = H + G.VerticalLook

	local fog = Raycaster.FogOfWarDistance
	local floorCeilingShading = fog + fog * G.VerticalLookCamera

	local shader = floorShader
	love.graphics.setShader(shader)
	shader:send("uPos", { Player.Pos.X, Player.Pos.Y })
	shader:send("uDir", { Player.Dir.X, Player.Dir.Y })
	shader:send("uPlane", { G.Plane.X, G.Plane.Y })
	shader:send("uVLT", VLT)
	shader:send("uViewport", { W, H })
	shader:send("uFogFloorCeiling", floorCeilingShading)
	shader:send("uLighting", Level.LightingFlag)
	shader:send("uDiag", Raycaster.diagMode)
	sendLights(shader)
	shader:send("uMapTex", Level.mapTexture)
	shader:send("uAtlas", Level.atlasImage)
	shader:send("uZBufTex", zbufImage)
	shader:send("uMapTiles", { Level.LevelMapWidth, Level.LevelMapHeight })
	shader:send("uAtlasTiles", { Level.atlasCols, Level.atlasRows })
	shader:send("uTextureSize", G.TextureSize)
	-- "alpha" instead of "replace": the shader's transparent output
	-- (ceilingIdx < 1 = sky visible) must KEEP the skybox pixels below,
	-- like the C++ canvas that only writes pixels for drawn geometry
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.rectangle("fill", 0, 0, W, H)
	love.graphics.setBlendMode("alpha")
	love.graphics.setShader()
end

-- draws the wall columns (including doors)
function Raycaster.renderWalls()
	local TS = G.TextureSize
	local fog = Raycaster.FogOfWarDistance
	local lighting = Level.LightingFlag
	local W = G.Canvas.Width

	love.graphics.setBlendMode("replace")
	love.graphics.setShader(wallShader)
	wallShader:send("uLighting", lighting)
	sendLights(wallShader)

	for x = 1, W do
		local rec = WallRecords[x]
		local sliceHeight = rec.lineEnd - rec.lineStart
		if sliceHeight > 0 then
			local texture
			if rec.isDoor then
				local door = Raycaster.Doors[rec.doorNumber]
				texture = door.AnimTexture
			else
				local wallValue = Level.layers[Level.WALL][rec.mapX + 1] and Level.layers[Level.WALL][rec.mapX + 1][rec.mapY + 1] or 1
				texture = Level.LevelTextures[wallValue]
			end
			if texture then
				local fogW = 1.0
				if lighting then
					local f = Utils.shadeFactor(rec.wallDist, fog)
					fogW = (f == -1) and 0.0 or f
				end
				local u = rec.textureX
				local quad = quadPool[x]
				quad:setViewport(u, rec.vTop, 1, rec.vBottom - rec.vTop, texture:getWidth(), texture:getHeight())
				love.graphics.setColor(fogW, rec.wallX, rec.mapX / 256, rec.mapY / 256)
				love.graphics.draw(texture, quad, x - 1, rec.lineStart, 0, 1, sliceHeight / (rec.vBottom - rec.vTop))
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setBlendMode("alpha")
	love.graphics.setShader()
end

function Raycaster.render()
	Raycaster.castWalls()
	Raycaster.renderFloorCeiling()
	Raycaster.renderWalls()
	-- blood decals sit on the walls/floor, in front of them but behind entities
	if Game.Decals then
		Game.Decals.Render()
	end
end

-- exposed for the decals module (src/decals.lua)
Raycaster.WallRecords = WallRecords
Raycaster.SendLights = sendLights

Game.Raycaster = Raycaster
return Raycaster
