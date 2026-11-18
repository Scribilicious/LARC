--
-- entities.lua - entity assets, entity behaviour, entity rendering
-- Ported from Game_EntityHandling.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")

local Entities = {}

-- enum class EntityTypes
EntityTypes = {
	CLEAR = 0,
	NEUTRAL = 1,
	ENEMY = 2,
	PLAYER = 3,
	AMMOBOX = 4,
	TURRET = 5
}
Entities.EntityTypes = EntityTypes

-- Possible directions: DirX / DirY / Heading / RotationFactor
local Directions = {
	{ -1.0, 0.0, "N", 0 },
	{ 1.0, 0.0, "S", 4 },
	{ 0.0, 1.0, "E", 2 },
	{ 0.0, -1.0, "W", 6 }
}

local EntityCollisionDetectionWallDist = 0.5

Entities.EntityAssets = {}
Entities.Entities = {}
Entities.EntityMap = {}
Entities.EntityOrder = {}

local quadPool = {}
local quadPoolSize = 0

local function getQuad(i)
	if quadPool[i] == nil then
		quadPool[i] = love.graphics.newQuad(0, 0, 1, 1, 1, 1)
		quadPoolSize = math.max(quadPoolSize, i)
	end
	return quadPool[i]
end

-- ------------------------------------------------------------------------
-- Asset loading
-- ------------------------------------------------------------------------

function Entities.CloseAudio()
	for _, asset in ipairs(Entities.EntityAssets) do
		for _, sound in pairs(asset.Sounds or {}) do
			sound:stop()
		end
	end
end

local function loadAssetTextures(assetTypeName, subFolder)
	local list = {}
	local index = 0
	while true do
		local textureFile = G.GFXEntitiesFolder .. G.EntitySize .. "/" .. assetTypeName .. "/" .. subFolder .. "/" .. index .. ".png"
		if Utils.fileExists(textureFile) then
			local image, imageData = Utils.loadImage(textureFile, G.EntitySize)
			list[index + 1] = { image = image, imagedata = imageData }
			index = index + 1
		else
			break
		end
	end
	return list
end

-- Loads all walking animation textures for one asset (per direction subfolder)
local function loadWalkAnimTextures(asset)
	asset.WalkingTextures = {}
	local dirIndex = 0
	while true do
		local folder = G.GFXEntitiesFolder .. G.EntitySize .. "/" .. asset.Name .. "/" .. dirIndex
		if Utils.folderExists(folder) then
			asset.WalkingTextures[dirIndex + 1] = loadAssetTextures(asset.Name, tostring(dirIndex))
			dirIndex = dirIndex + 1
		else
			break
		end
	end
end

function Entities.InitEntityAssets()
	Entities.CloseAudio()
	Entities.EntityAssets = {}

	local assetFileIndex = 0
	local assetIndex = 0

	while true do
		local entityDataFile = G.LevelFolder .. G.SelectedLevel .. "/EntityData/" .. assetFileIndex .. ".ini"
		if Utils.fileExists(entityDataFile) then
			local assetTypeName = Config.getString(Config.loadINI(entityDataFile), "ENTITY", "EntityTypeName")

			-- skip asset type if it was already loaded
			local skip = false
			for _, asset in ipairs(Entities.EntityAssets) do
				if asset.Name == assetTypeName then
					skip = true
					break
				end
			end

			local iniFile = G.AssetsEntitiesFolder .. assetTypeName .. "/AssetData.ini"
			if not skip and Utils.fileExists(iniFile) then
				local ini = Config.loadINI(iniFile)
				local asset = {}
				asset.Number = assetIndex
				asset.Name = assetTypeName
				asset.WalkingTextures = {}
				asset.AttackTextures = {}
				asset.KillTextures = {}
				asset.Sounds = {}

				loadWalkAnimTextures(asset)
				asset.AttackTextures = loadAssetTextures(asset.Name, "Attack")
				asset.KillTextures = loadAssetTextures(asset.Name, "Kill")

				local assetType = Config.getString(ini, "GENERAL", "AssetType")
				if assetType == "AmmoBox" then
					asset.Sounds[1] = love.audio.newSource(Config.fixPath(Config.getString(ini, "AUDIO", "AmmoPickup")), "static")
				elseif assetType == "Enemy" or assetType == "Turret" then
					asset.Sounds[1] = love.audio.newSource(Config.fixPath(Config.getString(ini, "AUDIO", "KillSound")), "static")
					asset.Sounds[2] = love.audio.newSource(Config.fixPath(Config.getString(ini, "AUDIO", "AttackSound")), "static")
				end

				Entities.EntityAssets[assetIndex + 1] = asset
				assetIndex = assetIndex + 1
			end

			assetFileIndex = assetFileIndex + 1
		else
			break
		end
	end
