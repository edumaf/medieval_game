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
local LAG = 0.15
local MAX_COMPENSATION = 2
local SPRINT = 24
-- Fast enough to be worth compensating, slow enough that the ceiling above
-- does not swallow the result — useful for testing the arithmetic itself
-- rather than the clamp.
local JOG = 8

--[[
	A candidate built the way CombatService builds one: the distance it carries
	is already corrected for replication lag.
]]
local function candidate(distance: number, recedeSpeed: number, facingDot: number)
	return {
		distance = PunchRules.perceivedDistance(distance, recedeSpeed, LAG, MAX_COMPENSATION),
		facingDot = facingDot,
	}
end

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

describe("PunchRules.perceivedDistance", function()
	it("leaves a stationary target exactly where it is", function()
		-- The correction exists for lag on a moving target. A target standing
		-- still is in the same place in every frame of reference, so a
		-- stationary punch must behave precisely as it did before.
		expect(PunchRules.perceivedDistance(6, 0, LAG, MAX_COMPENSATION)).toBe(6)
	end)

	it("does not push a closing target away", function()
		-- A target running at the attacker is drawn further off than it really
		-- is, so the server already sees it closer than the attacker did.
		-- Correcting that direction too would make head-on punches harder to
		-- land than they are today.
		expect(PunchRules.perceivedDistance(6, -SPRINT, LAG, MAX_COMPENSATION)).toBe(6)
	end)

	it("gives a receding target back the ground its copy is behind by", function()
		expect(PunchRules.perceivedDistance(9, JOG, LAG, MAX_COMPENSATION)).toBeCloseTo(
			9 - JOG * LAG,
			5
		)
	end)

	it("scales the allowance with how fast the target is receding", function()
		local slow = PunchRules.perceivedDistance(9, 4, LAG, MAX_COMPENSATION)
		local fast = PunchRules.perceivedDistance(9, JOG, LAG, MAX_COMPENSATION)
		expect(fast < slow).toBe(true)
	end)

	it("caps the allowance at a full sprint", function()
		-- At the shipped sprint speed the real error is around 3.6 studs, more
		-- than the ceiling, so a sprinting target is deliberately given back
		-- only part of it. Reach stays close to what an arm looks like.
		expect(SPRINT * LAG > MAX_COMPENSATION).toBe(true)
		expect(PunchRules.perceivedDistance(9, SPRINT, LAG, MAX_COMPENSATION)).toBe(
			9 - MAX_COMPENSATION
		)
	end)

	it("never hands out more than the stud ceiling", function()
		-- A character that has been launched, or one reporting a nonsense
		-- velocity, must not turn the punch into a ranged attack.
		expect(PunchRules.perceivedDistance(50, 1000, LAG, MAX_COMPENSATION)).toBe(
			50 - MAX_COMPENSATION
		)
	end)

	it("never reports a negative distance", function()
		expect(PunchRules.perceivedDistance(1, SPRINT, LAG, MAX_COMPENSATION)).toBe(0)
	end)

	it("does nothing when compensation is switched off", function()
		expect(PunchRules.perceivedDistance(9, SPRINT, 0, MAX_COMPENSATION)).toBe(9)
	end)
end)

describe("the chase the compensation exists for", function()
	-- Attacker and victim both sprinting the same way, victim ahead and
	-- directly in front. Their separation is constant, but the victim's
	-- replicated copy trails its real position, which is what used to make
	-- these punches miss.

	it("lands a punch on a fleeing victim the attacker saw in range", function()
		-- Sitting just outside reach on the server's fresh view, and inside it
		-- on the screen the attacker was aiming at.
		local chased = candidate(RANGE + 1, SPRINT, 1)
		expect(RANGE + 1 > RANGE).toBe(true)
		expect(PunchRules.isInReach(chased, RANGE, MIN_FACING_DOT)).toBe(true)
	end)

	it("still refuses a victim who is genuinely out of reach", function()
		-- Far enough that even the whole ceiling does not bring it inside.
		local escaped = candidate(RANGE + MAX_COMPENSATION + 2, SPRINT, 1)
		expect(PunchRules.isInReach(escaped, RANGE, MIN_FACING_DOT)).toBe(false)
	end)

	it("does not let the allowance reach around behind the attacker", function()
		-- Distance is corrected; the cone is not. Somebody sprinting away
		-- behind the attacker stays unhittable however fast they run.
		local behind = candidate(3, SPRINT, -1)
		expect(PunchRules.isInReach(behind, RANGE, MIN_FACING_DOT)).toBe(false)
	end)

	it("does not widen the cone for a target off to the side", function()
		local beside = candidate(3, SPRINT, 0)
		expect(PunchRules.isInReach(beside, RANGE, MIN_FACING_DOT)).toBe(false)
	end)

	it("leaves an attacker closing on a stationary victim unchanged", function()
		-- The attacker's own movement is not part of the correction, so this
		-- is the same arithmetic it always was.
		expect(PunchRules.isInReach(candidate(5, 0, 1), RANGE, MIN_FACING_DOT)).toBe(true)
		expect(PunchRules.isInReach(candidate(9, 0, 1), RANGE, MIN_FACING_DOT)).toBe(false)
	end)

	it("picks the target the attacker saw as nearest", function()
		-- A victim sprinting away at 8 studs was drawn nearer than a
		-- stationary bystander at 6.5. The attacker aimed at whichever looked
		-- closest, so that is the one who takes it.
		local candidates = {
			candidate(6.5, 0, 1),
			candidate(8, SPRINT, 1),
		}
		expect(PunchRules.selectTargetIndex(candidates, RANGE, MIN_FACING_DOT)).toBe(2)
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
