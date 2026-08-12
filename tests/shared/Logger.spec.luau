--!strict
--[[
	Proves the shared utility layer is reachable from a test and that Logger's
	public shape is what every module depends on.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Shared.Util.Logger", function()
	it("returns debug, info and warn for a scope", function()
		local log = Logger.forScope("SpecScope")

		expect(log.debug).toEqual(expect.any("function"))
		expect(log.info).toEqual(expect.any("function"))
		expect(log.warn).toEqual(expect.any("function"))
	end)

	it("gives each scope its own logger", function()
		expect(Logger.forScope("A")).never.toBe(Logger.forScope("B"))
	end)
end)
