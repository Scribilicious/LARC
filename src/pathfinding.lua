--
-- pathfinding.lua - A* pathfinding
-- Ported from Game_PathFinding.hpp
--

local Level = require("src/level")
local Game = require("src/game")

local PathFinding = {}

PathFinding.FlattenedMap = {}

-- GenerateFlattenedMap: walkable tiles = 1.0, others = "infinite" (1e30)
function PathFinding.GenerateFlattenedMap(width, height)
	local map = {}
	local wallLayer = Level.layers[Level.WALL]
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = y * width + x + 1
			local row = wallLayer[x + 1]
			local v = row and row[y + 1] or 0
			if v == 0 then
				map[idx] = 1.0
			else
				map[idx] = 1e30
			end
		end
	end
	PathFinding.FlattenedMap = map
end

-- A* with Manhattan heuristic. Start/Target are flattened indices (0 based).
-- WayPoints are {X, Y} map positions, stored front first (closest to start).
function PathFinding.CalculatePath(width, height, start, target, diagonal, wayPoints)
	local map = PathFinding.FlattenedMap
	local mapSize = width * height
	local targetRow = math.floor(target / width)
	local targetCol = target % width

	local costs = {}
	local paths = {}

	-- priority queue as a simple binary heap
	local heap = {}
	local heapSize = 0

	local function push(index, cost)
		heapSize = heapSize + 1
		heap[heapSize] = { index = index, cost = cost }
		local i = heapSize
		while i > 1 do
			local parent = math.floor(i / 2)
			if heap[i].cost < heap[parent].cost then
				heap[i], heap[parent] = heap[parent], heap[i]
				i = parent
			else
				break
			end
		end
	end

	local function pop()
		local top = heap[1]
		heap[1] = heap[heapSize]
		heap[heapSize] = nil
		heapSize = heapSize - 1
		local i = 1
		while true do
			local l = i * 2
			local r = l + 1
			local smallest = i
			if l <= heapSize and heap[l].cost < heap[smallest].cost then smallest = l end
			if r <= heapSize and heap[r].cost < heap[smallest].cost then smallest = r end
			if smallest ~= i then
				heap[i], heap[smallest] = heap[smallest], heap[i]
				i = smallest
			else
				break
			end
		end
		return top
	end

	costs[start + 1] = 0.0
	push(start, 0.0)

	local pathFound = false

	while heapSize > 0 do
		local current = pop()

		if current.index == target then
			pathFound = true
			break
		end

		local currentIndex = current.index + 1
		local currentCost = costs[currentIndex]
		if currentCost ~= nil then
			local row = math.floor(current.index / width)
			local column = current.index % width

			local neighbours = {}
			neighbours[1] = (diagonal and row > 0 and column > 0) and current.index - width - 1 or -1
			neighbours[2] = (row > 0) and current.index - width or -1
			neighbours[3] = (diagonal and row > 0 and column + 1 < width) and current.index - width + 1 or -1
			neighbours[4] = (column > 0) and current.index - 1 or -1
			neighbours[5] = (column + 1 < width) and current.index + 1 or -1
			neighbours[6] = (diagonal and row + 1 < height and column > 0) and current.index + width - 1 or -1
			neighbours[7] = (row + 1 < height) and current.index + width or -1
			neighbours[8] = (diagonal and row + 1 < height and column + 1 < width) and current.index + width + 1 or -1

			for i = 1, 8 do
				local nIndex = neighbours[i]
				if nIndex >= 0 then
					local newCost = currentCost + map[nIndex + 1]
					local nIndex1 = nIndex + 1
					if costs[nIndex1] == nil or newCost < costs[nIndex1] then
						local nRow = math.floor(nIndex / width)
						local nCol = nIndex % width
						local heuristic
						if diagonal then
							heuristic = math.max(math.abs(nRow - targetRow), math.abs(nCol - targetCol))
						else
							heuristic = math.abs(nRow - targetRow) + math.abs(nCol - targetCol)
						end
						push(nIndex, newCost + heuristic)
						costs[nIndex1] = newCost
						paths[nIndex1] = currentIndex
					end
				end
			end
		end
	end

	-- build waypoint list (front first)
	local index = target
	local list = wayPoints or {}
	while index ~= start do
		local prev = paths[index + 1]
		if prev == nil then break end
		local prevIndex = prev - 1
		if prevIndex ~= start then
			local wp = { X = prevIndex % width, Y = math.floor(prevIndex / width) }
			table.insert(list, 1, wp)
		end
		index = prevIndex
	end

	return pathFound
end

Game.PathFinding = PathFinding
return PathFinding