end

-- ------------------------------------------------------------------------
-- Entity init
-- ------------------------------------------------------------------------

local function newEntity()
	return {
		PathFindingWayPoints = {},
		ContainedItem = {},
		Type = EntityTypes.CLEAR,
		Pos = { X = 0.0, Y = 0.0 },
		Dir = { X = 0.0, Y = 0.0 },
		TypeName = "",
		Number = 0,
		TypeNumber = 0,
		WaitTimer = 0,
		Hitpoints = 0,
		WalkAnimCounter = 0,
		WalkAnimStep = 0,
		WalkAnimStepWidth = 0,
		AttackMode = 0,
		AttackAnimCounter = 0,
		AttackAnimStep = 0,
		AttackAnimStepWidth = 0,
		HitAnimDuration = 0,
		HitAnimCounter = 0,
		KillAnimStep = 0,
		KillAnimStepWidth = 0,
		KillAnimCounter = 0,
		MovementBehaviour = 0,
		RotationFactor = 0,
		DamagePoints = 0,
		DamageHitrate = 0,
		DamageHitrateCounter = 0,
		MoveSpeed = 0.0,
		MoveV = 0.0,
		Direction = "N",
		AttackFinished = false,
		AttackAnimEnabled = false,
		KillAnimEnabled = false,
		IsPickedUp = false,
		IsDead = false,
		IsHit = false,
		ValidPathFound = false
	}
end

local entityTypeCompare = {
	Clear = EntityTypes.CLEAR,
	Neutral = EntityTypes.NEUTRAL,
	Enemy = EntityTypes.ENEMY,
	Player = EntityTypes.PLAYER,
	AmmoBox = EntityTypes.AMMOBOX,
	Turret = EntityTypes.TURRET
}

function Entities.SwitchDirection(entity, direction)
	for _, dir in ipairs(Directions) do
		if dir[3] == direction then
			entity.Dir.X = dir[1]
			entity.Dir.Y = dir[2]
			entity.Direction = dir[3]
			entity.RotationFactor = dir[4]
			return
		end
	end
	error("SwitchDirection: Entity direction error! Direction must be N, S, E or W")
end

function Entities.MarkEntityPositionOnMap(entity)
	Entities.EntityMap[math.floor(entity.Pos.X) + 1][math.floor(entity.Pos.Y) + 1] = entity.Type
end

