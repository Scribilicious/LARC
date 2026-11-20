--
-- video.lua - window size, fullscreen, render format and frame scaling
-- LARC addition (no C++ counterpart): the original asks "Fullscreen (y/n)" on
-- the console (Game_PreGame.hpp) and creates the window at exactly the
-- ViewportWidth/Height from WindowConfig.ini. LARC keeps the internal render
-- width at that configured size (WindowConfig.ini) and composes the frame
-- into the render canvas, which is then scaled into the window.
-- LARC always renders widescreen: 16:9 or 16:10, auto-selected to match the
-- desktop. The classic 4:3 viewport stays reachable via LARC_CLASSIC=1 - it
-- is the reference size of the pixel verification workflow (AGENTS.md).
--

local Config = require("src/config")
local G = require("src/globals")
local Game = require("src/game")

local Video = {}

-- settings are written to the LARC save dir; DATA/ stays untouched
local SETTINGS_FILE = "VideoSettings.ini"
local SCALE_STEPS = { 1, 2, 3, 4 }

Video.Fullscreen = false
-- "16:9", "16:10" or "classic" (LARC_CLASSIC=1, verification only);
-- always the render format of the selected resolution entry
Video.Format = "16:10"
Video.ResolutionIndex = 1

-- camera plane factors: the plane must widen with the render aspect to keep
-- world proportions (the C++ has only the fixed 4:3 plane from
-- RaycasterConfig.ini)
local PLANE_FACTORS = {
	["16:9"] = (16 / 9) / (4 / 3),
	["16:10"] = (16 / 10) / (4 / 3),
	classic = 1.0
}

local resolutions = {}
local basePlaneStart

-- render canvas height for a format, at the configured base width
local function formatHeight(format)
	local width = G.Canvas.BaseWidth
	if format == "16:9" then
		return math.floor(width * 9 / 16 + 0.5)
	elseif format == "16:10" then
		return math.floor(width * 10 / 16 + 0.5)
	end
	return G.Canvas.BaseHeight
end

-- pick the format matching the desktop (16:10 MacBooks, 16:9 displays)
local function detectFormat()
	-- defaults to the display the window is on
	local desktopWidth, desktopHeight = love.window.getDesktopDimensions()
	local ratio = desktopWidth / desktopHeight
	if math.abs(ratio - 16 / 9) <= math.abs(ratio - 16 / 10) then
		return "16:9"
	end
	return "16:10"
end

-- window list: for each scale step the 16:9 and the 16:10 size with the same
-- width (640x480 base: 640x360, 640x400, 1280x720, 1280x800, ...); each
-- entry carries its render format, so picking a resolution picks the
-- format; classic keeps the 4:3 squares
local function buildResolutions()
	resolutions = {}
	for _, scale in ipairs(SCALE_STEPS) do
		local width = G.Canvas.BaseWidth * scale
		if Video.Format == "classic" then
			resolutions[#resolutions + 1] = {
				width = width, height = G.Canvas.BaseHeight * scale, format = "classic",
				label = string.format("%dx%d (4:3)", width, G.Canvas.BaseHeight * scale) }
		else
			resolutions[#resolutions + 1] = {
				width = width, height = formatHeight("16:9") * scale, format = "16:9",
				label = string.format("%dx%d (16:9)", width, formatHeight("16:9") * scale) }
			resolutions[#resolutions + 1] = {
				width = width, height = formatHeight("16:10") * scale, format = "16:10",
				label = string.format("%dx%d (16:10)", width, formatHeight("16:10") * scale) }
		end
	end
end

-- index of the scale-n window inside the active resolution list
local function scaleIndex(scale)
	if Video.Format == "classic" then
		return scale
	end
	return Video.Format == "16:9" and scale * 2 - 1 or scale * 2
end

local function saveSettings()
	local resolution = resolutions[Video.ResolutionIndex]
	local contents = "[VIDEO]\r\n"
		.. "Fullscreen=" .. (Video.Fullscreen and 1 or 0) .. "\r\n"
		.. "Width=" .. resolution.width .. "\r\n"
		.. "Height=" .. resolution.height .. "\r\n"
		.. "Format=" .. Video.Format .. "\r\n"
	love.filesystem.write(SETTINGS_FILE, contents)
end

-- internal render size from the format
local function applyRenderSize()
	G.Canvas.Width = G.Canvas.BaseWidth
	G.Canvas.Height = formatHeight(Video.Format)
	G.Canvas.WidthMid = math.floor(G.Canvas.Width / 2)
	G.Canvas.HeightMid = math.floor(G.Canvas.Height / 2)
end

