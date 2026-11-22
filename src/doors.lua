--
-- doors.lua - sliding door handling
-- Ported from Game_Doors.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")
local Entities = require("src/entities")

local Doors = {}

Doors.DoorTypes = {}
Doors.Doors = {}

local EntityTypes = Entities.EntityTypes

function Doors.InitDoorAssets()
	Doors.DoorTypes = {}

	local index = 1
	while true do
		local iniFile = G.AssetsDoorsFolder .. "Door_" .. index .. "_Data.ini"
		if Utils.fileExists(iniFile) then
			local ini = Config.loadINI(iniFile)
			local doorType = {}
			local sound = Config.getString(ini, "AUDIO", "OpenCloseSound")
			doorType.Sound = sound and love.audio.newSource(Config.fixPath(sound), "static") or nil
			doorType.Texture, doorType.TextureData = Utils.loadImage(Config.getString(ini, "TEXTURE", "DoorTexture"))
			doorType.Texture:setWrap("repeat")
			doorType.OpenCloseSpeed = Config.getNumber(ini, "GENERAL", "OpenCloseSpeed", 4)
			doorType.StayOpenTime = Config.getNumber(ini, "GENERAL", "StayOpenTime", 3) * G.FrameLock
			doorType.MaximumOpenPercent = Config.getNumber(ini, "GENERAL", "MaximumOpenPercent", 100.0)
			doorType.MinimumOpenPercent = Config.getNumber(ini, "GENERAL", "MinimumOpenPercent", 0.0)
			-- LARC addition: leaf depth across the doorway, in tiles. The C++
			-- draws the door as an infinitely thin plane; anything from a fine
			-- frame (0.05) to a real slab (0.5) works, 0 would be degenerate
			doorType.Thickness = Utils.clamp(Config.getNumber(ini, "GENERAL", "Thickness", 0.15), 0.01, 0.9)
			Doors.DoorTypes[index] = doorType
			index = index + 1
		else
			break
		end
	end
end

-- port of Game_Doors.hpp ModifyDoorTexture: slides the texture content in
-- place per row. The leading OpenPercent texels of each row keep their
-- (stale) content, exactly like the C++ std::copy loop, so the partially
-- open door shows the same leftover slivers as the original
local function modifyDoorTexture(door)
	local doorType = Doors.DoorTypes[door.DoorType]
	local TS = G.TextureSize
	-- "TextureOffset is not correct - works only when MaximumOpenPercent = 100%"
	local textureOffset = 100.0 / TS
	local openPercent = math.floor(door.CurrentOpenPercent / textureOffset)
	local source = doorType.TextureData
	local anim = door.AnimData
	for y = 0, TS - 1 do
		for j = 0, TS - 1 - openPercent do
			anim:setPixel(openPercent + j, y, source:getPixel(j, y))
		end
	end
	door.AnimTexture:replacePixels(anim)
end

-- LARC addition: the door has no orientation in the level data, so derive it
-- from the surrounding walls - a door whose neighbours sit on the +-X side is
-- set into a wall running along X, so the leaf is thin across Y. Corners and
-- free standing doors fall back to "y".
local function findLeafAxis(x, y)
	local acrossX = 0
	local acrossY = 0
	if Level.isWall(x - 1, y) then acrossX = acrossX + 1 end
	if Level.isWall(x + 1, y) then acrossX = acrossX + 1 end
	if Level.isWall(x, y - 1) then acrossY = acrossY + 1 end
	if Level.isWall(x, y + 1) then acrossY = acrossY + 1 end
	if acrossY > acrossX then return "x" end
	return "y"
end

-- leaf bounds in map coordinates: x0, x1, y0, y1. The slab is centred in the
-- door tile and retracts towards the low end of the axis it slides along,
-- which is where the C++ leaves the passable gap (Game_Raycaster.hpp compares
-- the tile fraction against OpenPercent).
local function leafBounds(door)
	local open = door.CurrentOpenPercent / 100.0
	local half = door.Thickness * 0.5
	local x, y = door.Pos.X, door.Pos.Y
	if door.Axis == "y" then
		return x + open, x + 1.0, y + 0.5 - half, y + 0.5 + half
	end
	return x + 0.5 - half, x + 0.5 + half, y + open, y + 1.0
end

local RAY_EPS = 1e-9