function Entities.InitEntities()
	Entities.Entities = {}
	Entities.EntityOrder = {}
	Entities.EntityMap = {}

	for x = 1, Level.LevelMapWidth do
		local column = {}
		for y = 1, Level.LevelMapHeight do
			column[y] = EntityTypes.CLEAR
		end
		Entities.EntityMap[x] = column
	end

	local index = 0
	while true do
		local iniFile = G.LevelFolder .. G.SelectedLevel .. "/EntityData/" .. index .. ".ini"
		if Utils.fileExists(iniFile) then
			local ini = Config.loadINI(iniFile)
			local entity = newEntity()
			entity.Number = index
			entity.TypeName = Config.getString(ini, "ENTITY", "EntityTypeName")
			entity.Type = entityTypeCompare[Config.getString(ini, "ENTITY", "EntityType")] or EntityTypes.CLEAR
			entity.WalkAnimStepWidth = Config.getNumber(ini, "ENTITY", "WalkAnimStepWidth", 0)
			entity.AttackAnimStepWidth = Config.getNumber(ini, "ENTITY", "AttackAnimStepWidth", 0)
			entity.KillAnimStepWidth = Config.getNumber(ini, "ENTITY", "KillAnimStepWidth", 0)
			entity.MoveV = Config.getNumber(ini, "ENTITY", "EntityMoveV", 64.0)
			entity.MoveSpeed = Config.getNumber(ini, "MOVEMENT", "MoveSpeed", 0.0)
			entity.MovementBehaviour = Config.getNumber(ini, "MOVEMENT", "MovementBehaviour", 0)
			entity.AttackMode = Config.getNumber(ini, "MOVEMENT", "AttackMode", 0)
			entity.Pos.X = Config.getNumber(ini, "POSITION", "StartPosX", 1.5)
			entity.Pos.Y = Config.getNumber(ini, "POSITION", "StartPosY", 1.5)
			Entities.SwitchDirection(entity, Config.getString(ini, "DIRECTION", "Direction", "N"))
			entity.Hitpoints = Config.getNumber(ini, "STATUS", "Hitpoints", 0)
			entity.HitAnimDuration = Config.getNumber(ini, "STATUS", "HitAnimDuration", 0)
			entity.DamagePoints = Config.getNumber(ini, "DAMAGE", "DamagePoints", 0)
			entity.DamageHitrate = Config.getNumber(ini, "DAMAGE", "DamageHitrate", 0)
			local containedItem = Config.getString(ini, "CONTAINS", "ContainedItem")
			if containedItem then
				entity.ContainedItem[containedItem] = Config.getNumber(ini, "CONTAINS", "ContainedItemValue", 0)
			end

			-- assign proper asset data (= texture set) to entity
			for _, asset in ipairs(Entities.EntityAssets) do
				if entity.TypeName == asset.Name then
					entity.TypeNumber = asset.Number
					break
				end
			end

			Entities.Entities[index + 1] = entity
			Entities.EntityOrder[index + 1] = { index + 1, 0.0 }
			Entities.MarkEntityPositionOnMap(entity)
			index = index + 1
		else
			break
		end
	end
end

-- ------------------------------------------------------------------------
-- Behaviour
-- ------------------------------------------------------------------------

function Entities.HandleEntityHit(entity)
	if entity.Type ~= EntityTypes.AMMOBOX then
		entity.IsHit = true
		entity.AttackMode = 1
		entity.Type = EntityTypes.ENEMY

		if entity.Hitpoints > 0 then
			entity.Hitpoints = entity.Hitpoints - Game.Weapons.Weapons[Game.Player.SelectedWeapon + 1].Damage
			entity.HitAnimCounter = entity.HitAnimCounter + entity.HitAnimDuration
		end

		if entity.Hitpoints <= 0 and not entity.KillAnimEnabled then
			Entities.PlayAudio(entity.TypeNumber + 1, 1) -- kill sound
			entity.KillAnimEnabled = true
			entity.AttackAnimEnabled = false
			entity.AttackFinished = true
		end
	end
end

local function changeEntityDirection(entity, turn)
	local map = { l = { N = "W", S = "E", E = "N", W = "S" }, r = { N = "E", S = "W", E = "S", W = "N" } }
	local newDirection = map[turn] and map[turn][entity.Direction]
	if newDirection then
		Entities.SwitchDirection(entity, newDirection)
	end
end

local function turnEntityBackwards(entity)
	local opposite = { N = "S", S = "N", E = "W", W = "E" }
	local newDirection = opposite[entity.Direction]
	if newDirection then
		Entities.SwitchDirection(entity, newDirection)
	end
end

local pathCalcInterval = 0.25 -- seconds; C++ calculates A* per frame, we throttle to save CPU

function Entities.CalculateEntityPath(entity)
	if entity.Type == EntityTypes.ENEMY or entity.Type == EntityTypes.NEUTRAL then
		entity.PathFindingWayPoints = {}
		local start = Level.LevelMapWidth * math.floor(entity.Pos.Y) + math.floor(entity.Pos.X)
		local target = Level.LevelMapWidth * math.floor(Game.Player.Pos.Y) + math.floor(Game.Player.Pos.X)
		entity.ValidPathFound = Game.PathFinding.CalculatePath(Level.LevelMapWidth, Level.LevelMapHeight, start, target, false, entity.PathFindingWayPoints)
	end
end

