--
-- main.lua - the game itself
-- Ported from NARC.cpp
--

local Game = require("src/game")
local G = Game.G
local Config = Game.Config
local Utils = Game.Utils
local Level = Game.Level

local Raycaster = require("src/raycaster")
local PathFinding = require("src/pathfinding")
local Entities = require("src/entities")
local Doors = require("src/doors")
local Weapons = require("src/weapons")
local PlayerClass = require("src/player")
local Effects = require("src/effects")
local Decals = require("src/decals")
local BloodBurst = require("src/bloodburst")
local Skybox = require("src/skybox")
local Transitions = require("src/transitions")
local Menu = require("src/menu")
local Video = require("src/video")
local HUD = require("src/hud")
local Input = require("src/input")

local EntityTypes = Entities.EntityTypes
local Player

-- scene render target ("Canvas" in the C++ original)
local sceneCanvas

-- game state: "play" (running or paused by menu), "dying", "dead"
local State = { mode = "play" }
local accumulator = 0
local footstepActive = false

-- debug helper: LARC_SCREENSHOT=1 love LARC -> writes screenshot.png into save dir after 3s
local debugScreenshot = os.getenv("LARC_SCREENSHOT")
local debugAutoFire = os.getenv("LARC_AUTOFIRE")
local debugTime = 0

-- ------------------------------------------------------------------------
-- Init
-- ------------------------------------------------------------------------

local function InitAndLoadGameConfig()
	local ini = Config.loadINI(G.GameConfigFolder .. "GameConfig.ini")
	if ini then
		G.TextureSize = Config.getNumber(ini, "TEXTURES", "TextureSize", 64)
		G.EntitySize = Config.getNumber(ini, "TEXTURES", "EntitySize", 64)
		G.FrameLock = Config.getNumber(ini, "GENERAL", "FrameLock", 60)
		G.TextureSizeBitShift = math.log(G.TextureSize) / math.log(2)
	end

	local windowIni = Config.loadINI(G.GameConfigFolder .. "WindowConfig.ini")
	if windowIni then
		G.Canvas.Width = Config.getNumber(windowIni, "WINDOW", "ViewportWidth", 640)
		G.Canvas.Height = Config.getNumber(windowIni, "WINDOW", "ViewportHeight", 480)
		G.Canvas.WidthMid = math.floor(G.Canvas.Width / 2)
		G.Canvas.HeightMid = math.floor(G.Canvas.Height / 2)
	end

	local windowW, windowH = love.window.getMode()
	if windowW ~= G.Canvas.Width or windowH ~= G.Canvas.Height then
		love.window.setMode(G.Canvas.Width, G.Canvas.Height)
	end

	G.LengthOfFrame = 1000 / G.FrameLock

	-- gather number of levels (count level folders)
	G.SelectedLevel = G.StartLevel
	local dbgLevel = os.getenv("LARC_LEVEL")
	if dbgLevel then G.SelectedLevel = tonumber(dbgLevel) end
	G.NumberOfLevels = G.StartLevel
	while Utils.folderExists(G.LevelFolder .. G.NumberOfLevels) do
		G.NumberOfLevels = G.NumberOfLevels + 1
	end
	G.NumberOfLevels = G.NumberOfLevels - 1
end

