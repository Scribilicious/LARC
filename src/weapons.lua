--
-- weapons.lua - weapon handling
-- Ported from Game_WeaponHandling.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")

local Weapons = {}

Weapons.WEAPONSTATE = { READY = 0, CHANGEUP = 1, CHANGEDOWN = 2, RELOADINITIATED = 3 }
Weapons.FIRINGSTATE = { NONE = 0, SINGLESHOT = 1, RAPIDFIRE = 2 }

Weapons.Weapons = {}
Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.READY
Weapons.CurrentFiringState = Weapons.FIRINGSTATE.NONE

Weapons.WeaponHeightFadeInOut = 0
Weapons.WeaponFadeInOutY = 0

Weapons.WeaponPace = 0.0
Weapons.WeaponPaceFlag = false
Weapons.WeaponMuzzleFlashFlag = false

local EntityTypes

-- ------------------------------------------------------------------------
-- Init
-- ------------------------------------------------------------------------

function Weapons.InitConfig()
	Weapons.Weapons = {}

	local index = 0
	while true do
		local iniFile = G.AssetsWeaponsFolder .. "Weapon_" .. index .. "_Data.ini"
		if Utils.fileExists(iniFile) then
			local ini = Config.loadINI(iniFile)
			local weapon = {}
			weapon.Number = index
			weapon.Name = Config.getString(ini, "DATA", "Name")
			weapon.Weight = Config.getNumber(ini, "DATA", "Weight", 1.0)
			weapon.Capacity = Config.getNumber(ini, "DATA", "Capacity", 30)
			weapon.PaceFactor = Config.getNumber(ini, "DATA", "PaceFactor", 0.05)
			weapon.Damage = Config.getNumber(ini, "DATA", "Damage", 10)
			weapon.CarriedAmmo = Config.getNumber(ini, "DATA", "CarriedAmmo", 0)
			weapon.Cadence = Config.getNumber(ini, "DATA", "Cadence", 600)
			weapon.PosX = Config.getNumber(ini, "POSITION", "PosX", 0)
			weapon.PosY = Config.getNumber(ini, "POSITION", "PosY", 0)
			weapon.FadeInOutSpeed = Config.getNumber(ini, "POSITION", "FadeInOutSpeed", 10)
			weapon.MuzzleFlashDuration = Config.getNumber(ini, "MUZZLEFLASH", "MuzzleFlashDuration", 5)
			weapon.MuzzleFlashPosX = Config.getNumber(ini, "MUZZLEFLASH", "MuzzleFlashPosX", 0)
			weapon.MuzzleFlashPosY = Config.getNumber(ini, "MUZZLEFLASH", "MuzzleFlashPosY", 0)
			weapon.ReloadCounter = 0
			weapon.MuzzleFlashCounter = 0
			weapon.CadenceCounter = 0
			-- pre-load weapon
			weapon.LoadedRounds = weapon.Capacity
			weapon.HUDAmmoInfo = weapon.Capacity .. "/" .. weapon.Capacity
			weapon.HUDCarriedAmmoInfo = "Carried:" .. weapon.CarriedAmmo
			Weapons.Weapons[index + 1] = weapon
			index = index + 1
		else
			break
		end
	end
end

function Weapons.current()
	return Weapons.Weapons[Game.Player.SelectedWeapon + 1]
end

function Weapons.InitTextures()
	for _, weapon in ipairs(Weapons.Weapons) do
		local textureConf = G.AssetsWeaponsFolder .. "Weapon_" .. weapon.Number .. "_TexturesData.conf"
		for line in love.filesystem.lines(textureConf) do
			local name = line:match("^%s*(.-)%s*$")
			if name ~= "" then
				local image = Utils.loadImage(name)
				weapon.Texture = image
				weapon.Width = image:getWidth()
				weapon.Height = image:getHeight()
			end
		end

		local muzzleConf = G.AssetsWeaponsFolder .. "Weapon_" .. weapon.Number .. "_MuzzleFlashTexturesData.conf"
		for line in love.filesystem.lines(muzzleConf) do
			local name = line:match("^%s*(.-)%s*$")
			if name ~= "" then
				local image = Utils.loadImage(name)
				weapon.MuzzleFlashTexture = image
				weapon.MuzzleFlashWidth = image:getWidth()
				weapon.MuzzleFlashHeight = image:getHeight()
			end
		end
	end
end

