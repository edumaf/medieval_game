--!strict
--[[
	Server entry point.

	Rojo turns this file into ServerScriptService.Server. It is the only script
	on the server that runs by itself; everything else is a module started from
	here. Keep it short — logic belongs in a service, not in the entry point.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bootstrap = require(Shared.Runtime.Bootstrap)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)

local log = Logger.forScope("Server")

-- Remotes must exist before any service registers a handler on them, and before
-- the first client asks for one.
Net.build()

Bootstrap.run(script.Services)

log.info("boot complete")
