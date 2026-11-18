--
-- input.lua - keyboard, mouse and gamepad input
-- Ported from HID_Keyboard.hpp, HID_Mouse.hpp, HID_Gamepad.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local Input = {}

-- Microsoft virtual key codes used in InputConfig.ini -> LÖVE scancodes
Input.VKToKey = {
	[87] = "w", -- W
	[83] = "s",
	[65] = "a",
	[68] = "d",
	[82] = "r",
	[72] = "h",
	[77] = "m",
	[32] = "space",
	[107] = "kp+",
	[109] = "kp-",
	[78] = "n",
	[76] = "l",
	[27] = "escape",
	[38] = "up",
	[40] = "down",
	[37] = "left",
	[39] = "right",
	[13] = "return",
	[33] = "pageup",
	[34] = "pagedown"
}

-- virtual key codes (state only, filled from config)
Input.Keys = {}

function Input.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "InputConfig.ini")

	Input.MousePos = { X = 0.0, Y = 0.0 }
	Input.OldMousePos = { X = 0.0, Y = 0.0 }
	Input.MouseSensitivity = 0.6
	Input.MouseSensitivityLowerLimit = 0.1
	Input.MouseSensitivityUpperLimit = 3.0
	Input.MouseSensitivityStep = 0.01

	Input.DeadZone = 0.3
	Input.GamepadSensitivity = 0.3
	Input.RotationXLimit = 0.01

	Input.virtualKeys = {} -- VK states set by the gamepad
	Input.joystick = nil

	if ini then
		Input.MouseSensitivity = Config.getNumber(ini, "MOUSE", "MouseSensitivity", 0.6)
		Input.MouseSensitivityLowerLimit = Config.getNumber(ini, "MOUSE", "MouseSensitivityLowerLimit", 0.1)
		Input.MouseSensitivityUpperLimit = Config.getNumber(ini, "MOUSE", "MouseSensitivityUpperLimit", 3.0)
		Input.MouseSensitivityStep = Config.getNumber(ini, "MOUSE", "MouseSensitivityStep", 0.01)

		local mouseIcon = Config.getString(ini, "MOUSE", "MouseIcon")
		if mouseIcon then
			Input.MouseIcon = Utils.loadImage(mouseIcon)
		end

		Input.DeadZone = Config.getNumber(ini, "GAMECONTROLLER", "DeadZone", 0.3)
		Input.GamepadSensitivity = Config.getNumber(ini, "GAMECONTROLLER", "Sensitivity", 0.3)
		Input.RotationXLimit = Config.getNumber(ini, "GAMECONTROLLER", "RotationXLimit", 0.01)
		local gamepadIcon = Config.getString(ini, "GAMECONTROLLER", "XBoxControllerIcon")
		if gamepadIcon then
			Input.XBoxControllerIcon = Utils.loadImage(gamepadIcon)
		end

		local kb = ini["KEYBOARD"]
		if kb then
			Input.Keys.MoveForward = tonumber(kb["MOVEFORWARDKEY"]) or 87
			Input.Keys.MoveBackward = tonumber(kb["MOVEBACKWARDKEY"]) or 83
			Input.Keys.StrafeLeft = tonumber(kb["STRAFELEFTKEY"]) or 65
			Input.Keys.StrafeRight = tonumber(kb["STRAFERIGHTKEY"]) or 68
			Input.Keys.ReloadWeapon = tonumber(kb["RELOADWEAPONKEY"]) or 82
			Input.Keys.HUD = tonumber(kb["HUDKEY"]) or 72
			Input.Keys.MiniMap = tonumber(kb["MINIMAPKEY"]) or 77
			Input.Keys.Action = tonumber(kb["ACTIONKEY"]) or 32
			Input.Keys.IncreaseMouseSensitivity = tonumber(kb["INCREASEMOUSESENSITIVITYKEY"]) or 107
			Input.Keys.DecreaseMouseSensitivity = tonumber(kb["DECREASEMOUSESENSITIVITYKEY"]) or 109
			Input.Keys.SelectNextLevel = tonumber(kb["SELECTNEXTLEVELKEY"]) or 78
			Input.Keys.SwitchLighting = tonumber(kb["SWITCHLIGHTINGKEY"]) or 76
			Input.Keys.Pause = tonumber(kb["PAUSEKEY"]) or 27
			Input.Keys.MenuItemDown = tonumber(kb["MENUITEMDOWNKEY"]) or 40
			Input.Keys.MenuItemUp = tonumber(kb["MENUITEMUPKEY"]) or 38
			Input.Keys.MenuItemSelect = tonumber(kb["MENUITEMSELECTKEY"]) or 13
		end
	end

	-- gamepad virtual mouse keys (arrow keys, kept fixed like in the original)
	Input.Keys.VirtMouseLeft = 37
	Input.Keys.VirtMouseRight = 39
	Input.Keys.VirtMouseUp = 38
	Input.Keys.VirtMouseDown = 40

	love.mouse.setRelativeMode(true)

	Input.rapidFireTimer = 0
	Input.prevGamepadButtons = {}