function Weapons.InitAudio()
	local index = 0
	for _, weapon in ipairs(Weapons.Weapons) do
		local iniFile = G.AssetsWeaponsFolder .. "Weapon_" .. weapon.Number .. "_Data.ini"
		local ini = Config.loadINI(iniFile)
		if ini then
			weapon.Sounds = {}
			local shot = Config.getString(ini, "AUDIO", "SingleShotAudio")
			weapon.Sounds[1] = shot and love.audio.newSource(Config.fixPath(shot), "static") or nil
			local dryfire = Config.getString(ini, "AUDIO", "DryFireAudio")
			weapon.Sounds[2] = dryfire and love.audio.newSource(Config.fixPath(dryfire), "static") or nil
			local reload = Config.getString(ini, "AUDIO", "ReloadAudio")
			weapon.Sounds[3] = reload and love.audio.newSource(Config.fixPath(reload), "static") or nil
			if weapon.Sounds[3] then
				-- duration in seconds -> ticks (FrameLock)
				weapon.ReloadDuration = math.floor(weapon.Sounds[3]:getDuration() * G.FrameLock)
			else
				weapon.ReloadDuration = 60
			end
		end
	end
end

-- ------------------------------------------------------------------------
-- Hitscan (CheckForHit)
-- ------------------------------------------------------------------------

local EPS = 1e-6

local function checkForHit()
	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local Entities = Game.Entities
	local zbuffer = Game.Raycaster.ZBuffer
	local widthMid = math.floor(W / 2)
	local VLT = H + G.VerticalLook

	local camera = (widthMid * 2) / W - 1
	local rayX = Player.Dir.X + G.Plane.X * camera
	local rayY = Player.Dir.Y + G.Plane.Y * camera

	local mapX = math.floor(Player.Pos.X)
	local mapY = math.floor(Player.Pos.Y)

	if math.abs(rayX) < EPS then rayX = EPS end
	if math.abs(rayY) < EPS then rayY = EPS end
	local deltaDX = math.abs(1.0 / rayX)
	local deltaDY = math.abs(1.0 / rayY)

	local stepX, sideX, stepY, sideY
	if rayX < 0.0 then
		stepX = -1.0
		sideX = (Player.Pos.X - mapX) * deltaDX
	else
		stepX = 1.0
		sideX = (mapX + 1.0 - Player.Pos.X) * deltaDX
	end
	if rayY < 0.0 then
		stepY = -1.0
		sideY = (Player.Pos.Y - mapY) * deltaDY
	else
		stepY = 1.0
		sideY = (mapY + 1.0 - Player.Pos.Y) * deltaDY
	end

	local endloop = false
	local inverseMatrix = 1.0 / (G.Plane.X * Player.Dir.Y - Player.Dir.X * G.Plane.Y)
	local wallLayer = Level.layers[Level.WALL]
	local numberOfEntities = #Entities.Entities

	while not endloop do
		if sideX < sideY then
			sideX = sideX + deltaDX
			mapX = mapX + stepX
		else
			sideY = sideY + deltaDY
			mapY = mapY + stepY
		end

		-- if wall was hit and no entity -> end loop
		local wallValue = wallLayer[mapX + 1] and wallLayer[mapX + 1][mapY + 1] or 0
		if wallValue > 0 and wallValue ~= Level.DOORWALL then
			endloop = true
		end

		if not endloop then
			for index = 1, numberOfEntities do
				local entity = Entities.Entities[Entities.EntityOrder[index][1]]
				if not entity.IsDead and not endloop then
					local textureIndex = Entities.GetEntityTextureIndex(index)
					local epX = entity.Pos.X - Player.Pos.X
					local epY = entity.Pos.Y - Player.Pos.Y
					local transY = inverseMatrix * (-G.Plane.Y * epX + G.Plane.X * epY)

					if transY > 0 and transY < zbuffer[widthMid + 1] then
						local vScreen = math.floor(entity.MoveV / transY)
						local entitySizeTemp = math.floor(H / transY)
						local entitySX = math.floor(W / 2 * (1.0 + inverseMatrix * (Player.Dir.Y * epX - Player.Dir.X * epY) / transY))
						local temp1 = -math.floor(entitySizeTemp / 2) + entitySX
						local lineEndX = math.min(math.floor(entitySizeTemp / 2) + entitySX, W)
						local ES = G.EntitySize
						-- only the center column of the screen (crosshair) is checked,
						-- and only if it lies within the sprite's screen column span
						if widthMid >= temp1 and widthMid <= lineEndX then
							local textureX = math.floor((widthMid - temp1) * ES / entitySizeTemp)
							local textureY = math.floor(((((math.floor(H / 2) - vScreen) * 256 - (H + G.VerticalLook) * 128 + entitySizeTemp * 128) * ES) / entitySizeTemp) / 256)
							local frames = Entities.EntityAssets[entity.TypeNumber + 1].WalkingTextures[textureIndex]
							local frame = frames and frames[entity.WalkAnimStep + 1]
							if frame and frame.imagedata then
								-- LÖVE ImageData is 0-based (like the C++
								-- Pixels array); the Lua % wrap keeps the
								-- negative / oversized cases in range
								local r, gg, b, a = frame.imagedata:getPixel(
									textureX % frame.imagedata:getWidth(),
									textureY % frame.imagedata:getHeight())
								if a > 0 then
									Entities.HandleEntityHit(entity)
									endloop = true
								end
							end
						end
					end
				end
			end
		end
	end
