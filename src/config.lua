--
-- config.lua - INI file reading / global game config
-- Ported from Game_Config.hpp / lwmf::ReadINIValue
--

local Config = {}

-- strip leading "./" from paths used by the original (runs from game root anyway)
function Config.fixPath(path)
	return (path:gsub("^%./", ""))
end

-- Loads an INI file and returns a table: {SECTION = {key = value}}
function Config.loadINI(fileName)
	local contents = love.filesystem.read(Config.fixPath(fileName))
	if not contents then
		return nil
	end
	local data = {}
	local section
	for line in contents:gmatch("([^\r\n]*)") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and trimmed:sub(1, 1) ~= ";" then
			local s = trimmed:match("^%[(.+)%]$")
			if s then
				section = s:upper()
				data[section] = data[section] or {}
			else
				local key, value = trimmed:match("^([^=]+)%s*=%s*(.-)%s*$")
				if key and value and section then
					data[section][key:upper()] = value
				end
			end
		end
	end
	return data
end

-- Typed getters on a loaded ini table
function Config.getString(ini, section, key)
	if not ini then return nil end
	local s = ini[string.upper(section)]
	return s and s[string.upper(key)] or nil
end

function Config.getNumber(ini, section, key, default)
	local v = Config.getString(ini, section, key)
	local n = tonumber(v)
	if n == nil then
		if v then
			if v:lower() == "true" then n = 1 elseif v:lower() == "false" then n = 0 end
		end
		if n == nil then
			return default
		end
	end
	return n
end

function Config.getBoolean(ini, section, key, default)
	local v = Config.getString(ini, section, key)
	if v == nil then return default end
	local lv = v:lower()
	if lv == "true" or lv == "1" then return true end
	if lv == "false" or lv == "0" then return false end
	return default
end

-- Reads [SECTION] Red/Green/Blue/Alpha color values (lwmf::ReadINIValueRGBA)
function Config.getRGBA(ini, section)
	local r = Config.getNumber(ini, section, "Red", 0) / 255
	local g = Config.getNumber(ini, section, "Green", 0) / 255
	local b = Config.getNumber(ini, section, "Blue", 0) / 255
	local a = Config.getNumber(ini, section, "Alpha", 255) / 255
	return r, g, b, a
end

return Config