-- Ray/leaf intersection for one column. Returns nil or
-- { T = ray multiplier (same parameter as the raycaster's wallDist),
--   FaceAxis = axis the hit face is perpendicular to,
--   Across = 0..1 across the leaf's thickness (thin faces only) }
function Doors.HitTest(door, posX, posY, rayX, rayY)
	local x0, x1, y0, y1 = leafBounds(door)
	if x1 - x0 < 1e-6 or y1 - y0 < 1e-6 then return nil end

	local tNearX, tFarX
	if math.abs(rayX) < RAY_EPS then
		if posX < x0 or posX > x1 then return nil end
		tNearX, tFarX = -math.huge, math.huge
	else
		tNearX = (x0 - posX) / rayX
		tFarX = (x1 - posX) / rayX
		if tNearX > tFarX then tNearX, tFarX = tFarX, tNearX end
	end
	local tNearY, tFarY
	if math.abs(rayY) < RAY_EPS then
		if posY < y0 or posY > y1 then return nil end
		tNearY, tFarY = -math.huge, math.huge
	else
		tNearY = (y0 - posY) / rayY
		tFarY = (y1 - posY) / rayY
		if tNearY > tFarY then tNearY, tFarY = tFarY, tNearY end
	end

	-- tEnter <= 0 means the camera sits inside the leaf: there is no surface
	-- left to draw, and letting the ray through beats a wall in your face
	local tEnter = math.max(tNearX, tNearY)
	if tEnter > math.min(tFarX, tFarY) or tEnter <= 0.0 then return nil end

	-- Across is only used on the thin sides (the leaf's depth), so measure it
	-- along the leaf's thin axis
	local thinMin, thinMax, thinHit
	if door.Axis == "y" then
		thinMin, thinMax, thinHit = y0, y1, posY + tEnter * rayY
	else
		thinMin, thinMax, thinHit = x0, x1, posX + tEnter * rayX
	end
	return {
		T = tEnter,
		FaceAxis = (tNearX >= tNearY) and "x" or "y",
		Across = Utils.clamp((thinHit - thinMin) / (thinMax - thinMin), 0.0, 1.0)
	}
end

function Doors.InitDoors()
	Doors.Doors = {}

	for mapPosX = 0, Level.LevelMapWidth - 1 do
		for mapPosY = 0, Level.LevelMapHeight - 1 do
			local foundDoorType = Level.getLayer(Level.DOOR, mapPosX, mapPosY)
			if foundDoorType and foundDoorType > 0 then
				local door = {}
				door.Pos = { X = mapPosX, Y = mapPosY }
				door.State = "closed"
				door.DoorType = foundDoorType
				door.Number = #Doors.Doors + 1
				door.CurrentOpenPercent = Doors.DoorTypes[foundDoorType].MinimumOpenPercent
				door.StayOpenCounter = 0
				door.CloseAudioFlag = false
				door.Axis = findLeafAxis(mapPosX, mapPosY)
				door.Thickness = Doors.DoorTypes[foundDoorType].Thickness
				-- AnimTexture starts as a copy of the original (Game_Doors.hpp Init)
				door.AnimData = love.image.newImageData(G.TextureSize, G.TextureSize)
				door.AnimData:paste(Doors.DoorTypes[foundDoorType].TextureData, 0, 0)
				door.AnimTexture = love.graphics.newImage(door.AnimData)
				door.AnimTexture:setFilter("nearest", "nearest")
				door.AnimTexture:setWrap("repeat")
				modifyDoorTexture(door)
				Doors.Doors[#Doors.Doors + 1] = door

				-- block the wall of the door tile (C++ sets it to INT_MAX)
				Level.setLayer(Level.WALL, mapPosX, mapPosY, Level.DOORWALL)
			end
		end
	end

	Game.Raycaster.Doors = Doors.Doors
end

function Doors.TriggerDoor()
	local Player = Game.Player
	for _, door in ipairs(Doors.Doors) do
		if door.State == "closed"
			and math.abs(door.Pos.X - Player.FuturePos.X) < 1e-6
			and math.abs(door.Pos.Y - Player.FuturePos.Y) < 1e-6 then
			door.State = "triggered"
			Doors.PlayAudio(door)
			break
		end
	end
end

function Doors.OpenCloseDoors()
	local Player = Game.Player
	local EntityMap = Game.Entities.EntityMap

	for _, door in ipairs(Doors.Doors) do
		local doorType = Doors.DoorTypes[door.DoorType]

		-- open door
		if door.State == "triggered" then
			if door.CurrentOpenPercent < doorType.MaximumOpenPercent then
				door.CurrentOpenPercent = door.CurrentOpenPercent + doorType.OpenCloseSpeed
				modifyDoorTexture(door)
			end
			if door.CurrentOpenPercent >= doorType.MaximumOpenPercent then
				door.State = "open"
				door.StayOpenCounter = doorType.StayOpenTime
				door.CurrentOpenPercent = doorType.MaximumOpenPercent
				Level.setLayer(Level.WALL, door.Pos.X, door.Pos.Y, 0)
			end
		end

		-- close door, but check that it is not blocked
		if door.State == "open"
			and EntityMap[door.Pos.X + 1][door.Pos.Y + 1] == EntityTypes.CLEAR
			and (math.abs(Player.Pos.X - door.Pos.X) > 1e-6 or math.abs(Player.Pos.Y - door.Pos.Y) > 1e-6) then
			door.StayOpenCounter = door.StayOpenCounter - 1
			if door.StayOpenCounter <= 0 then
				if door.CurrentOpenPercent >= doorType.OpenCloseSpeed then
					if not door.CloseAudioFlag then
						Doors.PlayAudio(door)
						door.CloseAudioFlag = true
					end
					door.CurrentOpenPercent = door.CurrentOpenPercent - doorType.OpenCloseSpeed
					modifyDoorTexture(door)
				end
			end

			if door.CurrentOpenPercent <= doorType.MinimumOpenPercent then
				door.State = "closed"
				door.CloseAudioFlag = false
				door.CurrentOpenPercent = doorType.MinimumOpenPercent
				Level.setLayer(Level.WALL, door.Pos.X, door.Pos.Y, Level.DOORWALL)
			end
		end
	end
end

function Doors.PlayAudio(door)
	local sound = Doors.DoorTypes[door.DoorType].Sound
	if sound then
		sound:play()
	end
end

Game.Doors = Doors
return Doors
