--
-- level.lua - level/map loading, textures, lights, music
-- Ported from Game_LevelHandling.hpp + GFX_LightingClass.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")

local Level = {}

-- Layer indices (enum class LevelMapLayers)
Level.FLOOR = 1
Level.WALL = 2
Level.CEILING = 3
Level.DOOR = 4
Level.LAYERCOUNT = 4

-- Marker for "wall blocked by a door": C++ uses INT_MAX here
Level.DOORWALL = 1e15

Level.layers = {}
Level.LevelTextures = {}
Level.StaticLights = {}
Level.BackgroundMusic = nil
Level.BackgroundMusicPaused = false
Level.LevelMapWidth = 0
Level.LevelMapHeight = 0
Level.LightingFlag = false
Level.BackgroundMusicEnabled = false

-- GPU helpers for the floor/ceiling shader
Level.atlasImage = nil
Level.atlasCols = 4
Level.atlasRows = 4
Level.mapTexture = nil

local function levelFile(name)
	return G.LevelFolder .. G.SelectedLevel .. "/LevelData/" .. name
end

function Level.InitConfig()
	local ini = Config.loadINI(levelFile("Config.ini"))
	if ini then
		Level.LightingFlag = Config.getBoolean(ini, "GENERAL", "Lighting", false)
	end
end

