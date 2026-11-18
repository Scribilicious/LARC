--
-- transitions.lua - level transitions, fizzle fade, death sequence
-- Ported from Game_Transitions.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local Transitions = {}

Transitions.GeneralFont = nil
Transitions.GameOverFont = nil
Transitions.GameOverFont1 = nil

-- Fizzle fade state ("famous Wolfenstein 3D effect" via a Feistel network)
local fizzleCanvas = nil
local fizzleFrame = 0
local fizzleLastFrame = 0
local fizzleHalfBits = 0
local fizzleHalfMask = 0
local fizzleSpeed = 50
local fizzleColor = { 1, 0, 0, 1 }

-- XOR that works on all Lua versions LÖVE ships with
-- (LuaJIT "bit", Lua 5.3+ via loadstring'd "~", or a manual fallback)
local bxor
if type(bit) == "table" and bit.bxor then
	bxor = bit.bxor
else
	local f = (loadstring or load)("return function(a, b) return a ~ b end")
	if f then
		bxor = f()
	else
		bxor = function(a, b)
			local result, place = 0, 1
			while a > 0 or b > 0 do
				if a % 2 ~= b % 2 then
					result = result + place
				end
				a = math.floor(a / 2)
				b = math.floor(b / 2)
				place = place * 2
			end
			return result
		end
	end
end

function Transitions.Init()
	local generalIni = Config.loadINI(G.GameConfigFolder .. "TransitionsConfig.ini")
	Transitions.GeneralFont = Transitions.loadFont(generalIni, "GENERALFONT")
	Transitions.GameOverFont = Transitions.loadFont(generalIni, "GAMEOVERFONT")
	Transitions.GameOverFont1 = Transitions.loadFont(generalIni, "GAMEOVERFONT1")
end

function Transitions.loadFont(ini, section)
	local fontName = Config.getString(ini, section, "FontName")
	if not fontName then return nil end
	local fontSize = Config.getNumber(ini, section, "FontSize", 20)
	local r = Config.getNumber(ini, section, "ColorRED", 255) / 255
	local g = Config.getNumber(ini, section, "ColorGREEN", 255) / 255
	local b = Config.getNumber(ini, section, "ColorBLUE", 255) / 255
	local offsetX = Config.getNumber(ini, section, "OffsetX", 0)
	local offsetY = Config.getNumber(ini, section, "OffsetY", 0)
	local font = love.graphics.newFont(Config.fixPath(fontName), fontSize)
	return { font = font, r = r, g = g, b = b, offsetX = offsetX, offsetY = offsetY }
end

-- Draws the "loading level" screen; call BEFORE loading the level data
function Transitions.LevelTransition()
	local nextLevelText = "...loading level number " .. G.SelectedLevel .. "..."

	love.graphics.clear(0, 0, 0)
	if Transitions.GeneralFont then
		local f = Transitions.GeneralFont
		love.graphics.setColor(f.r, f.g, f.b)
		love.graphics.setFont(f.font)
		local y = G.Canvas.Height - f.font:getHeight() - 50
		love.graphics.printf(nextLevelText, 0, y, G.Canvas.Width, "center")
	end
	love.graphics.present()
end

-- ------------------------------------------------------------------------
-- FizzleFade (Feistel network, see fabiensanglard.net/fizzlefade)
-- ------------------------------------------------------------------------

function Transitions.StartFizzleFade(r, g, b, a, speed)
	local W, H = G.Canvas.Width, G.Canvas.Height
	local bits = math.ceil(math.log(W * H) / math.log(2) * 0.5) * 2
	fizzleLastFrame = math.floor(2 ^ bits)
	fizzleHalfBits = math.floor(bits / 2)
	fizzleHalfMask = math.floor(2 ^ fizzleHalfBits) - 1
	fizzleFrame = 0
	fizzleSpeed = speed
	fizzleColor = { r, g, b, a or 1 }
	fizzleCanvas = love.graphics.newCanvas(W, H)
end

local function feistelPixelOffset(frame)
	local left = frame % (fizzleHalfMask + 1)
	local right = math.floor(frame / (fizzleHalfMask + 1))

	for _ = 1, 5 do
		local newLeft = right
		local fn = (right * 19 + math.floor(right / 2))
		fn = bxor(fn, right) % (fizzleHalfMask + 1)
		right = bxor(left, fn)
		left = newLeft
	end

	return bxor(right * (fizzleHalfMask + 1), left % fizzleLastFrame)
end

-- Advances the fizzle fade by one logic frame; returns true when finished
function Transitions.FizzleFadeTick()
	if not fizzleCanvas then return true end

	local W, H = G.Canvas.Width, G.Canvas.Height
	local pointsPerTick = math.floor(fizzleLastFrame / fizzleSpeed)

	love.graphics.push("all")
	love.graphics.setCanvas(fizzleCanvas)
	love.graphics.setColor(fizzleColor[1], fizzleColor[2], fizzleColor[3], 1)
	for _ = 1, pointsPerTick do
		if fizzleFrame >= fizzleLastFrame then break end
		local fnResult = feistelPixelOffset(fizzleFrame)
		local px = fnResult % W
		local py = math.floor(fnResult / W)
		if px < W and py < H then
			love.graphics.points(px + 0.5, py + 0.5)
		end
		fizzleFrame = fizzleFrame + 1
	end
	love.graphics.setCanvas()
	love.graphics.pop()

	return fizzleFrame >= fizzleLastFrame
end

function Transitions.getFizzleFrame()
	return fizzleFrame, fizzleLastFrame
end

function Transitions.RenderFizzleFade()
	if fizzleCanvas then
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.draw(fizzleCanvas, 0, 0)
	end
end

-- ------------------------------------------------------------------------
-- Death sequence
-- ------------------------------------------------------------------------

function Transitions.DeathSequenceStart()
	Transitions.StartFizzleFade(1, 0, 0, 1, 50)
end

function Transitions.RenderGameOverTexts()
	local W = G.Canvas.Width
	if Transitions.GameOverFont then
		local f = Transitions.GameOverFont
		love.graphics.setColor(f.r, f.g, f.b)
		love.graphics.setFont(f.font)
		local y = math.floor(G.Canvas.Height / 2) - math.floor(f.font:getHeight() / 2)
		love.graphics.printf("You are dead. Game over...", 0, y, W, "center")
	end
	if Transitions.GameOverFont1 then
		local f = Transitions.GameOverFont1
		love.graphics.setColor(f.r, f.g, f.b)
		love.graphics.setFont(f.font)
		local y = G.Canvas.Height - f.font:getHeight() - 50
		love.graphics.printf("Press [SPACE] to continue", 0, y, W, "center")
	end
end

Game.Transitions = Transitions
return Transitions