local function InitAndLoadLevel()
	Transitions.LevelTransition()

	Level.InitConfig()
	Level.InitMapData()
	Level.InitLights()
	Level.InitTextures()
	Level.InitBackgroundMusic()

	PathFinding.GenerateFlattenedMap(Level.LevelMapWidth, Level.LevelMapHeight)

	Doors.InitDoors()
	Skybox.LoadSkyboxImage()
	HUD.Minimap.PreRender()

	Player = PlayerClass.new()
	Player:InitConfig()
	Player:InitAudio()
	Game.Player = Player

	Entities.InitEntityAssets()
	Entities.InitEntities()
	Decals.Clear()
	BloodBurst.Clear()

	Raycaster.RefreshSettings()

	Entities.EntityMap[math.floor(Player.Pos.X) + 1][math.floor(Player.Pos.Y) + 1] = EntityTypes.PLAYER

	-- reset weapons state (HUD strings, counters)
	Weapons.CurrentWeaponState = Weapons.WEAPONSTATE.READY
	Weapons.CurrentFiringState = Weapons.FIRINGSTATE.NONE
	Weapons.WeaponPace = 0.0
	Weapons.WeaponPaceFlag = false
	Weapons.WeaponFadeInOutY = 0
	Weapons.WeaponHeightFadeInOut = 0

	State.mode = "play"
	Level.PlayBackgroundMusic()
end

function love.load()
	-- print the intro header to the console, like the original did
	local headerFile = G.GameConfigFolder .. "IntroHeader.txt"
	if Utils.fileExists(headerFile) then
		for line in love.filesystem.lines(Config.fixPath(headerFile)) do
			print(line)
		end
	end

	InitAndLoadGameConfig()

	Input.Init()
	Transitions.Init()

	Raycaster.Init()

	-- after Raycaster.Init: Video.init scales the camera plane from the
	-- unscaled base (RaycasterConfig.ini); Menu.init needs Video
	Video.init()
	Menu.Init()
	Weapons.InitConfig()
	Weapons.InitTextures()
	Weapons.InitAudio()
	Effects.InitEffects()
	Decals.Init()
	BloodBurst.Init()

	HUD.WeaponDisplay.Init()
	HUD.HealthBar.Init()
	HUD.Minimap.Init()

	Entities.InitShader()

	Doors.InitDoorAssets()

	sceneCanvas = love.graphics.newCanvas(G.Canvas.Width, G.Canvas.Height)
	sceneCanvas:setFilter("nearest", "nearest")

	-- widescreen toggle reruns this: rebuild the render target and the
	-- position-dependent prerendered minimap when the render size changes
	Video.onRenderSizeChange = function()
		sceneCanvas = love.graphics.newCanvas(G.Canvas.Width, G.Canvas.Height)
		sceneCanvas:setFilter("nearest", "nearest")
		HUD.Minimap.PreRender()
	end

	InitAndLoadLevel()

	-- debug helper: LARC_TESTPOS="x,y,dirx,diry" teleports the player after load
	local testpos = os.getenv("LARC_TESTPOS")
	if testpos then
		local x, y, dirx, diry = testpos:match("([%d%.]+),([%d%.]+),([%-%d%.]+),([%-%d%.]+)")
		if x then
			Player.Pos.X, Player.Pos.Y = tonumber(x), tonumber(y)
			Player.Dir.X, Player.Dir.Y = tonumber(dirx), tonumber(diry)
			print(string.format("LARC debug: teleported player to %.1f,%.1f (dir %.1f,%.1f)",
				Player.Pos.X, Player.Pos.Y, Player.Dir.X, Player.Dir.Y))
		end
	end

	-- debug helper: LARC_TESTDOOR=1 teleports the player near the door at tile (6,4) and triggers it
	if os.getenv("LARC_TESTDOOR") then
		Player.Pos.X, Player.Pos.Y = 4.5, 4.5
		Player.Dir.X, Player.Dir.Y = 1.0, 0.0
		Player.FuturePos.X, Player.FuturePos.Y = 6, 4
		print("LARC debug door: preloaded, will trigger after 2s")
	end

	-- debug helper: LARC_TESTVL=<camera fraction> sets vertical look
	-- (positive = up, negative = down, e.g. 0.3 for testing)
	local testvl = tonumber(os.getenv("LARC_TESTVL") or "")
	if testvl then
		G.VerticalLookCamera = testvl
		G.VerticalLook = math.floor(G.Canvas.Height * testvl)
		if G.VerticalLook % 2 ~= 0 then
			if G.VerticalLook < 0 then
				G.VerticalLook = G.VerticalLook - 1
			else
				G.VerticalLook = G.VerticalLook + 1
			end
		end
		print(string.format("LARC debug: vertical look set to %.3f (VL=%d)", G.VerticalLookCamera, G.VerticalLook))
	end
