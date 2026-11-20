--
-- menu.lua - pause menu
-- Ported from Game_MenuClass.hpp
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local Menu = {}

Menu.MenuItems = {}
Menu.Pos = {}
Menu.HighLightedItem = 0
Menu.MenuSelectedLevel = 0
Menu.SelectedItem = 0
Menu.Text = nil
Menu.TextHighlight = nil

function Menu.Init()
	local menuConfig = Config.loadINI(G.GameConfigFolder .. "MenuConfig.ini")
	if menuConfig then
		Menu.Pos.X = Config.getNumber(menuConfig, "MENU", "MenuPosX", 100)
		Menu.Pos.Y = Config.getNumber(menuConfig, "MENU", "MenuPosY", 200)
		Menu.Text = Game.Transitions.loadFont(menuConfig, "MENUFONT")
		Menu.TextHighlight = Game.Transitions.loadFont(menuConfig, "MENUFONTHIGHLIGHT")
	end

	Menu.MenuItems = {}
	local fileName = G.GameConfigFolder .. "MenuDefinition.txt"
	if Utils.fileExists(fileName) then
		for line in love.filesystem.lines(fileName) do
			if line:match("%S") then
				local itemNumber, entry, parentItem, itemLevel = line:match("^%s*(%d+)%s*,%s*(.-)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
				if itemNumber then
					local number = tonumber(itemNumber) + 1
					Menu.MenuItems[number] = Menu.MenuItems[number] or { ChildItems = {} }
					Menu.MenuItems[number].Entry = entry
					Menu.MenuItems[number].ParentItem = tonumber(parentItem)
					Menu.MenuItems[number].Level = tonumber(itemLevel)
					if Menu.MenuItems[number].Level > 0 then
						local parent = Menu.MenuItems[Menu.MenuItems[number].ParentItem + 1]
						if parent then
							parent.ChildItems[#parent.ChildItems + 1] = number
						end
					end
				end
			end
		end
	end

	-- the video entries in MenuDefinition.txt ("Video" / "Fullscreen" /
	-- "Resolution", LARC additions with no C++ counterpart) carry runtime
	-- state: fill in the current values when Video is registered
	local Video = Game.Video
	if Video then
		for index = 1, #Menu.MenuItems do
			local item = Menu.MenuItems[index]
			if item then
				if item.Entry == "Fullscreen" then
					item.Entry = "Fullscreen: " .. (Video.Fullscreen and "Yes" or "No")
				elseif item.Entry == "Resolution" then
					item.Entry = Video.resolutionLabel()
				end
			end
		end
	end
end

function Menu.DrawItem(itemNumber, y)
	local item = Menu.MenuItems[itemNumber + 1]
	local font = (itemNumber == Menu.HighLightedItem) and Menu.TextHighlight or Menu.Text
	if item and font then
		love.graphics.setFont(font.font)
		love.graphics.setColor(font.r, font.g, font.b)
		love.graphics.print(item.Entry, Menu.Pos.X, y)
	end
end

function Menu.Show()
	Game.Level.PauseBackgroundMusic()

	local font = Menu.Text
	local fontHeight = font and font.font:getHeight() or 30
	local tempMenuPosY = Menu.Pos.Y

	for itemNumber = 0, #Menu.MenuItems - 1 do
		local item = Menu.MenuItems[itemNumber + 1]
		if item and item.Level == Menu.MenuSelectedLevel then
			if item.Level == 0 then
				Menu.DrawItem(itemNumber, tempMenuPosY)
				tempMenuPosY = tempMenuPosY + fontHeight
			else
				local selectedItem = Menu.MenuItems[Menu.SelectedItem + 1]
				for _, childItemNumber in ipairs(selectedItem.ChildItems) do
					if itemNumber + 1 == childItemNumber then
						Menu.DrawItem(itemNumber, tempMenuPosY)
						tempMenuPosY = tempMenuPosY + fontHeight
						break
					end
				end
			end
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

function Menu.ExecuteChoice()
	local item = Menu.MenuItems[Menu.HighLightedItem + 1]
	local Video = Game.Video

	if item and item.Entry == "Exit Game" then
		G.QuitGameFlag = true
		love.event.quit()
	elseif item and item.Entry == "Toogle Mouse / GameController" then
		G.GameControllerFlag = not G.GameControllerFlag
	elseif item and Video then
		local entry = item.Entry
		if entry:match("^Fullscreen: ") then
			Video.toggleFullscreen()
			item.Entry = "Fullscreen: " .. (Video.Fullscreen and "Yes" or "No")
		elseif entry:match("^Resolution: ") then
			Video.cycleResolution()
			item.Entry = Video.resolutionLabel()
		end
	end
end

function Menu.ItemDown()
	local highlighted = Menu.MenuItems[Menu.HighLightedItem + 1]
	if highlighted.Level == 0 then
		local nextItem = Menu.MenuItems[Menu.HighLightedItem + 2]
		if nextItem and nextItem.Level == 0 then
			Menu.HighLightedItem = Menu.HighLightedItem + 1
		end
	else
		-- submenu: step to the next child of the selected item in child list
		-- order (LARC: replaces the C++'s positional ++ walk, which assumes
		-- all siblings are contiguous in the item list)
		local children = Menu.MenuItems[Menu.SelectedItem + 1].ChildItems
		for index, child in ipairs(children) do
			if child == Menu.HighLightedItem + 1 then
				if index < #children then
					Menu.HighLightedItem = children[index + 1] - 1
				end
				break
			end
		end
	end
end

function Menu.ItemUp()
	local highlighted = Menu.MenuItems[Menu.HighLightedItem + 1]
	if highlighted.Level == 0 and Menu.HighLightedItem > 0 then
		local prevItem = Menu.MenuItems[Menu.HighLightedItem]
		if prevItem and prevItem.Level == 0 then
			Menu.HighLightedItem = Menu.HighLightedItem - 1
		end
	elseif highlighted.Level > 0 then
		-- see ItemDown: walk the child list instead of item positions
		local children = Menu.MenuItems[Menu.SelectedItem + 1].ChildItems
		for index, child in ipairs(children) do
			if child == Menu.HighLightedItem + 1 then
				if index > 1 then
					Menu.HighLightedItem = children[index - 1] - 1
				end
				break
			end
		end
	end
end

function Menu.ItemSelect()
	local highlighted = Menu.MenuItems[Menu.HighLightedItem + 1]
	if #highlighted.ChildItems > 0 then
		Menu.SelectedItem = Menu.HighLightedItem
		Menu.HighLightedItem = highlighted.ChildItems[1] - 1
		Menu.MenuSelectedLevel = Menu.MenuSelectedLevel + 1
	else
		Menu.ExecuteChoice()
	end
end

function Menu.LevelUp()
	if Menu.MenuSelectedLevel == 0 then
		G.GamePausedFlag = not G.GamePausedFlag
		if not G.GamePausedFlag then
			Game.Level.RestartBackgroundMusic()
		end
	elseif Menu.MenuSelectedLevel == 1 then
		Menu.MenuSelectedLevel = 0
		Menu.HighLightedItem = Menu.SelectedItem
	else
		local highlighted = Menu.MenuItems[Menu.HighLightedItem + 1]
		local parent = Menu.MenuItems[highlighted.ParentItem + 1]
		Menu.SelectedItem = parent.ParentItem
		Menu.HighLightedItem = Menu.MenuItems[Menu.SelectedItem + 1].ChildItems[1] - 1
		Menu.MenuSelectedLevel = Menu.MenuSelectedLevel - 1
	end
end

Game.Menu = Menu
return Menu