end

-- ------------------------------------------------------------------------
-- Firing / reload / weapon change
-- ------------------------------------------------------------------------

function Weapons.HandleAmmoBoxPickup()
	local Entities = Game.Entities
	local Player = Game.Player
	local EntityTypes = Entities.EntityTypes
	local px, py = math.floor(Player.Pos.X), math.floor(Player.Pos.Y)

	if Entities.EntityMap[px + 1][py + 1] == EntityTypes.AMMOBOX then
		for _, entity in ipairs(Entities.Entities) do
			if entity.Type == EntityTypes.AMMOBOX
				and px == math.floor(entity.Pos.X)
				and py == math.floor(entity.Pos.Y) then
				Entities.PlayAudio(entity.TypeNumber + 1, 1)
				entity.IsDead = true
				entity.IsPickedUp = true

				for _, weapon in ipairs(Weapons.Weapons) do
					local value = entity.ContainedItem[weapon.Name]
					if value then
						weapon.CarriedAmmo = weapon.CarriedAmmo + value
						weapon.HUDCarriedAmmoInfo = "Carried:" .. weapon.CarriedAmmo
						break
					end
				end

				break
			end
		end
	end
end

function Weapons.InitiateRapidFire()
	if Weapons.CurrentFiringState == Weapons.FIRINGSTATE.NONE
		and Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.READY then
		Weapons.CurrentFiringState = Weapons.FIRINGSTATE.RAPIDFIRE
	end
end

function Weapons.ReleaseRapidFire()
	Weapons.CurrentFiringState = Weapons.FIRINGSTATE.NONE
end

function Weapons.InitiateSingleShot()
	if Weapons.CurrentFiringState == Weapons.FIRINGSTATE.NONE
		and Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.READY then
		Weapons.CurrentFiringState = Weapons.FIRINGSTATE.SINGLESHOT
	end
end

function Weapons.InitiateReload()
	local weapon = Weapons.current()
	if Weapons.CurrentFiringState == Weapons.FIRINGSTATE.NONE
		and Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.READY then
		if weapon.ReloadCounter == 0 and weapon.CarriedAmmo > 0 then
			weapon.ReloadCounter = weapon.ReloadDuration
			Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.RELOADINITIATED
			if weapon.Sounds and weapon.Sounds[3] then weapon.Sounds[3]:play() end
		end
	end
end

function Weapons.InitiateWeaponChangeUp()
	if not Weapons.WeaponMuzzleFlashFlag and Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.READY then
		Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.CHANGEUP
	end
end

function Weapons.InitiateWeaponChangeDown()
	if not Weapons.WeaponMuzzleFlashFlag and Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.READY then
		Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.CHANGEDOWN
	end
end

function Weapons.FireWeapon()
	local weapon = Weapons.current()
	local Player = Game.Player

	if Weapons.CurrentFiringState == Weapons.FIRINGSTATE.SINGLESHOT
		or Weapons.CurrentFiringState == Weapons.FIRINGSTATE.RAPIDFIRE then
		if weapon.LoadedRounds > 0 and weapon.CadenceCounter <= 0 then
			weapon.CadenceCounter = math.floor(3600 / weapon.Cadence)
			if weapon.Sounds and weapon.Sounds[1] then weapon.Sounds[1]:play() end

			Weapons.WeaponMuzzleFlashFlag = true
			weapon.MuzzleFlashCounter = weapon.MuzzleFlashDuration
			weapon.LoadedRounds = weapon.LoadedRounds - 1

			checkForHit()
		elseif Weapons.CurrentFiringState == Weapons.FIRINGSTATE.SINGLESHOT then
			if weapon.Sounds and weapon.Sounds[2] then weapon.Sounds[2]:play() end
		end
	end

	-- build ammo info HUD string
	if weapon.LoadedRounds < 10 then
		weapon.HUDAmmoInfo = "0" .. weapon.LoadedRounds .. "/" .. weapon.Capacity
	else
		weapon.HUDAmmoInfo = weapon.LoadedRounds .. "/" .. weapon.Capacity
	end

	if Weapons.CurrentFiringState == Weapons.FIRINGSTATE.SINGLESHOT then
		Weapons.CurrentFiringState = Weapons.FIRINGSTATE.NONE
	end