end

local function debugDoorTick()
	if love._larcDoorDone ~= true and debugTime > 2 then
		Doors.TriggerDoor()
		love._larcDoorDone = true
		print("LARC debug door: triggered")
	end
end

-- ------------------------------------------------------------------------
-- Player movement (from NARC.cpp)
-- ------------------------------------------------------------------------

local DEG2RAD = math.pi / 180.0

local function movePlayerAndCheckCollision()
	local Player = Player
	local EntityMap = Entities.EntityMap
	local wallLayer = Level.layers[Level.WALL]

	local fx = Player.FuturePos.X
	local fy = Player.FuturePos.Y
	local px = math.floor(Player.Pos.X)
	local py = math.floor(Player.Pos.Y)

	local cellValue = EntityMap[fx + 1] and EntityMap[fx + 1][fy + 1] or EntityTypes.CLEAR

	if (not wallLayer[fx + 1] or wallLayer[fx + 1][py + 1] == 0)
		and (not wallLayer[px + 1] or wallLayer[px + 1][fy + 1] == 0)
		and cellValue ~= EntityTypes.ENEMY
		and cellValue ~= EntityTypes.NEUTRAL
		and cellValue ~= EntityTypes.TURRET then

		Player.Pos.X = Player.Pos.X + Player.StepWidth.X
		Player.Pos.Y = Player.Pos.Y + Player.StepWidth.Y

		Weapons.WeaponPaceFlag = not Weapons.WeaponPaceFlag
		if Weapons.WeaponPaceFlag then
			Weapons.WeaponPace = Weapons.WeaponPace + Weapons.Weapons[Player.SelectedWeapon + 1].PaceFactor
		end

		Weapons.HandleAmmoBoxPickup()

		-- footstep audio
		local footsteps = Player.Sounds[PlayerClass.SOUNDS.FOOTSTEPS]
		if footsteps and not footsteps:isPlaying() then
			footsteps:play()
		end
		footstepActive = true
	end
end

