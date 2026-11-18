--
-- hud.lua - health bar, weapon display, minimap, fps counter
-- Ported from Game_HealthBarClass.hpp, Game_WeaponDisplayClass.hpp,
-- Game_MinimapClass.hpp and the lwmf fps counter
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Level = require("src/level")
local Game = require("src/game")
local EntitiesModule = require("src/entities")

local HUD = {}

local EntityTypes = EntitiesModule.EntityTypes

-- ------------------------------------------------------------------------
-- Health bar
-- ------------------------------------------------------------------------

HUD.HealthBar = {}

function HUD.HealthBar.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "HUDHealthBarConfig.ini")
	if ini then
		local hb = HUD.HealthBar
		hb.PosX = Config.getNumber(ini, "GENERAL", "PosX", 0)
		hb.PosY = Config.getNumber(ini, "GENERAL", "PosY", 0)
		hb.Width = Config.getNumber(ini, "GENERAL", "HealthBarWidth", 15)
		local length = Config.getNumber(ini, "GENERAL", "HealthBarLength", 100)
		hb.Factor = math.floor(length / 100)
		hb.Length = length
		hb.Green = { Config.getRGBA(ini, "GREEN") }
		hb.Red = { Config.getRGBA(ini, "RED") }
		hb.Orange = { Config.getRGBA(ini, "ORANGE") }
		hb.Black = { Config.getRGBA(ini, "BLACK") }
	end
end

function HUD.HealthBar.Display()
	local hb = HUD.HealthBar
	local Player = Game.Player
	local hp = math.max(Player.Hitpoints, 0)

	love.graphics.setColor(hb.Black[1], hb.Black[2], hb.Black[3])
	love.graphics.setLineWidth(1)
	love.graphics.rectangle("line", hb.PosX - 4, hb.PosY - 4, hb.Length + 8, hb.Width + 8)

	love.graphics.setColor(hb.Orange[1], hb.Orange[2], hb.Orange[3])
	love.graphics.rectangle("fill", hb.PosX - 3, hb.PosY - 3, hb.Length + 6, hb.Width + 6)

	love.graphics.setColor(hb.Black[1], hb.Black[2], hb.Black[3])
	love.graphics.rectangle("line", hb.PosX - 1, hb.PosY - 1, hb.Length + 2, hb.Width + 2)

	love.graphics.setColor(hb.Red[1], hb.Red[2], hb.Red[3])
	love.graphics.rectangle("fill", hb.PosX, hb.PosY, hb.Length, hb.Width)

	love.graphics.setColor(hb.Green[1], hb.Green[2], hb.Green[3])
	love.graphics.rectangle("fill", hb.PosX, hb.PosY, hp * hb.Factor, hb.Width)

	love.graphics.setColor(1, 1, 1, 1)
end

-- ------------------------------------------------------------------------
-- Weapon display (crosshair, weapon HUD image, ammo text)
-- ------------------------------------------------------------------------

HUD.WeaponDisplay = {}

function HUD.WeaponDisplay.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "HUDWeaponDisplayConfig.ini")
	if ini then
		local wd = HUD.WeaponDisplay
		local crosshairFile = Config.getString(ini, "HUD", "CrosshairFileName")
		if crosshairFile then
			wd.Crosshair = Utils.loadImage(crosshairFile)
		end
		local weaponHudFile = Config.getString(ini, "HUD", "WeaponHUDFileName")
		if weaponHudFile then
			wd.WeaponHUD = Utils.loadImage(weaponHudFile)
		end
		wd.PosX = Config.getNumber(ini, "HUD", "WeaponHUDPosX", 0)
		wd.PosY = Config.getNumber(ini, "HUD", "WeaponHUDPosY", 0)
		wd.AmmoFont = Game.Transitions.loadFont(ini, "HUDAMMOFONT")
		wd.CarriedAmmoFont = Game.Transitions.loadFont(ini, "HUDCARRIEDAMMOFONT")
		wd.WeaponFont = Game.Transitions.loadFont(ini, "HUDWEAPONFONT")
	end
end

function HUD.WeaponDisplay.Display()
	local wd = HUD.WeaponDisplay
	local W, H = G.Canvas.Width, G.Canvas.Height

	if wd.Crosshair then
		love.graphics.draw(wd.Crosshair, math.floor(W / 2 - wd.Crosshair:getWidth() / 2), math.floor(H / 2 - wd.Crosshair:getHeight() / 2))
	end
	if wd.WeaponHUD then
		love.graphics.draw(wd.WeaponHUD, wd.PosX, wd.PosY)
	end

	local weapon = Game.Weapons.current()
	local f
	f = wd.WeaponFont
	if f then
		love.graphics.setFont(f.font)
		love.graphics.setColor(f.r, f.g, f.b)
		love.graphics.print(weapon.Name, wd.PosX + (f.offsetX or 0), wd.PosY + (f.offsetY or 0))
	end
	f = wd.CarriedAmmoFont
	if f then
		love.graphics.setFont(f.font)
		love.graphics.setColor(f.r, f.g, f.b)
		love.graphics.print(weapon.HUDCarriedAmmoInfo, wd.PosX + (f.offsetX or 0), wd.PosY + (f.offsetY or 0))
	end
	f = wd.AmmoFont
	if f then
		love.graphics.setFont(f.font)
		love.graphics.setColor(f.r, f.g, f.b)
		love.graphics.print(weapon.HUDAmmoInfo, wd.PosX + (f.offsetX or 0), wd.PosY + (f.offsetY or 0))
	end
	love.graphics.setColor(1, 1, 1, 1)
end

-- ------------------------------------------------------------------------
-- Minimap
-- ------------------------------------------------------------------------