end

function Weapons.CheckReloadStatus()
	local weapon = Weapons.current()

	if Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.RELOADINITIATED then
		if weapon.ReloadCounter > 0 then
			weapon.ReloadCounter = weapon.ReloadCounter - 1
		else
			local tempAmmo = weapon.Capacity - weapon.LoadedRounds
			if weapon.CarriedAmmo >= tempAmmo then
				weapon.LoadedRounds = weapon.LoadedRounds + tempAmmo
				weapon.CarriedAmmo = weapon.CarriedAmmo - tempAmmo
			else
				weapon.LoadedRounds = weapon.LoadedRounds + weapon.CarriedAmmo
				weapon.CarriedAmmo = 0
			end

			weapon.HUDAmmoInfo = weapon.LoadedRounds .. "/" .. weapon.Capacity
			weapon.HUDCarriedAmmoInfo = "Carried:" .. weapon.CarriedAmmo

			Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.READY
		end
	end
end

function Weapons.ChangeWeapon()
	local weapon = Weapons.current()

	if (Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.CHANGEUP
			or Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.CHANGEDOWN)
		and Weapons.WeaponHeightFadeInOut == 0 then
		Weapons.WeaponHeightFadeInOut = weapon.Height
	elseif Weapons.WeaponHeightFadeInOut > 0 then
		Weapons.WeaponHeightFadeInOut = Weapons.WeaponHeightFadeInOut - weapon.FadeInOutSpeed
		Weapons.WeaponFadeInOutY = Weapons.WeaponFadeInOutY + weapon.FadeInOutSpeed

		if Weapons.WeaponHeightFadeInOut <= 0 then
			if Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.CHANGEUP then
				if Game.Player.SelectedWeapon < #Weapons.Weapons - 1 then
					Game.Player.SelectedWeapon = Game.Player.SelectedWeapon + 1
				else
					Game.Player.SelectedWeapon = 0
				end
			elseif Weapons.CurrentWeaponState == Weapons.WEAPONSTATE.CHANGEDOWN then
				if Game.Player.SelectedWeapon > 0 then
					Game.Player.SelectedWeapon = Game.Player.SelectedWeapon - 1
				else
					Game.Player.SelectedWeapon = #Weapons.Weapons - 1
				end
			end

			local newWeapon = Weapons.current()
			Weapons.WeaponFadeInOutY = newWeapon.Height
		end
	elseif Weapons.WeaponFadeInOutY > 0 then
		Weapons.WeaponFadeInOutY = Weapons.WeaponFadeInOutY - weapon.FadeInOutSpeed

		if Weapons.WeaponFadeInOutY <= 0 then
			Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.READY
			Weapons.WeaponHeightFadeInOut = 0
			Weapons.WeaponFadeInOutY = 0
		end
	end
end

function Weapons.CountdownMuzzleFlashCounter()
	local weapon = Weapons.current()
	weapon.MuzzleFlashCounter = weapon.MuzzleFlashCounter - 1
	if weapon.MuzzleFlashCounter <= 0 then
		Weapons.WeaponMuzzleFlashFlag = false
		weapon.MuzzleFlashCounter = 0
	end
end

function Weapons.CountdownCadenceCounter()
	local weapon = Weapons.current()
	if weapon.CadenceCounter > 0 then
		weapon.CadenceCounter = weapon.CadenceCounter - 1
	end
end

-- ------------------------------------------------------------------------
-- Rendering
-- ------------------------------------------------------------------------

function Weapons.DrawWeapon()
	local weapon = Weapons.current()
	if not weapon.Texture then return end

	local paceWeightProduct = Weapons.WeaponPace * weapon.Weight

	-- LARC widescreen addition: with the cropped 16:9 render viewport the
	-- configured viewmodel position is shifted up so it stays anchored to
	-- the canvas bottom like in the original 4:3 layout
	local bottomShift = G.Canvas.Height - G.Canvas.BaseHeight

	-- sway pattern is some kind of simple Lissajous figure
	local swayX = weapon.PosX + math.floor(math.cos(paceWeightProduct) * 6.0)
	local swayY = weapon.PosY + math.floor(math.sin(paceWeightProduct * 1.5) * 6.0) + bottomShift

	-- draw muzzle flash if weapon is fired
	if Weapons.WeaponMuzzleFlashFlag and weapon.MuzzleFlashTexture then
		love.graphics.draw(weapon.MuzzleFlashTexture, swayX + weapon.MuzzleFlashPosX, swayY - weapon.MuzzleFlashPosY)
	end

	love.graphics.draw(weapon.Texture, swayX, swayY + Weapons.WeaponFadeInOutY)
end

Game.Weapons = Weapons
return Weapons