-- ReadMapDataFile: each line is one map row of comma separated values
local function readMapDataFile(fileName, layer)
	if Utils.fileExists(fileName) then
		local lastLine = nil
		for line in love.filesystem.lines(Config.fixPath(fileName)) do
			if line:match("%S") then
				local values = Utils.parseConfNumbers(line)
				local grid = Level.layers[layer]
				grid[#grid + 1] = values
				lastLine = values
			end
		end
		-- double the last line for ceiling only (prevents bad lighting behaviour)
		if layer == Level.CEILING and lastLine then
			local grid = Level.layers[layer]
			grid[#grid + 1] = lastLine
		end
	end
end

function Level.InitMapData()
	Level.layers = {}
	for i = 1, Level.LAYERCOUNT do
		Level.layers[i] = {}
	end

	local path = G.LevelFolder .. G.SelectedLevel .. "/LevelData/"

	-- NOTE: file line index is the "X" coordinate, column index inside a line is "Y"
	readMapDataFile(path .. "MapFloorData.conf", Level.FLOOR)
	readMapDataFile(path .. "MapWallData.conf", Level.WALL)
	readMapDataFile(path .. "MapCeilingData.conf", Level.CEILING)
	readMapDataFile(path .. "MapDoorData.conf", Level.DOOR)

	Level.LevelMapWidth = #Level.layers[Level.WALL]
	Level.LevelMapHeight = Level.LevelMapWidth > 0 and #Level.layers[Level.WALL][1] or 0
end

-- 0-based coordinate access -----------------------------------------------

function Level.getLayer(layer, x, y)
	local grid = Level.layers[layer]
	local row = grid[x + 1]
	if not row then return nil end
	return row[y + 1]
end

function Level.setLayer(layer, x, y, value)
	local grid = Level.layers[layer]
	local row = grid[x + 1]
	if row then
		row[y + 1] = value
	end
end

function Level.isWall(x, y)
	local v = Level.getLayer(Level.WALL, x, y)
	return v ~= nil and v ~= 0 and v ~= Level.DOORWALL
end

-- InitLights (GFX_LightingClass) ------------------------------------------

local Light = {}
Light.__index = Light
Level.Light = Light

function Light.new(posX, posY, location, radius, intensity)
	local self = setmetatable({}, Light)
	self.Pos = { X = posX, Y = posY }
	self.Location = location -- 0=Floor, 1=Wall, 2=Ceiling, 3=Door (LevelMap layers - 1)
	self.Radius = radius
	self.Intensity = intensity
	return self
end

-- GetIntensity at map position (x,y)
function Light:getIntensity(x, y)
	local dist = Utils.distance(x, self.Pos.X, y, self.Pos.Y)
	if dist > self.Radius then
		return 0.0
	end
	return self.Intensity * ((self.Radius - dist) / self.Radius)
end

function Level.InitLights()
	Level.StaticLights = {}
	if Level.LightingFlag then
		local fileName = levelFile("StaticLightsData.conf")
		if Utils.fileExists(fileName) then
			for line in love.filesystem.lines(Config.fixPath(fileName)) do
				if line:match("%S") then
					local v = Utils.parseConfNumbers(line)
					if #v >= 5 then
						Level.StaticLights[#Level.StaticLights + 1] =
							Light.new(v[1], v[2], math.floor(v[3]), v[4], v[5])
					end
				end
			end
		end
	end
end

-- InitTextures: list of LevelTextures + GPU atlas + mapRGB texture ----------

function Level.InitTextures()
	Level.LevelTextures = {}
	local fileName = levelFile("TexturesData.conf")
	if Utils.fileExists(fileName) then
		for line in love.filesystem.lines(Config.fixPath(fileName)) do
			local name = line:match("^%s*(.-)%s*$")
			if name ~= "" then
				local image = Utils.loadImage("./GFX/LevelTextures/" .. G.TextureSize .. "/" .. name, G.TextureSize)
				Level.LevelTextures[#Level.LevelTextures + 1] = image
			end
		end
	end

	Level.buildAtlas()
	Level.buildMapTexture()
end

function Level.textureCount()
	return #Level.LevelTextures
end

-- Builds one texture atlas (atlasCols x atlasRows tiles) out of all level textures
function Level.buildAtlas()
	local count = #Level.LevelTextures
	Level.atlasCols = math.max(1, math.min(count, 8))
	Level.atlasRows = math.ceil(count / Level.atlasCols)
	if Level.atlasRows < 1 then Level.atlasRows = 1 end
	local ts = G.TextureSize
	local atlas = love.graphics.newCanvas(Level.atlasCols * ts, Level.atlasRows * ts)
	love.graphics.push("all")
	love.graphics.setCanvas(atlas)
	love.graphics.clear(0, 0, 0, 0)
	for i, image in ipairs(Level.LevelTextures) do
		local slot = i - 1
		local cx = slot % Level.atlasCols
		local cy = math.floor(slot / Level.atlasCols)
		love.graphics.draw(image, cx * ts, cy * ts)
	end
	love.graphics.setCanvas()
	love.graphics.pop()
	local imageData = atlas:newImageData()
	Level.atlasImage = love.graphics.newImage(imageData)
	Level.atlasImage:setFilter("nearest", "nearest")
end

-- Builds a mapW x mapH RGBA texture holding the texture indices per tile:
-- R = wall index (0 = none, 255 = door), G = floor index, B = ceiling index, A = door index
function Level.buildMapTexture()
	local w, h = Level.LevelMapWidth, Level.LevelMapHeight
	local imageData = love.image.newImageData(w, h)
	for x = 1, w do
		for y = 1, h do
			local wall = Level.layers[Level.WALL][x][y] or 0
			if wall == Level.DOORWALL then wall = 255 end
			local floorTex = Level.layers[Level.FLOOR][x] and Level.layers[Level.FLOOR][x][y] or 0
			local ceilTex = Level.layers[Level.CEILING][x] and Level.layers[Level.CEILING][x][y] or 0
			local door = Level.layers[Level.DOOR][x] and Level.layers[Level.DOOR][x][y] or 0
			imageData:setPixel(x - 1, y - 1,
				math.min(wall, 255) / 255, math.min(floorTex, 255) / 255,
				math.min(ceilTex, 255) / 255, math.min(door, 255) / 255)
		end
	end
	Level.mapTexture = love.graphics.newImage(imageData)
	Level.mapTexture:setFilter("nearest", "nearest")
end

-- Background music ---------------------------------------------------------

function Level.InitBackgroundMusic()
	Level.StopBackgroundMusic()
	local ini = Config.loadINI(levelFile("Config.ini"))
	if not ini then return end
	Level.BackgroundMusicEnabled = Config.getBoolean(ini, "AUDIO", "BackgroundMusicEnabled", false)
	if Level.BackgroundMusicEnabled then
		local audioFile = Config.getString(ini, "AUDIO", "BackgroundMusic")
		if audioFile then
			Level.BackgroundMusic = love.audio.newSource(Config.fixPath(audioFile), "stream")
			Level.BackgroundMusic:setLooping(true)
		end
	end
end

function Level.PlayBackgroundMusic()
	if Level.BackgroundMusicEnabled and Level.BackgroundMusic then
		-- the pause menu pauses the track every frame (Menu.Show, like the
		-- C++ Show()); like the C++ MP3Player.IsFinished() gate, never
		-- resume a paused track - the LÖVE source would otherwise resume
		-- and pause each frame, which is audible as stuttering
		if not Level.BackgroundMusicPaused and not Level.BackgroundMusic:isPlaying() then
			Level.BackgroundMusic:play()
		end
	end
end

function Level.PauseBackgroundMusic()
	if Level.BackgroundMusicEnabled and Level.BackgroundMusic then
		Level.BackgroundMusic:pause()
		Level.BackgroundMusicPaused = true
	end
end

function Level.RestartBackgroundMusic()
	if Level.BackgroundMusicEnabled and Level.BackgroundMusic then
		if not Level.BackgroundMusic:isPlaying() then
			Level.BackgroundMusic:play()
		else
			Level.BackgroundMusic:stop()
			Level.BackgroundMusic:play()
		end
		Level.BackgroundMusicPaused = false
	end
end

function Level.StopBackgroundMusic()
	if Level.BackgroundMusic then
		Level.BackgroundMusic:stop()
		Level.BackgroundMusic = nil
		Level.BackgroundMusicPaused = false
	end
end

return Level
