--
-- player.lua - player class
-- Ported from Game_PlayerClass.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local Player = {}
Player.__index = Player

Player.SOUNDS = { FOOTSTEPS = 1, HURT = 2, DEATHSCREAM = 3 }

function Player.new()
	local self = setmetatable({}, Player)
	self.Sounds = {}
	self.FuturePos = { X = 0, Y = 0 }
	self.Pos = { X = 0.0, Y = 0.0 }
	self.Dir = { X = -1.0, Y = 0.0 }
	self.StepWidth = { X = 0.0, Y = 0.0 }
	self.SelectedWeapon = 0
	self.Hitpoints = 100
	self.MoveSpeed = 0.0
	self.CollisionDetectionFactor = 0.0
	self.IsDead = false
	self.FootstepsPlaying = false
	return self
end

function Player:InitConfig()
	local iniFile = G.LevelFolder .. G.SelectedLevel .. "/PlayerData/Config.ini"
	local ini = Config.loadINI(iniFile)
	if ini then
		self.MoveSpeed = Config.getNumber(ini, "GENERAL", "MoveSpeed", 1.0)
		self.Hitpoints = Config.getNumber(ini, "GENERAL", "Hitpoints", 100)
		self.CollisionDetectionFactor = self.MoveSpeed + Config.getNumber(ini, "GENERAL", "CollisionDetectionWallDist", 0.25)
		self.Pos.X = Config.getNumber(ini, "POSITION", "PosX", 1.5)
		self.Pos.Y = Config.getNumber(ini, "POSITION", "PosY", 1.5)
		self.Dir.X = Config.getNumber(ini, "POSITION", "DirX", -1.0)
		self.Dir.Y = Config.getNumber(ini, "POSITION", "DirY", 0.0)
		self.SelectedWeapon = Config.getNumber(ini, "WEAPON", "SelectedWeapon", 0)
	end
end

function Player:InitAudio()
	local iniFile = G.LevelFolder .. G.SelectedLevel .. "/PlayerData/Config.ini"
	local ini = Config.loadINI(iniFile)
	if ini then
		local footsteps = Config.getString(ini, "AUDIO", "FootStepsAudio")
		if footsteps then
			self.Sounds[Player.SOUNDS.FOOTSTEPS] = love.audio.newSource(Config.fixPath(footsteps), "static")
			self.Sounds[Player.SOUNDS.FOOTSTEPS]:setLooping(true)
		end
		local hurt = Config.getString(ini, "AUDIO", "HurtAudio")
		if hurt then
			self.Sounds[Player.SOUNDS.HURT] = love.audio.newSource(Config.fixPath(hurt), "static")
		end
		local scream = Config.getString(ini, "AUDIO", "DeathScreamAudio")
		if scream then
			self.Sounds[Player.SOUNDS.DEATHSCREAM] = love.audio.newSource(Config.fixPath(scream), "static")
		end
	end
end

function Player:HurtPlayer(damageDealt)
	self.Hitpoints = self.Hitpoints - damageDealt

	if self.Hitpoints > 0 then
		self:PlayAudio(Player.SOUNDS.HURT)
		Game.Effects.StartBloodstainDrawing()
	end

	if self.Hitpoints <= 0 then
		self.Hitpoints = 0
		self.IsDead = true
		self:PlayAudio(Player.SOUNDS.DEATHSCREAM)
	end
end

function Player:PlayAudio(sound)
	Utils.playSound(self.Sounds[sound])
end

return Player
