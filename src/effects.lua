--
-- effects.lua - screen effects (bloodstain)
-- Ported from Game_Effects.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local Effects = {}

Effects.BloodstainDuration = 15
Effects.BloodstainCounter = 0
Effects.BloodstainFlag = false
Effects.BloodstainTexture = nil

function Effects.InitEffects()
	local ini = Config.loadINI(G.GameConfigFolder .. "EffectsConfig.ini")
	if ini then
		Effects.BloodstainDuration = Config.getNumber(ini, "EFFECTS", "BloodstainDuration", 15)
		Effects.BloodstainTexture = Utils.loadImage(Config.getString(ini, "TEXTURES", "Bloodstains"))
	end
end

function Effects.StartBloodstainDrawing()
	Effects.BloodstainFlag = true
	Effects.BloodstainCounter = Effects.BloodstainDuration
end

function Effects.CountdownBloodstainCounter()
	if Effects.BloodstainCounter > 0 then
		Effects.BloodstainCounter = Effects.BloodstainCounter - 1
		if Effects.BloodstainCounter == 0 then
			Effects.BloodstainFlag = false
		end
	end
end

function Effects.DrawBloodstain()
	if Effects.BloodstainFlag and Effects.BloodstainTexture then
		local alpha = Utils.clamp(0.5 - (0.5 / Effects.BloodstainCounter), 0.0, 0.5)
		love.graphics.setColor(1, 1, 1, alpha)
		love.graphics.draw(Effects.BloodstainTexture, 0, 0)
		love.graphics.setColor(1, 1, 1, 1)
	end
end

Game.Effects = Effects
return Effects