function Entities.MoveEntities(dt)
	for _, entity in ipairs(Entities.Entities) do
		if entity.IsHit then
			entity.HitAnimCounter = entity.HitAnimCounter - 1
			if entity.HitAnimCounter <= 0 then
				entity.IsHit = false
			end
		end

		if not entity.IsDead and entity.KillAnimEnabled then
			entity.KillAnimCounter = entity.KillAnimCounter + 1
			if entity.KillAnimCounter > entity.KillAnimStepWidth then
				local killTextures = Entities.EntityAssets[entity.TypeNumber + 1].KillTextures
				if entity.KillAnimStep < #killTextures - 1 then
					entity.KillAnimStep = entity.KillAnimStep + 1
				else
					entity.IsDead = true
					entity.MovementBehaviour = 0
					Entities.EntityMap[math.floor(entity.Pos.X) + 1][math.floor(entity.Pos.Y) + 1] = EntityTypes.CLEAR
				end
				entity.KillAnimCounter = 0
			end
		end

		if not entity.IsDead and not entity.KillAnimEnabled then
			-- A* pathfinding (throttled: results are only used for the minimap waypoints)
			entity.PathTimer = (entity.PathTimer or 0) + dt
			if entity.PathTimer >= pathCalcInterval then
				entity.PathTimer = 0
				Entities.CalculateEntityPath(entity)
			end

			if entity.MovementBehaviour == 0 then
				-- stationary: refresh ammo position on map once another entity moved over it
				if entity.Type == EntityTypes.AMMOBOX
					and Entities.EntityMap[math.floor(entity.Pos.X) + 1][math.floor(entity.Pos.Y) + 1] == EntityTypes.CLEAR then
					Entities.MarkEntityPositionOnMap(entity)
				end
			elseif entity.MovementBehaviour == 2 then
				-- free roaming mode
				local asset = Entities.EntityAssets[entity.TypeNumber + 1]
				local entityMap = Entities.EntityMap
				local posX, posY = entity.Pos.X, entity.Pos.Y
				local entityCollisionDetectionFactor = entity.MoveSpeed + EntityCollisionDetectionWallDist

				entityMap[math.floor(posX) + 1][math.floor(posY) + 1] = EntityTypes.CLEAR

				-- wait by chance
				if entity.WaitTimer == 0 and love.math.random(1, 666) == 99 and entity.AttackMode == 0 then
					entity.WaitTimer = love.math.random(1, 200)
				end

				if entity.WaitTimer > 0 then
					entity.WaitTimer = entity.WaitTimer - 1
					entity.WalkAnimStep = 0
				else
					if #asset.WalkingTextures[1] == 1 then
						-- not animated
						entity.WalkAnimStep = 0
					else
						-- animated
						entity.WalkAnimCounter = entity.WalkAnimCounter + 1
						if entity.WalkAnimCounter > entity.WalkAnimStepWidth then
							if entity.WalkAnimStep < #asset.WalkingTextures[1] - 1 then
								entity.WalkAnimStep = entity.WalkAnimStep + 1
							else
								entity.WalkAnimStep = 0
							end
							entity.WalkAnimCounter = 0
						end
					end

					-- move forward
					entity.Pos.X = entity.Pos.X + entity.Dir.X * entity.MoveSpeed
					entity.Pos.Y = entity.Pos.Y + entity.Dir.Y * entity.MoveSpeed
				end

				-- switch textures for attack animations
				if entity.AttackAnimEnabled then
					entity.AttackAnimCounter = entity.AttackAnimCounter + 1
					if entity.AttackAnimCounter > entity.AttackAnimStepWidth then
						if entity.AttackAnimStep < #asset.AttackTextures - 1 then
							entity.AttackAnimStep = entity.AttackAnimStep + 1
						else
							entity.AttackAnimStep = 0
							entity.AttackAnimEnabled = false
							entity.AttackFinished = true
						end
						entity.AttackAnimCounter = 0
					end
				end

				local entityPosX = math.floor(entity.Pos.X + entity.Dir.X * entityCollisionDetectionFactor)
				local entityPosY = math.floor(entity.Pos.Y + entity.Dir.Y * entityCollisionDetectionFactor)
				local mapValue = entityMap[entityPosX + 1] and entityMap[entityPosX + 1][entityPosY + 1] or -1

				if Level.isWall(entityPosX, entityPosY) then
					entity.Pos.X = entity.Pos.X - entity.Dir.X * entity.MoveSpeed
					entity.Pos.Y = entity.Pos.Y - entity.Dir.Y * entity.MoveSpeed
					changeEntityDirection(entity, love.math.random(0, 1) == 0 and "l" or "r")
				elseif mapValue == EntityTypes.ENEMY or mapValue == EntityTypes.NEUTRAL or mapValue == EntityTypes.TURRET then
					turnEntityBackwards(entity)
				elseif mapValue == EntityTypes.PLAYER then
					if entity.Type == EntityTypes.ENEMY then
						entity.Pos.X = entity.Pos.X - entity.Dir.X * entity.MoveSpeed
						entity.Pos.Y = entity.Pos.Y - entity.Dir.Y * entity.MoveSpeed

						entity.DamageHitrateCounter = entity.DamageHitrateCounter - 1
						if entity.DamageHitrateCounter <= 0 then
							Entities.PlayAudio(entity.TypeNumber + 1, 2) -- attack sound
							entity.DamageHitrateCounter = entity.DamageHitrate * G.FrameLock
							entity.AttackAnimEnabled = true
							entity.AttackMode = 1
						end
					elseif entity.Type == EntityTypes.NEUTRAL then
						turnEntityBackwards(entity)
					end
				end

				if entity.AttackFinished then
					Game.Player:HurtPlayer(entity.DamagePoints)
					entity.AttackFinished = false
				end

				Entities.MarkEntityPositionOnMap(entity)
			end
		end
	end