local function controlPlayerMovement()
	local Player = Player
	local EntityMap = Entities.EntityMap
	EntityMap[math.floor(Player.Pos.X) + 1][math.floor(Player.Pos.Y) + 1] = EntityTypes.CLEAR
	Weapons.WeaponPaceFlag = false

	local gamepadActive = G.GameControllerFlag and Input.isGamepadActive()
	local rawStickX, rawStickY = 0, 0

	if gamepadActive then
		rawStickX, rawStickY = Input.getGamepadRightStick()
		Input.MousePos.X = rawStickX < 0 and -1 or (rawStickX > 0 and 1 or 0)
		Input.MousePos.Y = rawStickY < 0 and -1 or (rawStickY > 0 and 1 or 0)
	end

	local inputSensitivity = gamepadActive and Input.GamepadSensitivity or Input.MouseSensitivity

	if Input.MousePos.X ~= Input.OldMousePos.X then
		local rotationX
		if gamepadActive then
			rotationX = Input.RotationXLimit * (rawStickX / inputSensitivity)
		else
			rotationX = Input.MousePos.X * inputSensitivity * DEG2RAD
		end
		local tempCos = math.cos(-rotationX)
		local tempSin = math.sin(-rotationX)
		local oldDirX, oldDirY = Player.Dir.X, Player.Dir.Y
		local oldPlaneX, oldPlaneY = G.Plane.X, G.Plane.Y
		Player.Dir.X = oldDirX * tempCos - oldDirY * tempSin
		Player.Dir.Y = oldDirX * tempSin + oldDirY * tempCos
		G.Plane.X = oldPlaneX * tempCos - oldPlaneY * tempSin
		G.Plane.Y = oldPlaneX * tempSin + oldPlaneY * tempCos
	end

	if Input.MousePos.Y ~= Input.OldMousePos.Y then
		local mouseY = Input.MousePos.Y
		if mouseY < 0 then
			local lookTemp1 = Raycaster.VerticalLookStep * -(mouseY * inputSensitivity)
			if G.VerticalLookCamera + lookTemp1 < Raycaster.VerticalLookUpLimit then
				G.VerticalLookCamera = G.VerticalLookCamera + lookTemp1
			end
		elseif mouseY > 0 then
			local lookTemp2 = Raycaster.VerticalLookStep * (mouseY * inputSensitivity)
			if -(G.VerticalLookCamera - lookTemp2) < Raycaster.VerticalLookDownLimit then
				G.VerticalLookCamera = G.VerticalLookCamera - lookTemp2
			end
		end

		G.VerticalLook = math.floor(G.Canvas.Height * G.VerticalLookCamera)
		if G.VerticalLook % 2 ~= 0 then
			if G.VerticalLook < 0 then
				G.VerticalLook = G.VerticalLook - 1
			else
				G.VerticalLook = G.VerticalLook + 1
			end
		end
	end

	Input.OldMousePos.X = Input.MousePos.X
	Input.OldMousePos.Y = Input.MousePos.Y

	if not gamepadActive then
		-- mouse deltas are consumed per tick
		Input.MousePos.X = 0
		Input.MousePos.Y = 0
	end

	-- movement
	local moved = false
	if Input.isKeyDown(Input.Keys.MoveForward) then
		local cdf = Player.CollisionDetectionFactor
		Player.FuturePos.X = math.floor(Player.Pos.X + Player.Dir.X * cdf)
		Player.FuturePos.Y = math.floor(Player.Pos.Y + Player.Dir.Y * cdf)
		Player.StepWidth.X = Player.Dir.X * Player.MoveSpeed
		Player.StepWidth.Y = Player.Dir.Y * Player.MoveSpeed
		movePlayerAndCheckCollision()
		moved = true
	elseif Input.isKeyDown(Input.Keys.MoveBackward) then
		local cdf = Player.CollisionDetectionFactor
		Player.FuturePos.X = math.floor(Player.Pos.X - Player.Dir.X * cdf)
		Player.FuturePos.Y = math.floor(Player.Pos.Y - Player.Dir.Y * cdf)
		Player.StepWidth.X = -(Player.Dir.X * Player.MoveSpeed)
		Player.StepWidth.Y = -(Player.Dir.Y * Player.MoveSpeed)
		movePlayerAndCheckCollision()
		moved = true
	end

	if Input.isKeyDown(Input.Keys.StrafeRight) then
		local cdf = Player.CollisionDetectionFactor
		Player.FuturePos.X = math.floor(Player.Pos.X + G.Plane.X * cdf)
		Player.FuturePos.Y = math.floor(Player.Pos.Y + G.Plane.Y * cdf)
		Player.StepWidth.X = G.Plane.X * Player.MoveSpeed
		Player.StepWidth.Y = G.Plane.Y * Player.MoveSpeed
		movePlayerAndCheckCollision()
		moved = true
	elseif Input.isKeyDown(Input.Keys.StrafeLeft) then
		local cdf = Player.CollisionDetectionFactor
		Player.FuturePos.X = math.floor(Player.Pos.X - G.Plane.X * cdf)
		Player.FuturePos.Y = math.floor(Player.Pos.Y - G.Plane.Y * cdf)
		Player.StepWidth.X = -(G.Plane.X * Player.MoveSpeed)
		Player.StepWidth.Y = -(G.Plane.Y * Player.MoveSpeed)
		movePlayerAndCheckCollision()
		moved = true
	end

	if not moved and footstepActive then
		local footsteps = Player.Sounds[PlayerClass.SOUNDS.FOOTSTEPS]
		if footsteps then footsteps:stop() end
		footstepActive = false
	end

	EntityMap[math.floor(Player.Pos.X) + 1][math.floor(Player.Pos.Y) + 1] = EntityTypes.PLAYER
