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

function Utils.fileExists(fileName)
	local info = love.filesystem.getInfo(Config.fixPath(fileName))
	return info ~= nil and info.type == "file"
end

function Utils.folderExists(folderName)
	local info = love.filesystem.getInfo(Config.fixPath(folderName))
	return info ~= nil and info.type == "directory"
end

return Utils