end

function Entities.GetEntityDistance()
	local Player = Game.Player
	for index, entity in ipairs(Entities.Entities) do
		Entities.EntityOrder[index] = {
			index,
			Utils.distance(Player.Pos.X, entity.Pos.X, Player.Pos.Y, entity.Pos.Y)
		}
	end
end

function Entities.SortEntities(frontToBack)
	if frontToBack then
		table.sort(Entities.EntityOrder, function(a, b) return a[2] < b[2] end)
	else
		table.sort(Entities.EntityOrder, function(a, b) return a[2] > b[2] end)
	end
end

function Entities.PlayAudio(typeNumber, sound)
	local sound = Entities.EntityAssets[typeNumber].Sounds[sound]
	if sound then
		sound:play()
	end
end

-- ------------------------------------------------------------------------
-- Rendering
-- ------------------------------------------------------------------------

-- GetEntityTextureIndex: relative angle between player and entity, 0..7
function Entities.GetEntityTextureIndex(entityOrderNumber)
	local entity = Entities.Entities[Entities.EntityOrder[entityOrderNumber][1]]
	local Player = Game.Player
	local etX = entity.Pos.X - Player.Pos.X
	local etY = entity.Pos.Y - Player.Pos.Y
	local cosTheta1 = (etX + etY) * math.sqrt(0.5)
	local cosTheta3 = (etY - etX) * math.sqrt(0.5)

	local closestTheta = etX
	local textureIndex = 0

	if closestTheta < cosTheta1 then textureIndex = 1 closestTheta = cosTheta1 end
	if closestTheta < etY then textureIndex = 2 closestTheta = etY end
	if closestTheta < cosTheta3 then textureIndex = 3 closestTheta = cosTheta3 end
	if closestTheta < -etX then textureIndex = 4 closestTheta = -etX end
	if closestTheta < -cosTheta1 then textureIndex = 5 closestTheta = -cosTheta1 end
	if closestTheta < -etY then textureIndex = 6 closestTheta = -etY end
	if closestTheta < -cosTheta3 then textureIndex = 7 end

	local textureIndexTemp = textureIndex + entity.RotationFactor
	if textureIndexTemp < 8 then
		return textureIndexTemp + 1
	else
		return textureIndexTemp - 7
	end
end

local entityShader

function Entities.InitShader()
	entityShader = love.graphics.newShader([[
uniform float uFlash;
uniform float uFog;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
	vec4 texel = Texel(tex, tc);
	if (texel.a < 0.5) { discard; }
	if (uFlash > 0.5) { return vec4(1.0, 1.0, 1.0, 1.0); }
	return vec4(texel.rgb * uFog, 1.0);
}
]])
end

