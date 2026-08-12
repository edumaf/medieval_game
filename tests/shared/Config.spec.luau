--!strict
--[[
	Guards the invariants other systems rely on: Config is immutable, and
	GameVersion stays in a shape the handshake can compare.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Shared.Config", function()
	it("is frozen so no system can mutate shared configuration at runtime", function()
		expect(table.isfrozen(Config)).toBe(true)
	end)

	it("exposes a three-part GameVersion", function()
		expect(Config.GameVersion).toEqual(expect.any("string"))
		expect(string.match(Config.GameVersion, "^%d+%.%d+%.%d+$")).never.toBeNil()
	end)

	it("uses a log level Logger understands", function()
		local allowed = { debug = true, info = true, warn = true }
		expect(allowed[Config.LogLevel]).toBe(true)
	end)
end)
