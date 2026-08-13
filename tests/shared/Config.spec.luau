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

	it("states the punch animation as an asset id, or as no animation at all", function()
		-- A malformed id is silent in game: the track loads, plays nothing,
		-- and the "Hit" marker never arrives, so punches simply stop landing.
		-- Empty is the supported "no animation" state, which PunchController
		-- handles by reporting the hit on the click.
		expect(Config.PunchAnimationId).toEqual(expect.any("string"))
		if Config.PunchAnimationId ~= "" then
			expect(string.match(Config.PunchAnimationId, "^rbxassetid://%d+$")).never.toBeNil()
		end
	end)

	it("names a hit marker for PunchController to bind", function()
		expect(Config.PunchHitMarkerName).toEqual(expect.any("string"))
		expect(#Config.PunchHitMarkerName > 0).toBe(true)
	end)
end)