function Entities.RenderEntities()
	if not entityShader then
		Entities.InitShader()
	end

	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local VLT = H + G.VerticalLook
	local inverseMatrix = 1.0 / (G.Plane.X * Player.Dir.Y - Player.Dir.X * G.Plane.Y)
	local zbuffer = Game.Raycaster.ZBuffer
	local fog = G.FogOfWarDistance
	local lighting = Level.LightingFlag

	for index = 1, #Entities.EntityOrder do
		local entity = Entities.Entities[Entities.EntityOrder[index][1]]

		if not entity.IsPickedUp then
			local epX = entity.Pos.X - Player.Pos.X
			local epY = entity.Pos.Y - Player.Pos.Y
			local transY = inverseMatrix * (-G.Plane.Y * epX + G.Plane.X * epY)

			if transY > 0.0 then
				local vScreen = math.floor(entity.MoveV / transY)
				local entitySizeTemp = math.floor(H / transY)
				local temp = math.floor(VLT / 2) + vScreen
				local lineStartY = math.max(-math.floor(entitySizeTemp / 2) + temp, 0)
				local lineEndY = math.min(math.floor(entitySizeTemp / 2) + temp, H)
				local entitySX = math.floor(W / 2 * (1.0 + inverseMatrix * (Player.Dir.Y * epX - Player.Dir.X * epY) / transY))
				local lineEndX = math.min(math.floor(entitySizeTemp / 2) + entitySX, W)
				local temp1 = -math.floor(entitySizeTemp / 2) + entitySX
				local ES = G.EntitySize

				local texture
				local asset = Entities.EntityAssets[entity.TypeNumber + 1]
				if entity.AttackAnimEnabled and #asset.AttackTextures > 0 then
					texture = asset.AttackTextures[entity.AttackAnimStep + 1] and asset.AttackTextures[entity.AttackAnimStep + 1].image
				elseif entity.KillAnimEnabled and #asset.KillTextures > 0 then
					texture = asset.KillTextures[entity.KillAnimStep + 1] and asset.KillTextures[entity.KillAnimStep + 1].image
				else
					local textureIndex = Entities.GetEntityTextureIndex(index)
					local frames = asset.WalkingTextures[textureIndex]
					texture = frames and frames[entity.WalkAnimStep + 1] and frames[entity.WalkAnimStep + 1].image
				end

				if texture and lineEndY - lineStartY > 0 then
					local fogW = 1.0
					if lighting then
						local f = Utils.shadeFactor(transY, fog)
						fogW = (f == -1) and 0.0 or f
					end

					love.graphics.setShader(entityShader)
					entityShader:send("uFlash", entity.IsHit and not entity.KillAnimEnabled and 1.0 or 0.0)
					entityShader:send("uFog", fogW)

					local texW, texH = texture:getDimensions()
					local sliceHeight = lineEndY - lineStartY
					-- vertical texel coordinates over the full sprite
					local vTop = ((lineStartY - vScreen) + (entitySizeTemp - VLT) / 2) * ES / entitySizeTemp
					local vBottom = ((lineEndY - vScreen) + (entitySizeTemp - VLT) / 2) * ES / entitySizeTemp

					-- find contiguous visible column runs (zbuffer test)
					local x = math.max(temp1, 0)
					while x < lineEndX do
						if transY < zbuffer[x + 1] then
							local runStart = x
							while x < lineEndX and transY < zbuffer[x + 1] do
								x = x + 1
							end
							local runWidth = x - runStart
							local u0 = (runStart - temp1) * ES / entitySizeTemp
							local u1 = (x - temp1) * ES / entitySizeTemp
							local quad = getQuad(runStart + 1)
							quad:setViewport(u0, vTop, u1 - u0, vBottom - vTop, texW, texH)
							texture:setWrap("clampzero")
							love.graphics.setColor(1, 1, 1, 1)
							-- one sprite texel covers entitySizeTemp/EntitySize screen pixels
							local texelScale = entitySizeTemp / ES
							love.graphics.draw(texture, quad, runStart, lineStartY, 0, texelScale, texelScale)
						else
							x = x + 1
						end
					end
					love.graphics.setShader()
				end
			end
		end
	end
end

Game.Entities = Entities
return Entities
