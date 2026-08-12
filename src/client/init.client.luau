--!strict
--[[
	Client entry point.

	Rojo turns this file into StarterPlayer.StarterPlayerScripts.Client, which
	Roblox copies into every player's PlayerScripts. Same rule as the server
	entry point: keep it short, put logic in a controller.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bootstrap = require(Shared.Runtime.Bootstrap)
local Logger = require(Shared.Util.Logger)

local log = Logger.forScope("Client")

Bootstrap.run(script:WaitForChild("Controllers"))

log.info("boot complete")
