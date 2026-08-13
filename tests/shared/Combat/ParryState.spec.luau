--!strict
--[[
	Covers the parry phases and the direction test that ParryController and
	ParryService both rely on. No characters, Humanoids or animations here — the
	Roblox side (the Q key, the Hold marker, the frozen pose, and a punch
	actually being stopped between two players) is a Studio check, see
	docs/testing.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local ParryState = require(ReplicatedStorage.Shared.Combat.ParryState)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- The shipped arc: the forward hemisphere.
local MIN_FACING_DOT = 0

-- Attack directions as the defender sees them, in the units ParryState works
-- in: the dot of the defender's look vector with the direction the attacker is
-- in. The diagonals are 45 degrees off the defender's facing.
--
-- Left and right collapse to the same number on purpose — a dot product is
-- symmetric about the look axis, so "front-left" and "front-right" are
-- genuinely the same test. They are named separately because the feature is
-- specified in those terms, and a reader should be able to find the case they
-- are looking for.
local DIAGONAL = math.cos(math.rad(45))

local FRONT = 1
local FRONT_LEFT = DIAGONAL
local FRONT_RIGHT = DIAGONAL
local BESIDE = 0
local BACK_LEFT = -DIAGONAL
local BACK_RIGHT = -DIAGONAL
local BACK = -1

--[[
	A state that has been driven all the way to a held guard, the way the
	controller drives it: press, then the animation's Hold marker.
]]
local function active()
	return ParryState.apply(ParryState.apply(ParryState.initial(), "begin"), "hold")
end

local function attempting()
	return ParryState.apply(ParryState.initial(), "begin")
end

describe("ParryState phases", function()
	it("starts idle", function()
		local state = ParryState.initial()

		expect(state.phase).toBe("idle")
		expect(ParryState.isEngaged(state)).toBe(false)
		expect(ParryState.isAttempting(state)).toBe(false)
		expect(ParryState.isActive(state)).toBe(false)
	end)

	it("enters the wind-up when the key goes down", function()
		local state = attempting()

		expect(state.phase).toBe("attempting")
		expect(ParryState.isAttempting(state)).toBe(true)
		expect(ParryState.isActive(state)).toBe(false)
		-- Slowed and unable to punch from the press, not from the marker.
		expect(ParryState.isEngaged(state)).toBe(true)
	end)

	it("raises the guard when the animation reaches Hold", function()
		local state = active()

		expect(state.phase).toBe("active")
		expect(ParryState.isActive(state)).toBe(true)
		expect(ParryState.isAttempting(state)).toBe(false)
		expect(ParryState.isEngaged(state)).toBe(true)
	end)

	it("returns to idle when the key is released", function()
		local state = ParryState.apply(active(), "end")

		expect(state.phase).toBe("idle")
		expect(ParryState.isEngaged(state)).toBe(false)
	end)
end)

describe("ParryState invalid and duplicate transitions", function()
	it("refuses to raise a guard that was never asked for", function()
		-- The transition a modified client would send to skip the wind-up
		-- entirely. Without an attempt behind it, it must do nothing at all.
		local state = ParryState.apply(ParryState.initial(), "hold")

		expect(state.phase).toBe("idle")
		expect(ParryState.isActive(state)).toBe(false)
	end)

	it("ignores a repeated press while winding up", function()
		local once = attempting()
		local twice = ParryState.apply(once, "begin")

		expect(twice.phase).toBe("attempting")
		expect(twice).toEqual(once)
	end)

	it("ignores a repeated press while the guard is held", function()
		-- Mashing Q, or a platform that repeats InputBegan while a key is down,
		-- must not drop a raised guard back to the wind-up.
		local once = active()
		local twice = ParryState.apply(once, "begin")

		expect(twice.phase).toBe("active")
		expect(twice).toEqual(once)
	end)

	it("ignores a repeated Hold marker", function()
		local once = active()
		local twice = ParryState.apply(once, "hold")

		expect(twice.phase).toBe("active")
		expect(twice).toEqual(once)
	end)

	it("ignores a release from idle", function()
		local state = ParryState.apply(ParryState.initial(), "end")

		expect(state.phase).toBe("idle")
	end)

	it("cancels a wind-up without ever passing through the guard", function()
		-- Q released before Hold. The player must never have been protected.
		local cancelled = ParryState.apply(attempting(), "end")

		expect(cancelled.phase).toBe("idle")
		expect(ParryState.isProtectedFrom(cancelled, FRONT, MIN_FACING_DOT)).toBe(false)
	end)

	it("ignores a Hold that arrives after the release", function()
		-- The marker and the key release race on a real client. A marker
		-- landing after the parry ended must not resurrect it.
		local state = ParryState.apply(ParryState.apply(attempting(), "end"), "hold")

		expect(state.phase).toBe("idle")
	end)

	it("survives a long run of out-of-order transitions", function()
		-- Roughly what a client spamming the remote would produce. The only
		-- path to a guard is begin -> hold, and nothing else along the way may
		-- open one.
		local state = ParryState.initial()

		state = ParryState.apply(state, "hold")
		expect(state.phase).toBe("idle")

		state = ParryState.apply(state, "end")
		expect(state.phase).toBe("idle")

		state = ParryState.apply(state, "hold")
		expect(state.phase).toBe("idle")

		state = ParryState.apply(state, "begin")
		state = ParryState.apply(state, "begin")
		expect(state.phase).toBe("attempting")

		state = ParryState.apply(state, "hold")
		state = ParryState.apply(state, "hold")
		expect(state.phase).toBe("active")

		state = ParryState.apply(state, "end")
		expect(state.phase).toBe("idle")
	end)
end)

describe("ParryState.isTransition", function()
	it("accepts exactly the three declared transitions", function()
		expect(ParryState.isTransition("begin")).toBe(true)
		expect(ParryState.isTransition("hold")).toBe(true)
		expect(ParryState.isTransition("end")).toBe(true)
	end)

	it("rejects anything else a client could send", function()
		-- The whole validation surface of ParryStateRequest. Everything a
		-- modified client can put on the wire has to fall out here.
		expect(ParryState.isTransition(nil)).toBe(false)
		expect(ParryState.isTransition("")).toBe(false)
		expect(ParryState.isTransition("BEGIN")).toBe(false)
		expect(ParryState.isTransition("active")).toBe(false)
		expect(ParryState.isTransition(true)).toBe(false)
		expect(ParryState.isTransition(1)).toBe(false)
		expect(ParryState.isTransition({})).toBe(false)
		expect(ParryState.isTransition(Vector3.new())).toBe(false)
	end)
end)

describe("ParryState.isProtectedFrom, guard held", function()
	it("stops an attacker directly in front", function()
		expect(ParryState.isProtectedFrom(active(), FRONT, MIN_FACING_DOT)).toBe(true)
	end)

	it("stops an attacker to the front-left", function()
		expect(ParryState.isProtectedFrom(active(), FRONT_LEFT, MIN_FACING_DOT)).toBe(true)
	end)

	it("stops an attacker to the front-right", function()
		expect(ParryState.isProtectedFrom(active(), FRONT_RIGHT, MIN_FACING_DOT)).toBe(true)
	end)

	it("stops an attacker exactly beside the defender", function()
		-- The hemisphere boundary. The comparison is >=, matching
		-- PunchRules.isInReach, so exactly 90 degrees is covered.
		expect(ParryState.isProtectedFrom(active(), BESIDE, MIN_FACING_DOT)).toBe(true)
	end)

	it("does not stop an attacker directly behind", function()
		expect(ParryState.isProtectedFrom(active(), BACK, MIN_FACING_DOT)).toBe(false)
	end)

	it("does not stop an attacker to the back-left", function()
		expect(ParryState.isProtectedFrom(active(), BACK_LEFT, MIN_FACING_DOT)).toBe(false)
	end)

	it("does not stop an attacker to the back-right", function()
		expect(ParryState.isProtectedFrom(active(), BACK_RIGHT, MIN_FACING_DOT)).toBe(false)
	end)

	it("does not stop an attacker a hair behind the boundary", function()
		expect(ParryState.isProtectedFrom(active(), -0.001, MIN_FACING_DOT)).toBe(false)
	end)

	it("is not 360-degree invulnerability", function()
		-- The rear half has to stay open, or the parry stops being directional.
		local openings = 0
		for step = 0, 359 do
			local dot = math.cos(math.rad(step))
			if not ParryState.isProtectedFrom(active(), dot, MIN_FACING_DOT) then
				openings += 1
			end
		end

		expect(openings > 0).toBe(true)
	end)
end)

describe("ParryState.isProtectedFrom, no guard held", function()
	it("protects nothing while idle, from any direction", function()
		local idle = ParryState.initial()

		for _, dot in { FRONT, FRONT_LEFT, FRONT_RIGHT, BESIDE, BACK_LEFT, BACK_RIGHT, BACK } do
			expect(ParryState.isProtectedFrom(idle, dot, MIN_FACING_DOT)).toBe(false)
		end
	end)

	it("protects nothing during the wind-up, from any direction", function()
		-- The distinction the phases exist for: Q is down, the player is slowed,
		-- and a punch from dead ahead still lands.
		local windingUp = attempting()

		for _, dot in { FRONT, FRONT_LEFT, FRONT_RIGHT, BESIDE, BACK_LEFT, BACK_RIGHT, BACK } do
			expect(ParryState.isProtectedFrom(windingUp, dot, MIN_FACING_DOT)).toBe(false)
		end
	end)
end)

describe("ParryState.isProtectedFrom, other arcs", function()
	it("narrows to the punch's own cone when asked to", function()
		-- The threshold is a tunable dot product, not a hard-coded hemisphere.
		-- At 0.5 the guard covers the same 120 degrees the punch does.
		local state = active()

		expect(ParryState.isProtectedFrom(state, FRONT, 0.5)).toBe(true)
		expect(ParryState.isProtectedFrom(state, DIAGONAL, 0.5)).toBe(true)
		expect(ParryState.isProtectedFrom(state, BESIDE, 0.5)).toBe(false)
	end)
end)
