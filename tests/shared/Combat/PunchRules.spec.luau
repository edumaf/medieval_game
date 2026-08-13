--!strict
--[[
	Covers the pure punch arithmetic CombatService and PunchController both
	rely on. No characters or Humanoids here — the Roblox side (actually
	landing a hit on another player) is a Studio check, see docs/testing.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local PunchRules = require(ReplicatedStorage.Shared.Combat.PunchRules)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local COOLDOWN = 0.6
local RANGE = 7
local MIN_FACING_DOT = 0.5

describe("PunchRules.canPunch", function()
	it("allows a player who has never punched", function()
		expect(PunchRules.canPunch(nil, 100, COOLDOWN)).toBe(true)
	end)

	it("blocks a second punch inside the cooldown", function()
		expect(PunchRules.canPunch(100, 100.3, COOLDOWN)).toBe(false)
	end)

	it("allows a punch exactly on the cooldown boundary", function()
		-- Deliberately uses 0.5 rather than COOLDOWN. 100.6 - 100 evaluates to
		-- 0.5999999999999943, so asserting the boundary with 0.6 tests IEEE 754
		-- rounding rather than the >= in canPunch. Halves are exactly
		-- representable, so this asserts the intended semantics.
		--
		-- The imprecision is harmless in the game: os.clock() never lands
		-- exactly on a boundary, and being ready a picosecond late is not
		-- something a player can feel.
		expect(PunchRules.canPunch(100, 100.5, 0.5)).toBe(true)
	end)

	it("blocks a punch a hair before the cooldown boundary", function()
		expect(PunchRules.canPunch(100, 100.499, 0.5)).toBe(false)
	end)

	it("allows a punch well after the cooldown", function()
		expect(PunchRules.canPunch(100, 105, COOLDOWN)).toBe(true)
	end)

	it("blocks a repeat in the same tick", function()
		expect(PunchRules.canPunch(100, 100, COOLDOWN)).toBe(false)
	end)

	it("does not lock a player out if the clock goes backwards", function()
		-- Better to allow an extra punch than to leave someone unable to
		-- fight for the rest of the round.
		expect(PunchRules.canPunch(100, 99, COOLDOWN)).toBe(true)
	end)
end)

describe("PunchRules.isInReach", function()
	it("accepts a target dead ahead and well inside range", function()
		expect(PunchRules.isInReach({ distance = 3, facingDot = 1 }, RANGE, MIN_FACING_DOT)).toBe(
			true
		)
	end)

	it("accepts a target exactly at maximum range", function()
		expect(PunchRules.isInReach({ distance = RANGE, facingDot = 1 }, RANGE, MIN_FACING_DOT)).toBe(
			true
		)
	end)

	it("rejects a target just out of range", function()
		expect(
			PunchRules.isInReach({ distance = RANGE + 0.1, facingDot = 1 }, RANGE, MIN_FACING_DOT)
		).toBe(false)
	end)

	it("accepts a target exactly on the edge of the cone", function()
		expect(
			PunchRules.isInReach(
				{ distance = 3, facingDot = MIN_FACING_DOT },
				RANGE,
				MIN_FACING_DOT
			)
		).toBe(true)
	end)

	it("rejects a target off to the side, outside the cone", function()
		expect(PunchRules.isInReach({ distance = 3, facingDot = 0 }, RANGE, MIN_FACING_DOT)).toBe(
			false
		)
	end)

	it("rejects a target directly behind, however close", function()
		expect(PunchRules.isInReach({ distance = 1, facingDot = -1 }, RANGE, MIN_FACING_DOT)).toBe(
			false
		)
	end)
end)

describe("PunchRules.selectTargetIndex", function()
	it("returns nil when nobody else is around", function()
		expect(PunchRules.selectTargetIndex({}, RANGE, MIN_FACING_DOT)).toBeNil()
	end)

	it("returns nil when everyone is out of reach", function()
		local candidates = {
			{ distance = 20, facingDot = 1 },
			{ distance = 2, facingDot = -1 },
		}
		expect(PunchRules.selectTargetIndex(candidates, RANGE, MIN_FACING_DOT)).toBeNil()
	end)

	it("picks the only valid target", function()
		local candidates = {
			{ distance = 20, facingDot = 1 },
			{ distance = 3, facingDot = 1 },
		}
		expect(PunchRules.selectTargetIndex(candidates, RANGE, MIN_FACING_DOT)).toBe(2)
	end)

	it("picks the nearest when several are in reach", function()
		local candidates = {
			{ distance = 5, facingDot = 1 },
			{ distance = 2, facingDot = 1 },
			{ distance = 4, facingDot = 1 },
		}
		expect(PunchRules.selectTargetIndex(candidates, RANGE, MIN_FACING_DOT)).toBe(2)
	end)

	it("ignores a nearer target that is outside the cone", function()
		-- Somebody standing behind you must not steal the hit from the person
		-- you are actually facing.
		local candidates = {
			{ distance = 1, facingDot = -1 },
			{ distance = 4, facingDot = 1 },
		}
		expect(PunchRules.selectTargetIndex(candidates, RANGE, MIN_FACING_DOT)).toBe(2)
	end)

	it("keeps the first of two equally close targets", function()
		local candidates = {
			{ distance = 3, facingDot = 1 },
			{ distance = 3, facingDot = 1 },
		}
		expect(PunchRules.selectTargetIndex(candidates, RANGE, MIN_FACING_DOT)).toBe(1)
	end)
end)
