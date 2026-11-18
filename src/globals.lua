--
-- globals.lua - global definitions
-- Ported from Game_GlobalDefinitions.hpp / Game_Folder.hpp
--

local G = {}

-- Folders (Game_Folder.hpp)
G.LevelFolder = "DATA/Levels/"
G.GameConfigFolder = "DATA/GameConfig/"
G.AssetsEntitiesFolder = "DATA/Assets_Entities/"
G.AssetsDoorsFolder = "DATA/Assets_Doors/"
G.AssetsWeaponsFolder = "DATA/Assets_Weapons/"
G.GFXEntitiesFolder = "GFX/Entities/"

-- Raycaster plane / vertical look (Game_GlobalDefinitions.hpp)
G.Plane = { X = 0.0, Y = 0.66 }
G.PlaneStartValue = { X = 0.0, Y = 0.66 }
G.VerticalLookCamera = 0.0
G.VerticalLookUpLimit = 0.4
G.VerticalLookDownLimit = 0.4
G.VerticalLookStep = 0.02
G.FogOfWarDistance = 2.5
G.VerticalLook = 0

-- Levels
G.StartLevel = 1
G.SelectedLevel = 1
G.NumberOfLevels = 0

-- Renderer options
G.VSync = true
G.Fullscreen = false

-- Texture sizes
G.TextureSize = 64
G.EntitySize = 64
G.TextureSizeBitShift = 6

-- Fixed timestep
G.FrameLock = 60
G.LengthOfFrame = 1000 / 60
G.GamePausedFlag = false
G.GameControllerFlag = false
G.QuitGameFlag = false
G.HUDEnabled = true

-- Viewport ("Canvas" in the C++ original)
G.Canvas = { Width = 640, Height = 480, WidthMid = 320, HeightMid = 240 }

-- RNG
G.random = love.math.newRandomGenerator()
G.random:setSeed(love.math.getRandomSeed())

return G