end

-- ------------------------------------------------------------------------
-- Update
-- ------------------------------------------------------------------------

local function tick(dt)
	Input.refreshGamepad(dt)

	if not G.GamePausedFlag then
		local beforeX, beforeY = Player.Pos.X, Player.Pos.Y
		controlPlayerMovement()
		if os.getenv("LARC_DEBUGMOVE") and (Player.Pos.X ~= beforeX or Player.Pos.Y ~= beforeY) and not love._larcMoveLogged then
			love._larcMoveLogged = true
			print(string.format("LARC debug move: %.3f -> %.3f keys w=%s s=%s a=%s d=%s mouse=%.1f,%.1f joy=%s",
				beforeX, Player.Pos.X,
				tostring(Input.isKeyDown(Input.Keys.MoveForward)), tostring(Input.isKeyDown(Input.Keys.MoveBackward)),
				tostring(Input.isKeyDown(Input.Keys.StrafeLeft)), tostring(Input.isKeyDown(Input.Keys.StrafeRight)),
				Input.MousePos.X, Input.MousePos.Y, tostring(Input.isGamepadActive())))
		end
		Entities.MoveEntities(dt)
		Doors.OpenCloseDoors()
		Weapons.ChangeWeapon()
		Weapons.CheckReloadStatus()
		Weapons.CountdownMuzzleFlashCounter()
		Weapons.CountdownCadenceCounter()
		Effects.CountdownBloodstainCounter()
		BloodBurst.Tick(dt)
		local tbAge = tonumber(os.getenv("LARC_TESTBURST") or "")
		if tbAge then
			local b = love._larcTestBurst
			if not b then
				local dd = tonumber(os.getenv("LARC_TESTBURSTD")) or 1.6
				BloodBurst.Spawn(Player.Pos.X + Player.Dir.X * dd, Player.Pos.Y + Player.Dir.Y * dd, tonumber(os.getenv("LARC_TESTBURSTH")) or 0.5)
				b = BloodBurst.bursts[#BloodBurst.bursts]
				love._larcTestBurst = b
			end
			b.birth = BloodBurst.time - tbAge
		end

		if Player.IsDead then
			State.mode = "dying"
			Transitions.DeathSequenceStart()
		end
	end
end

function love.update(dt)
	if debugScreenshot then
		debugTime = debugTime + dt
		local shotCount = math.floor(debugTime / 2)
		if shotCount > (love._larcShot or 0) then
			love._larcShot = shotCount
			love.graphics.captureScreenshot(function(imageData)
				imageData:encode("png", "screenshot" .. shotCount .. ".png")
				print("screenshot" .. shotCount .. ".png written, FPS " .. love.timer.getFPS())
				local ff, fl = Transitions.getFizzleFrame()
				print(string.format("LARC debug: player %.2f,%.2f hp=%d state=%s fizzle=%d/%d paused=%s",
					Player.Pos.X, Player.Pos.Y, Player.Hitpoints,
					State.mode, ff, fl, tostring(G.GamePausedFlag)))
				print(string.format("LARC debug: cam dir=%.4f,%.4f plane=%.4f,%.4f VC=%.4f VL=%d lighting=%s",
					Player.Dir.X, Player.Dir.Y, G.Plane.X, G.Plane.Y,
					G.VerticalLookCamera, G.VerticalLook, tostring(Level.LightingFlag)))
			end)
		end
		if debugTime > 10 then
			print("LARC debug: exiting after screenshots")
			love.event.quit()
		end
		if debugAutoFire and debugTime > 2 and debugTime < 8 then
			Weapons.InitiateSingleShot()
		end
		if os.getenv("LARC_TESTDOOR") then
			debugDoorTick()
		end
	end

	-- debug: LARC_TESTDEATH=1 kills the player at t=2 and opens the pause menu at t=7
	if os.getenv("LARC_TESTDEATH") then
		if debugTime > 2 and not love._larcDied then
			love._larcDied = true
			Player:HurtPlayer(105)
		end
		if debugTime > 7 and not love._larcSpace then
			love._larcSpace = true
			love.keypressed("space")
		end
	end

	-- debug: LARC_TESTMENU=1 pauses at t=3, selects "Exit Game" via menu at t=5
	local testMenu = os.getenv("LARC_TESTMENU")
	if testMenu then
		if debugTime > 3 and not love._larcMenuPause then
			love._larcMenuPause = true
			love.keypressed("escape")
			print("LARC debug menu: escape -> paused=" .. tostring(G.GamePausedFlag))
		end
		if debugTime > 4 and not love._larcMenuDown then
			love._larcMenuDown = true
			love.keypressed("down")
			print("LARC debug menu: down -> highlight=" .. Menu.HighLightedItem .. " paused=" .. tostring(G.GamePausedFlag))
		end
		if debugTime > 5 and not love._larcMenuSelect then
			love._larcMenuSelect = true
			love.keypressed("return")
			print("LARC debug menu: select -> quit=" .. tostring(G.QuitGameFlag))
		end
	end

	accumulator = accumulator + dt

	if State.mode == "dying" then
		-- fizzle fade runs at the logic rate
		while accumulator >= 1 / G.FrameLock do
			accumulator = accumulator - 1 / G.FrameLock
			if Transitions.FizzleFadeTick() then
				State.mode = "dead"
				break
			end
		end
		return
	end

	if State.mode == "dead" then
		return
	end

	while accumulator >= 1 / G.FrameLock do
		accumulator = accumulator - 1 / G.FrameLock
		tick(1 / G.FrameLock)
	end

	if State.mode ~= "play" then
		return
	end

	-- per frame work (like the part of the C++ main loop outside the lag loop)
	Level.PlayBackgroundMusic()

	Entities.GetEntityDistance()

	-- sort entities front to back to check weapon hit on first entity in front of player
	Entities.SortEntities(true)
	if not G.GamePausedFlag then
		Weapons.FireWeapon()
	end
	-- sort back to front for correct draw order
	Entities.SortEntities(false)
end

-- ------------------------------------------------------------------------
-- Draw
-- ------------------------------------------------------------------------

-- draws the scene and HUD into the active sceneCanvas (love.draw sets it up
-- and blits the composed frame to the window via Video.present)
local function renderScene()
	local HUDEnabled = G.HUDEnabled

	Raycaster.render()

	if not os.getenv("LARC_NOENTITIES") then
		Entities.RenderEntities()
	end

	-- in front of the target: the spray bursts towards the camera
	BloodBurst.Render()

	if HUD.Minimap.Enabled then
		HUD.Minimap.DisplayRealtimeMap()
	end

	if HUDEnabled then
		HUD.HealthBar.Display()
		HUD.DisplayFPSCounter()
	end

	Weapons.DrawWeapon()

	if HUDEnabled then
		HUD.WeaponDisplay.Display()
		local gamepadActive = G.GameControllerFlag and Input.isGamepadActive()
		local icon = gamepadActive and Input.XBoxControllerIcon or Input.MouseIcon
		if icon then
			love.graphics.draw(icon, G.Canvas.Width - 153, 0)
		end
	end

	if HUD.Minimap.Enabled then
		HUD.Minimap.DisplayPreRenderedMap()
	end

	Effects.DrawBloodstain()

	if G.GamePausedFlag then
		Menu.Show()
	end
end

function love.draw()
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)

	-- compose the whole frame at the internal viewport size,
	-- then scale it into the window (Video.present)
	love.graphics.setCanvas(sceneCanvas)
	love.graphics.clear(0, 0, 0, 0)

	if State.mode == "dying" or State.mode == "dead" then
		-- frozen scene + death overlays
		Skybox.Render()
		Raycaster.render()
		Entities.RenderEntities()
		Transitions.RenderFizzleFade()
		if State.mode == "dead" then
			Transitions.RenderGameOverTexts()
		end
	else
		Skybox.Render()
		renderScene()
	end

	love.graphics.setCanvas()
	Video.present(sceneCanvas)
