--
-- utils.lua - shared helper functions
--

local Utils = {}

local Config = require("src/config")

-- lwmf::CalcEuclidianDistance
function Utils.distance(x1, x2, y1, y2)
	return math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
end

-- lwmf::ShadeColor returns a color multiplied with a weight and limited by fog distance;
-- returns the per-channel weight (0..1), or -1 if beyond the fog limit (black)
function Utils.shadeFactor(dist, limit)
	if dist > limit then
		return -1
	end
	return (limit - dist) / limit
end

function Utils.clamp(value, min, max)
	if value < min then return min end
	if value > max then return max end
	return value
end

-- Loads an image asset, optionally checking the expected square size
function Utils.loadImage(fileName, expectedSize)
	local fileData = love.filesystem.read("data", Config.fixPath(fileName))
	local imageData = love.image.newImageData(fileData)
	if expectedSize then
		if imageData:getWidth() ~= expectedSize or imageData:getHeight() ~= expectedSize then
			error("Texture " .. fileName .. " has wrong size (expected " .. expectedSize .. "x" .. expectedSize .. ")")
		end
	end
	local image = love.graphics.newImage(imageData)
	image:setFilter("nearest", "nearest")
	return image, imageData
end

-- Numeric read of one whitespace separated "conf" line of values
function Utils.parseConfNumbers(line)
	local values = {}
	for number in line:gmatch("[-+%d%.]+") do
		values[#values + 1] = tonumber(number) or 0
	end
	return values
end

-- A Source is a single playback voice: play() on an already playing source is
-- a no-op, so rapid one-shots (e.g. rapid fire) would be dropped. Play through
-- a small pool of clones so overlapping sounds each get a voice.
local soundPools = setmetatable({}, { __mode = "k" })
local MAX_SOUND_VOICES = 8

function Utils.playSound(source)
	if not source then return end
	if source:isLooping() then
		source:play()
		return
	end
	local pool = soundPools[source]
	if not pool then
		pool = { voices = { source }, next = 1 }
		soundPools[source] = pool
	end
	local voices = pool.voices
	for i = 1, #voices do
		if not voices[i]:isPlaying() then
			voices[i]:play()
			return
		end
	end
	if #voices < MAX_SOUND_VOICES then
		local clone = source:clone()
		voices[#voices + 1] = clone
		clone:play()
	else
		local s = voices[pool.next]
		pool.next = pool.next % #voices + 1
		s:stop()
		s:play()
	end
end

function Utils.fileExists(fileName)
	local info = love.filesystem.getInfo(Config.fixPath(fileName))
	return info ~= nil and info.type == "file"
end

function Utils.folderExists(folderName)
	local info = love.filesystem.getInfo(Config.fixPath(folderName))
	return info ~= nil and info.type == "directory"
end


---Recursively print the table, if not table value is just printed.
---@param t any
---@param level? number
function Utils.printTable(t, level)
	local format = string.format
	local rep = string.rep
	local write = io.write
    level = level or 0
    if type(t) == "table" then
        -- do not print new line on the level 0
        if level ~= 0 then
            write("\n")
        end
        write(rep("\t", level), "{\n")
        level = level + 1

        for key, value in pairs(t) do
            write(rep("\t", level) .. format("[%s] = ", key))
            printTable(value, level)
            write(",\n")
        end

        level = level - 1
        write(rep("\t", level), "}")
    else
        write(tostring(t))
    end
    -- print new line on the level 0
    if level == 0 then
        write("\n")
    end
end

return Utils
