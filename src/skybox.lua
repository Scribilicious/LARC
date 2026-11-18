--
-- skybox.lua - skybox handling
-- Ported from Game_SkyboxHandling.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")

local Skybox = {}

Skybox.Texture = nil
Skybox.SkyboxWidth = 0
Skybox.SkyboxHeight = 0
Skybox.SkyBoxEnabled = false

function Skybox.LoadSkyboxImage()
	local iniFile = G.LevelFolder .. G.SelectedLevel .. "/LevelData/SkyboxConfig.ini"
	if Utils.fileExists(iniFile) then
		local ini = Config.loadINI(iniFile)
		Skybox.SkyBoxEnabled = Config.getBoolean(ini, "SKYBOX", "SkyBoxEnabled", false)
		if Skybox.SkyBoxEnabled then
			local imageFile = Config.getString(ini, "SKYBOX", "SkyBoxImageName")
			if imageFile then
				Skybox.Texture = Utils.loadImage(imageFile)
				Skybox.SkyboxWidth = Skybox.Texture:getWidth()
				Skybox.SkyboxHeight = Skybox.Texture:getHeight()
			end
		end
	end
end

function Skybox.Render()
	if Skybox.SkyBoxEnabled and Skybox.Texture then
		local left = math.floor(math.atan2(G.Plane.X, G.Plane.Y) / (2.0 * math.pi) * -Skybox.SkyboxWidth)
		local top = math.floor(G.VerticalLookCamera * 360.0 - 180.0)

		love.graphics.draw(Skybox.Texture, left, top)

		if left < Skybox.SkyboxWidth - G.Canvas.Width then
			love.graphics.draw(Skybox.Texture, left - Skybox.SkyboxWidth, top)
		end
	end
end

return Skybox