end

function Input.ChangeMouseSensitivity(direction)
	if direction == "+" then
		Input.MouseSensitivity = Input.MouseSensitivity + Input.MouseSensitivityStep
		if Input.MouseSensitivity > Input.MouseSensitivityUpperLimit then
			Input.MouseSensitivity = Input.MouseSensitivityUpperLimit
		end
	else
		Input.MouseSensitivity = Input.MouseSensitivity - Input.MouseSensitivityStep
		if Input.MouseSensitivity < Input.MouseSensitivityLowerLimit then
			Input.MouseSensitivity = Input.MouseSensitivityLowerLimit
		end
	end
end

-- is a (virtual key code) key currently held?
function Input.isKeyDown(vk)
	if os.getenv("LARC_NOINPUT") then
		return false
	end
	local scancode = Input.VKToKey[vk]
	if scancode and love.keyboard.isDown(scancode) then
		return true
	end
	return Input.virtualKeys[vk] == true
end

-- Called by love.mousemoved
function Input.addMouseMovement(dx, dy)
	Input.MousePos.X = Input.MousePos.X + dx
	Input.MousePos.Y = Input.MousePos.Y + dy
end

-- Gamepad handling: called once per logic tick
function Input.refreshGamepad(dt)
	Input.virtualKeys = {}

	local joysticks = love.joystick.getJoysticks()
	local joystick = joysticks[1]

	if not joystick or not joystick:isGamepad() then
		Input.joystick = nil
		return
	end
	Input.joystick = joystick

	local dz = Input.DeadZone

	-- left stick: movement
	local lx = joystick:getGamepadAxis("leftx")
	local ly = joystick:getGamepadAxis("lefty")
	if math.abs(lx) > dz then
		if lx < 0 then Input.virtualKeys[Input.Keys.StrafeLeft] = true
		else Input.virtualKeys[Input.Keys.StrafeRight] = true end
	end
	if math.abs(ly) > dz then
		if ly < 0 then Input.virtualKeys[Input.Keys.MoveForward] = true
		else Input.virtualKeys[Input.Keys.MoveBackward] = true end
	end

	-- right stick: look (virtual mouse keys)
	local rx = joystick:getGamepadAxis("rightx")
	local ry = joystick:getGamepadAxis("righty")
	if math.abs(rx) > dz then
		if rx < 0 then Input.virtualKeys[Input.Keys.VirtMouseLeft] = true
		else Input.virtualKeys[Input.Keys.VirtMouseRight] = true end
	end
	if math.abs(ry) > dz then
		if ry < 0 then Input.virtualKeys[Input.Keys.VirtMouseUp] = true
		else Input.virtualKeys[Input.Keys.VirtMouseDown] = true end
	end

	-- buttons with repeat intervals (port of lwmf SetInterval behaviour)
	local Weapons = Game.Weapons
	local pressed = function(name) return joystick:isGamepadDown(name) end

	if pressed("rightshoulder") then
		Weapons.InitiateSingleShot()
	end

	Input.rapidFireTimer = Input.rapidFireTimer + dt
	if pressed("leftshoulder") then
		if Input.rapidFireTimer >= 0.15 then
			Input.rapidFireTimer = 0
			Weapons.InitiateRapidFire()
		end
	else
		Input.rapidFireTimer = 0.15 -- fire immediately on press
		if Game.Weapons.CurrentFiringState == Game.Weapons.FIRINGSTATE.RAPIDFIRE then
			Weapons.ReleaseRapidFire()
		end
	end

	local singlePress = function(name, fn)
		local isDown = pressed(name)
		if isDown and not Input.prevGamepadButtons[name] then
			fn()
		end
		Input.prevGamepadButtons[name] = isDown
	end

	singlePress("x", function() Game.Doors.TriggerDoor() end)
	singlePress("dpup", function() Weapons.InitiateWeaponChangeUp() end)
	singlePress("dpdown", function() Weapons.InitiateWeaponChangeDown() end)
	singlePress("dpright", function() Weapons.InitiateReload() end)
end

-- which look axis is the gamepad right stick pushed to (for ControlPlayerMovement)?
function Input.getGamepadRightStick()
	local joystick = Input.joystick
	if not joystick then return 0, 0 end
	local rx = joystick:getGamepadAxis("rightx")
	local ry = joystick:getGamepadAxis("righty")
	local dz = Input.DeadZone
	if math.abs(rx) <= dz then rx = 0 end
	if math.abs(ry) <= dz then ry = 0 end
	return rx, ry
end

Input.isGamepadActive = function()
	return Input.joystick ~= nil
end

Game.Input = Input
return Input