end

-- ------------------------------------------------------------------------
-- Input events
-- ------------------------------------------------------------------------

local keyToVK = {}
for vk, scancode in pairs(Input.VKToKey) do
	keyToVK[scancode] = vk
end

local function handleKey(scancode)
	local vk = keyToVK[scancode]
	if not vk then
		return
	end

	if State.mode == "dead" then
		if vk == Input.Keys.Action then -- space
			G.GamePausedFlag = true
			State.mode = "play"
		end
		return
	end

	if State.mode == "dying" then
		return
	end

	if G.GamePausedFlag then
		if vk == Input.Keys.MenuItemDown then
			Menu.ItemDown()
		elseif vk == Input.Keys.MenuItemUp then
			Menu.ItemUp()
		elseif vk == Input.Keys.MenuItemSelect then
			Menu.ItemSelect()
		elseif vk == Input.Keys.Pause then
			Menu.LevelUp()
		end
		return
	end

	if vk == Input.Keys.Pause then
		Menu.LevelUp()
		return
	end

	if vk == Input.Keys.Action then
		Doors.TriggerDoor()
	elseif vk == Input.Keys.ReloadWeapon then
		Weapons.InitiateReload()
	elseif vk == Input.Keys.HUD then
		G.HUDEnabled = not G.HUDEnabled
	elseif vk == Input.Keys.MiniMap then
		HUD.Minimap.Enabled = not HUD.Minimap.Enabled
	elseif vk == Input.Keys.IncreaseMouseSensitivity then
		Input.ChangeMouseSensitivity("+")
	elseif vk == Input.Keys.DecreaseMouseSensitivity then
		Input.ChangeMouseSensitivity("-")
	elseif vk == Input.Keys.SelectNextLevel then
		if G.NumberOfLevels > G.StartLevel then
			if G.SelectedLevel < G.NumberOfLevels then
				G.SelectedLevel = G.SelectedLevel + 1
			else
				G.SelectedLevel = G.StartLevel
			end
			InitAndLoadLevel()
		end
	elseif vk == Input.Keys.SwitchLighting then
		Level.LightingFlag = not Level.LightingFlag
	end
end

function love.keypressed(key, scancode)
	-- LARC addition: Alt+Enter toggles fullscreen (no C++ counterpart)
	if scancode == "return" and (love.keyboard.isDown("lalt") or love.keyboard.isDown("ralt")) then
		Video.toggleFullscreen()
		return
	end
	handleKey(key)
end

function love.mousemoved(x, y, dx, dy)
	if love.mouse.getRelativeMode() and not os.getenv("LARC_NOINPUT") then
		Input.addMouseMovement(dx, dy)
	end
end

function love.mousepressed(x, y, button)
	if State.mode ~= "play" or G.GamePausedFlag then
		return
	end
	if button == 1 then
		Weapons.InitiateSingleShot()
	elseif button == 2 then
		Weapons.InitiateRapidFire()
	end
end

function love.mousereleased(x, y, button)
	if button == 2 then
		Weapons.ReleaseRapidFire()
	end
end

function love.wheelmoved(x, y)
	if State.mode ~= "play" or G.GamePausedFlag then
		return
	end
	if y < 0 then
		Weapons.InitiateWeaponChangeDown()
	elseif y > 0 then
		Weapons.InitiateWeaponChangeUp()
	end
end
