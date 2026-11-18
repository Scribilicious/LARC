-- LARC - Lua LOVE port of NARC ("Not Another RayCaster")
-- (c) original: 2017 - 2020 Stefan Kubsch

local function readWindowConfig()
	local w, h = 640, 480
	local contents = love.filesystem.read("DATA/GameConfig/WindowConfig.ini")
	if contents then
		local section
		for line in contents:gmatch("([^\r\n]*)") do
			local s = line:match("^%s*%[(.+)%]")
			if s then
				section = s:upper()
			else
				local key, value = line:match("^%s*([%w]+)%s*=%s*(.-)%s*$")
				if key and value and section == "WINDOW" then
					if key == "ViewportWidth" then w = tonumber(value) or w end
					if key == "ViewportHeight" then h = tonumber(value) or h end
				end
			end
		end
	end
	return w, h
end

local width, height = readWindowConfig()

function love.conf(t)
	t.identity = "LARC"
	t.window.width = width
	t.window.height = height
	t.window.title = "LARC - Lua LOVE RayCaster (port of NARC)"
	t.window.vsync = true
	t.window.resizable = false
	t.window.msaa = 0
	t.console = false
end