HUD.Minimap = {}
HUD.Minimap.Enabled = true

function HUD.Minimap.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "HUDMinimapConfig.ini")
	if ini then
		local mm = HUD.Minimap
		mm.PosX = Config.getNumber(ini, "GENERAL", "PosX", 20)
		mm.PosY = Config.getNumber(ini, "GENERAL", "PosY", 20)
		mm.ShowWaypoints = Config.getBoolean(ini, "GENERAL", "ShowWaypoints", false)
		mm.PlayerColor = { Config.getRGBA(ini, "PLAYER") }
		mm.EnemyColor = { Config.getRGBA(ini, "ENEMY") }
		mm.NeutralColor = { Config.getRGBA(ini, "NEUTRAL") }
		mm.AmmoBoxColor = { Config.getRGBA(ini, "AMMO") }
		mm.WallColor = { Config.getRGBA(ini, "WALLS") }
		mm.DoorColor = { Config.getRGBA(ini, "DOORS") }
		mm.WayPointColor = { Config.getRGBA(ini, "WAYPOINT") }
	end
end

function HUD.Minimap.PreRender()
	local mm = HUD.Minimap
	mm.TileSize = 6

	-- the bigger the level, the smaller the tiles of the minimap
	local dims = Level.LevelMapWidth + Level.LevelMapHeight
	if dims <= 50 then
		mm.TileSize = 10
	elseif dims <= 100 then
		mm.TileSize = 8
	end

	if mm.TileSize > 6 and G.Canvas.Width <= 640 then
		mm.TileSize = math.floor(mm.TileSize / 2)
	end

	mm.WaypointOffset = math.floor(mm.TileSize / 2)

	local ts = mm.TileSize
	local canvas = love.graphics.newCanvas(Level.LevelMapHeight * ts, Level.LevelMapWidth * ts)
	love.graphics.push("all")
	love.graphics.setCanvas(canvas)
	love.graphics.clear(0, 0, 0, 0) -- transparent background: realtime entries shine through

	-- outer loop = "x" on screen, inner = "y" (same order as the C++ renderer)
	for mapPosY = 0, Level.LevelMapHeight - 1 do
		for mapPosX = 0, Level.LevelMapWidth - 1 do
			local sx = mapPosY * ts
			local sy = mapPosX * ts
			local wallValue = Level.getLayer(Level.WALL, mapPosX, mapPosY)
			if wallValue and wallValue ~= 0 then
				love.graphics.setColor(mm.WallColor[1], mm.WallColor[2], mm.WallColor[3])
				love.graphics.rectangle("fill", sx, sy, ts, ts)
			end
			local doorValue = Level.getLayer(Level.DOOR, mapPosX, mapPosY)
			if doorValue and doorValue ~= 0 then
				love.graphics.setColor(mm.DoorColor[1], mm.DoorColor[2], mm.DoorColor[3])
				love.graphics.rectangle("fill", sx, sy, ts, ts)
			end
		end
	end
	love.graphics.setCanvas()
	love.graphics.pop()
	mm.Canvas = canvas

	mm.StartPosY = G.Canvas.Height - Level.LevelMapWidth * ts - mm.PosY
end

-- realtime data (entities, waypoints) drawn directly to the main canvas
function HUD.Minimap.DisplayRealtimeMap()
	local mm = HUD.Minimap
	local Entities = Game.Entities
	local ts = mm.TileSize
	local EntityMap = Entities.EntityMap

	for mapPosY = 0, Level.LevelMapHeight - 1 do
		for mapPosX = 0, Level.LevelMapWidth - 1 do
			local x = mm.PosX + mapPosY * ts
			local y = mm.StartPosY + mapPosX * ts
			local cell = EntityMap[mapPosX + 1][mapPosY + 1]

			local color
			if cell == EntityTypes.PLAYER then
				color = mm.PlayerColor
			elseif cell == EntityTypes.ENEMY or cell == EntityTypes.TURRET then
				color = mm.EnemyColor
			elseif cell == EntityTypes.NEUTRAL then
				color = mm.NeutralColor
			elseif cell == EntityTypes.AMMOBOX then
				color = mm.AmmoBoxColor
			end

			if color then
				love.graphics.setColor(color[1], color[2], color[3])
				love.graphics.rectangle("fill", x, y, ts, ts)
			end

			if mm.ShowWaypoints then
				for _, entity in ipairs(Entities.Entities) do
					if not entity.IsDead and (entity.Type == EntityTypes.NEUTRAL or entity.Type == EntityTypes.ENEMY) then
						for _, wayPoint in ipairs(entity.PathFindingWayPoints) do
							if wayPoint.X == mapPosX and wayPoint.Y == mapPosY then
								love.graphics.setColor(mm.WayPointColor[1], mm.WayPointColor[2], mm.WayPointColor[3])
								love.graphics.points(x + mm.WaypointOffset + 0.5, y + mm.WaypointOffset + 0.5)
								break
							end
						end
					end
				end
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

function HUD.Minimap.DisplayPreRenderedMap()
	local mm = HUD.Minimap
	if mm.Canvas then
		love.graphics.draw(mm.Canvas, mm.PosX, mm.StartPosY)
	end
end

-- ------------------------------------------------------------------------
-- FPS counter
-- ------------------------------------------------------------------------

function HUD.DisplayFPSCounter()
	love.graphics.setColor(1, 1, 1)
	local font = love.graphics.getFont()
	love.graphics.print(tostring(love.timer.getFPS()), G.Canvas.Width - 70, 7)
	love.graphics.setFont(font)
end

Game.HUD = HUD
return HUD
