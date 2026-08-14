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

	it("keeps lag compensation smaller than the punch range itself", function()
		-- The allowance is meant to cover the gap between where a running
		-- target is drawn and where it is. Letting it grow past the reach
		-- would turn the punch into something you could land from clean across
		-- the gap, which is the failure mode the tuning has to stay clear of.
		expect(Config.PunchMaxCompensationStuds >= 0).toBe(true)
		expect(Config.PunchMaxCompensationStuds < Config.PunchRange).toBe(true)
	end)

	it("compensates for a plausible fraction of a second", function()
		-- Negative would push targets away; a large value would hand a sprinting
		-- target several extra studs of reach.
		expect(Config.PunchLagCompensationSeconds >= 0).toBe(true)
		expect(Config.PunchLagCompensationSeconds <= 0.5).toBe(true)
	end)

	it("states the parry animation as an asset id, or as no animation at all", function()
		-- Same failure mode as the punch animation: a malformed id loads a
		-- track that plays nothing, so the "Hold" marker never arrives and the
		-- parry winds up forever without ever protecting anyone. Empty is the
		-- supported "no animation" state, which ParryController handles by
		-- reaching the guard on the key press.
		expect(Config.ParryAnimationId).toEqual(expect.any("string"))
		if Config.ParryAnimationId ~= "" then
			expect(string.match(Config.ParryAnimationId, "^rbxassetid://%d+$")).never.toBeNil()
		end
	end)

	it("names a hold marker for ParryController to bind", function()
		expect(Config.ParryHoldMarkerName).toEqual(expect.any("string"))
		expect(#Config.ParryHoldMarkerName > 0).toBe(true)
	end)

	it("ships the agreed parry numbers", function()
		-- Pinned deliberately. Both were settled decisions rather than tuning
		-- knobs, and each has a rule attached that is not obvious from the
		-- number alone: the arc is the forward hemisphere, and the slowdown is
		-- half of walking. Changing one should be a decision, not a diff nobody
		-- noticed.
		expect(Config.ParryWalkSpeed).toBe(8)
		expect(Config.ParryMinFacingDot).toBe(0)
	end)

	it("guards at least the forward hemisphere and never the back", function()
		-- Below 0 the guard would start covering directions behind the
		-- defender, which is the "invulnerable from everywhere" failure the
		-- feature is defined against. Above 1 nothing could ever be parried.
		expect(Config.ParryMinFacingDot >= 0).toBe(true)
		expect(Config.ParryMinFacingDot <= 1).toBe(true)
	end)

	it("keeps sprinting faster than walking, and walking faster than guarding", function()
		-- The precedence RunningController applies, asserted as an ordering so
		-- retuning any one of the three cannot silently invert it. A parry speed
		-- at or above the walking speed would make guarding strictly better than
		-- not guarding; one at or below zero would root the player in place.
		expect(Config.ParryWalkSpeed > 0).toBe(true)
		expect(Config.ParryWalkSpeed < Config.NormalWalkSpeed).toBe(true)
		expect(Config.NormalWalkSpeed < Config.SprintWalkSpeed).toBe(true)
	end)
end)
