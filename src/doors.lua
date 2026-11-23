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
	Utils.playSound(Doors.DoorTypes[door.DoorType].Sound)
end

Game.Doors = Doors
return Doors
