--
-- game.lua - shared registry so modules can reference each other without
-- circular require() cycles. Each module registers itself here at load time.
--

local Game = {}

Game.G = require("src/globals")
Game.Config = require("src/config")
Game.Utils = require("src/utils")
Game.Level = require("src/level")

return Game