-- set the camera plane for the format. PlaneStartValue is always derived
-- from the unscaled base (RaycasterConfig.ini) so repeated switches cannot
-- drift; the current plane keeps its orientation and is scaled to the
-- target length, so the view direction survives a format switch
local function applyPlane()
	local planeStart = Game.Raycaster and Game.Raycaster.PlaneStartValue
	if not planeStart then
		return
	end
	if not basePlaneStart then
		basePlaneStart = { X = planeStart.X, Y = planeStart.Y }
	end
	local factor = PLANE_FACTORS[Video.Format] or 1.0
	planeStart.X = basePlaneStart.X * factor
	planeStart.Y = basePlaneStart.Y * factor
	local target = math.sqrt(basePlaneStart.X ^ 2 + basePlaneStart.Y ^ 2) * factor
	local current = math.sqrt(G.Plane.X ^ 2 + G.Plane.Y ^ 2)
	if current > 0 and target > 0 then
		local ratio = target / current
		G.Plane.X = G.Plane.X * ratio
		G.Plane.Y = G.Plane.Y * ratio
	end
end

function Video.loadSettings()
	local format = detectFormat()
	local savedWidth, savedHeight, legacyScale

	local ini = Config.loadINI(SETTINGS_FILE)
	if ini then
		Video.Fullscreen = Config.getNumber(ini, "VIDEO", "Fullscreen", 0) == 1
		local savedFormat = Config.getString(ini, "VIDEO", "Format")
		if savedFormat == "16:9" or savedFormat == "16:10" then
			format = savedFormat
		end
		-- legacy "Widescreen" key meant 16:9
		if Config.getNumber(ini, "VIDEO", "Widescreen", -1) == 1 then
			format = "16:9"
		end
		savedWidth = Config.getNumber(ini, "VIDEO", "Width", 0)
		savedHeight = Config.getNumber(ini, "VIDEO", "Height", 0)
		legacyScale = Config.getNumber(ini, "VIDEO", "Scale", 0)
	end

	-- env overrides for automated runs
	local envClassic = os.getenv("LARC_CLASSIC")
	if envClassic and envClassic ~= "0" then
		format = "classic"
	else
		local envAspect = os.getenv("LARC_ASPECT")
		if envAspect == "16:9" or envAspect == "16:10" then
			format = envAspect
		end
	end

	Video.Format = format
	buildResolutions()

	-- window: saved size, else scale step (legacy Scale=), else 2x of the
	-- format; LARC_SCALE= overrides (classic: the n-th 4:3 window)
	local envScale = tonumber(os.getenv("LARC_SCALE") or "")
	if envScale and envScale >= 1 and envScale <= #SCALE_STEPS then
		Video.ResolutionIndex = scaleIndex(envScale)
	else
		local matched = false
		for index, resolution in ipairs(resolutions) do
			if resolution.width == savedWidth and resolution.height == savedHeight then
				Video.ResolutionIndex = index
				Video.Format = resolution.format
				matched = true
				break
			end
		end
		if not matched then
			if legacyScale and legacyScale >= 1 and legacyScale <= #SCALE_STEPS then
				Video.ResolutionIndex = scaleIndex(legacyScale)
			else
				Video.ResolutionIndex = scaleIndex(2)
			end
		end
	end
end

function Video.apply()
	G.Fullscreen = Video.Fullscreen
	if Video.Fullscreen then
		love.window.setFullscreen(true, "desktop")
	else
		local resolution = resolutions[Video.ResolutionIndex]
		love.window.setMode(resolution.width, resolution.height, {
			fullscreen = false, vsync = true, resizable = false, msaa = 0 })
	end
end

-- run AFTER Raycaster.Init (captures the unscaled plane base)
function Video.init()
	G.Canvas.BaseWidth = G.Canvas.Width
	G.Canvas.BaseHeight = G.Canvas.Height
	Video.loadSettings()
	applyRenderSize()
	applyPlane()
	Video.apply()
end

function Video.toggleFullscreen()
	Video.Fullscreen = not Video.Fullscreen
	Video.apply()
	saveSettings()
end

-- cycles the windowed window size (takes effect when not fullscreen); the
-- entry's render format follows the selection, so crossing a format
-- boundary re-applies render size and camera plane
function Video.cycleResolution()
	local index = Video.ResolutionIndex % #resolutions + 1
	local formatChanged = resolutions[index].format ~= Video.Format
	Video.ResolutionIndex = index
	Video.Format = resolutions[index].format
	if formatChanged then
		applyRenderSize()
		applyPlane()
		-- vertical look is a fraction of the canvas height; re-base it
		G.VerticalLookCamera = 0.0
		G.VerticalLook = 0
		if Video.onRenderSizeChange then
			Video.onRenderSizeChange()
		end
	end
	Video.apply()
	saveSettings()
end

function Video.resolutionLabel()
	return "Resolution: " .. resolutions[Video.ResolutionIndex].label
end

-- draws the composed frame (internal render size) into the window,
-- aspect-preserving and letterboxed; fills 16:9/16:10 displays end to end
function Video.present(canvas)
	local windowWidth, windowHeight = love.window.getMode()
	local scale = math.min(windowWidth / G.Canvas.Width, windowHeight / G.Canvas.Height)
	local drawWidth = G.Canvas.Width * scale
	local drawHeight = G.Canvas.Height * scale
	love.graphics.draw(canvas, math.floor((windowWidth - drawWidth) / 2),
		math.floor((windowHeight - drawHeight) / 2), 0, scale, scale)
end

Game.Video = Video
return Video
