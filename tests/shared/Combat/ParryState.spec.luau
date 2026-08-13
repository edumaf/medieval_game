--!strict
--[[
	Covers the parry phases, the maximum hold, and the direction arithmetic that
	ParryController and ParryService both rely on. No characters, Humanoids or
	animations here — the Roblox side (the Q key, the Hold marker, the frozen
	pose, and a punch actually being stopped between two players) is a Studio
	check, see docs/testing.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local ParryState = require(ReplicatedStorage.Shared.Combat.ParryState)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- The shipped arc: the forward hemisphere.
local MIN_FACING_DOT = 0

-- The shipped ceiling on one guard's lifetime.
local MAX_HOLD = 5

-- An arbitrary clock reading to build states at. Nothing depends on its value;
-- only differences from it matter.
local T0 = 1000

-- Attack directions as the defender sees them, in the units ParryState works
-- in: the dot of the defender's look vector with the direction the attacker is
-- in. The diagonals are 45 degrees off the defender's facing.
--
-- Left and right collapse to the same number on purpose — a dot product is
-- symmetric about the look axis, so "front-left" and "front-right" are
-- genuinely the same test at this level. They are named separately because the
-- feature is specified in those terms, and because the geometry tests further
-- down do tell them apart.
local DIAGONAL = math.cos(math.rad(45))

local FRONT = 1
local FRONT_LEFT = DIAGONAL
local FRONT_RIGHT = DIAGONAL
local BESIDE = 0
local BACK_LEFT = -DIAGONAL
local BACK_RIGHT = -DIAGONAL
local BACK = -1

--[[
	A state driven all the way to a raised guard, the way the controller drives
	it: press, then the animation's Hold marker.
]]
local function active()
	return ParryState.apply(ParryState.apply(ParryState.initial(), "begin", T0), "hold", T0)
end

local function attempting()
	return ParryState.apply(ParryState.initial(), "begin", T0)
end

--[[
	Protection for a guard raised at T0, judged `elapsed` seconds later.
]]
local function protectedAfter(elapsed: number, dot: number): boolean
	return ParryState.isProtectedFrom(active(), dot, MIN_FACING_DOT, T0 + elapsed, MAX_HOLD)
end

describe("ParryState phases", function()
	it("starts idle", function()
		local state = ParryState.initial()

		expect(state.phase).toBe("idle")
		expect(state.activatedAt).toBeNil()
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

	it("does not stamp an activation time before the guard is up", function()
		expect(attempting().activatedAt).toBeNil()
	end)

	it("raises the guard when the animation reaches Hold", function()
		local state = active()

		expect(state.phase).toBe("active")
		expect(state.activatedAt).toBe(T0)
		expect(ParryState.isActive(state)).toBe(true)
		expect(ParryState.isAttempting(state)).toBe(false)
		expect(ParryState.isEngaged(state)).toBe(true)
	end)

	it("returns to idle when the key is released", function()
		local state = ParryState.apply(active(), "end", T0 + 1)

		expect(state.phase).toBe("idle")
		expect(state.activatedAt).toBeNil()
		expect(ParryState.isEngaged(state)).toBe(false)
	end)
end)

describe("ParryState invalid and duplicate transitions", function()
	it("refuses to raise a guard that was never asked for", function()
		-- The transition a modified client would send to skip the wind-up
		-- entirely. Without an attempt behind it, it must do nothing at all.
		local state = ParryState.apply(ParryState.initial(), "hold", T0)

		expect(state.phase).toBe("idle")
		expect(ParryState.isActive(state)).toBe(false)
	end)

	it("ignores a repeated press while winding up", function()
		local once = attempting()
		local twice = ParryState.apply(once, "begin", T0 + 0.01)

		expect(twice.phase).toBe("attempting")
		expect(twice).toEqual(once)
	end)

	it("keeps a repeated press idempotent however fast it arrives", function()
		-- There is no rate limiter on the phase, by design: a valid transition
		-- must never be dropped in a way that leaves the client believing it is
		-- protected while the server disagrees. Repeats are made harmless here,
		-- in the state machine, rather than by discarding messages.
		local state = attempting()
		for step = 1, 50 do
			state = ParryState.apply(state, "begin", T0 + step * 0.001)
		end

		expect(state.phase).toBe("attempting")
		expect(state).toEqual(attempting())
	end)

	it("ignores a repeated press while the guard is held", function()
		-- Mashing Q, or a platform that repeats InputBegan while a key is down,
		-- must not drop a raised guard back to the wind-up.
		local once = active()
		local twice = ParryState.apply(once, "begin", T0 + 1)

		expect(twice.phase).toBe("active")
		expect(twice).toEqual(once)
	end)

	it("does not restart the hold clock on a repeated press", function()
		-- Otherwise a client could keep a guard alive past the maximum hold
		-- simply by re-sending "begin".
		local refreshed = ParryState.apply(active(), "begin", T0 + 4)

		expect(refreshed.activatedAt).toBe(T0)
		expect(ParryState.isExpired(refreshed, T0 + MAX_HOLD + 1, MAX_HOLD)).toBe(true)
	end)

	it("does not restart the hold clock on a repeated Hold marker", function()
		local refreshed = ParryState.apply(active(), "hold", T0 + 4)

		expect(refreshed.activatedAt).toBe(T0)
		expect(refreshed).toEqual(active())
	end)

	it("ignores a release from idle", function()
		local state = ParryState.apply(ParryState.initial(), "end", T0)

		expect(state.phase).toBe("idle")
	end)

	it("cancels a wind-up without ever passing through the guard", function()
		-- Q released before Hold. The player must never have been protected.
		local cancelled = ParryState.apply(attempting(), "end", T0 + 0.1)

		expect(cancelled.phase).toBe("idle")
		expect(
			ParryState.isProtectedFrom(cancelled, FRONT, MIN_FACING_DOT, T0 + 0.1, MAX_HOLD)
		).toBe(false)
	end)

	it("ignores a Hold that arrives after the release", function()
		-- The marker and the key release race on a real client. A marker landing
		-- after the parry ended must not resurrect it.
		local ended = ParryState.apply(attempting(), "end", T0 + 0.1)
		local state = ParryState.apply(ended, "hold", T0 + 0.2)

		expect(state.phase).toBe("idle")
		expect(state.activatedAt).toBeNil()
	end)

	it("survives a long run of out-of-order transitions", function()
		-- Roughly what a client spamming the remote would produce. The only path
		-- to a guard is begin -> hold, and nothing else along the way may open
		-- one.
		local state = ParryState.initial()

		state = ParryState.apply(state, "hold", T0)
		expect(state.phase).toBe("idle")

		state = ParryState.apply(state, "end", T0)
		expect(state.phase).toBe("idle")

		state = ParryState.apply(state, "hold", T0)
		expect(state.phase).toBe("idle")

		state = ParryState.apply(state, "begin", T0)
		state = ParryState.apply(state, "begin", T0)
		expect(state.phase).toBe("attempting")

		state = ParryState.apply(state, "hold", T0)
		state = ParryState.apply(state, "hold", T0)
		expect(state.phase).toBe("active")

		state = ParryState.apply(state, "end", T0)
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

describe("ParryState.isExpired", function()
	it("does not expire a guard that has just gone up", function()
		expect(ParryState.isExpired(active(), T0, MAX_HOLD)).toBe(false)
	end)

	it("does not expire a guard inside its allowance", function()
		expect(ParryState.isExpired(active(), T0 + MAX_HOLD - 0.5, MAX_HOLD)).toBe(false)
	end)

	it("does not expire a guard exactly on the boundary", function()
		-- The comparison is strictly greater than, so the full allowance is
		-- honoured rather than cut a moment short.
		expect(ParryState.isExpired(active(), T0 + MAX_HOLD, MAX_HOLD)).toBe(false)
	end)

	it("expires a guard held past its allowance", function()
		expect(ParryState.isExpired(active(), T0 + MAX_HOLD + 0.001, MAX_HOLD)).toBe(true)
	end)

	it("expires a guard held far past its allowance", function()
		-- The case this exists for: a client that sends begin and hold and then
		-- simply never sends end.
		expect(ParryState.isExpired(active(), T0 + 3600, MAX_HOLD)).toBe(true)
	end)

	it("never expires a phase that has no guard up", function()
		expect(ParryState.isExpired(ParryState.initial(), T0 + 3600, MAX_HOLD)).toBe(false)
		expect(ParryState.isExpired(attempting(), T0 + 3600, MAX_HOLD)).toBe(false)
	end)

	it("does not expire a guard if the clock went backwards", function()
		-- Better to leave a guard up than to silently take away protection a
		-- player is entitled to, which is the direction PunchRules.canPunch
		-- errs in too.
		expect(ParryState.isExpired(active(), T0 - 10, MAX_HOLD)).toBe(false)
	end)
end)

describe("ParryState.isProtectedFrom, guard held", function()
	it("stops an attacker directly in front", function()
		expect(protectedAfter(0, FRONT)).toBe(true)
	end)

	it("stops an attacker to the front-left", function()
		expect(protectedAfter(0, FRONT_LEFT)).toBe(true)
	end)

	it("stops an attacker to the front-right", function()
		expect(protectedAfter(0, FRONT_RIGHT)).toBe(true)
	end)

	it("stops an attacker exactly beside the defender", function()
		-- The hemisphere boundary. The comparison is >=, matching
		-- PunchRules.isInReach, so exactly 90 degrees is covered.
		expect(protectedAfter(0, BESIDE)).toBe(true)
	end)

	it("does not stop an attacker directly behind", function()
		expect(protectedAfter(0, BACK)).toBe(false)
	end)

	it("does not stop an attacker to the back-left", function()
		expect(protectedAfter(0, BACK_LEFT)).toBe(false)
	end)

	it("does not stop an attacker to the back-right", function()
		expect(protectedAfter(0, BACK_RIGHT)).toBe(false)
	end)

	it("does not stop an attacker a hair behind the boundary", function()
		expect(protectedAfter(0, -0.001)).toBe(false)
	end)

	it("is not 360-degree invulnerability", function()
		-- The rear half has to stay open, or the parry stops being directional.
		local openings = 0
		for step = 0, 359 do
			if not protectedAfter(0, math.cos(math.rad(step))) then
				openings += 1
			end
		end

		expect(openings > 0).toBe(true)
	end)
end)

describe("ParryState.isProtectedFrom, guard expired", function()
	it("stops protecting the front once the guard has outlived its allowance", function()
		expect(protectedAfter(MAX_HOLD - 0.5, FRONT)).toBe(true)
		expect(protectedAfter(MAX_HOLD + 0.5, FRONT)).toBe(false)
	end)

	it("protects nothing at all once expired, from any direction", function()
		for _, dot in { FRONT, FRONT_LEFT, FRONT_RIGHT, BESIDE, BACK_LEFT, BACK_RIGHT, BACK } do
			expect(protectedAfter(MAX_HOLD + 1, dot)).toBe(false)
		end
	end)

	it("cannot be kept alive indefinitely by a client that never releases", function()
		-- The exploit the ceiling exists for, stated as a test: begin, hold, and
		-- then silence forever.
		expect(protectedAfter(60, FRONT)).toBe(false)
		expect(protectedAfter(3600, FRONT)).toBe(false)
	end)
end)

describe("ParryState.isProtectedFrom, no guard held", function()
	it("protects nothing while idle, from any direction", function()
		local idle = ParryState.initial()

		for _, dot in { FRONT, FRONT_LEFT, FRONT_RIGHT, BESIDE, BACK_LEFT, BACK_RIGHT, BACK } do
			expect(ParryState.isProtectedFrom(idle, dot, MIN_FACING_DOT, T0, MAX_HOLD)).toBe(false)
		end
	end)

	it("protects nothing during the wind-up, from any direction", function()
		-- The distinction the phases exist for: Q is down, the player is slowed,
		-- and a punch from dead ahead still lands.
		local windingUp = attempting()

		for _, dot in { FRONT, FRONT_LEFT, FRONT_RIGHT, BESIDE, BACK_LEFT, BACK_RIGHT, BACK } do
			expect(ParryState.isProtectedFrom(windingUp, dot, MIN_FACING_DOT, T0, MAX_HOLD)).toBe(
				false
			)
		end
	end)
end)

describe("ParryState.isProtectedFrom, other arcs", function()
	it("narrows to the punch's own cone when asked to", function()
		-- The threshold is a tunable dot product, not a hard-coded hemisphere.
		-- At 0.5 the guard covers the same 120 degrees the punch does.
		local state = active()

		expect(ParryState.isProtectedFrom(state, FRONT, 0.5, T0, MAX_HOLD)).toBe(true)
		expect(ParryState.isProtectedFrom(state, DIAGONAL, 0.5, T0, MAX_HOLD)).toBe(true)
		expect(ParryState.isProtectedFrom(state, BESIDE, 0.5, T0, MAX_HOLD)).toBe(false)
	end)
end)

describe("ParryState.attackerDot", function()
	-- The defender stands at the origin looking down +Z. Every case below places
	-- the attacker somewhere around them and checks the dot the guard is judged
	-- by. This is the arithmetic that decides who is in front of whom, so the
	-- sign and the subtraction order are what these assertions are really for.
	local LOOK = Vector3.new(0, 0, 1)
	local ORIGIN = Vector3.new(0, 0, 0)

	local function dotFor(attackerPosition: Vector3): number
		return ParryState.attackerDot(LOOK, ORIGIN, attackerPosition)
	end

	it("reads an attacker dead ahead as fully in front", function()
		expect(dotFor(Vector3.new(0, 0, 10))).toBeCloseTo(FRONT, 5)
	end)

	it("reads an attacker directly behind as fully behind", function()
		-- The single most important assertion here: a sign error or a flipped
		-- subtraction would make the guard protect the defender's back.
		expect(dotFor(Vector3.new(0, 0, -10))).toBeCloseTo(BACK, 5)
	end)

	it("reads an attacker to the front-left", function()
		expect(dotFor(Vector3.new(-10, 0, 10))).toBeCloseTo(DIAGONAL, 5)
	end)

	it("reads an attacker to the front-right", function()
		expect(dotFor(Vector3.new(10, 0, 10))).toBeCloseTo(DIAGONAL, 5)
	end)

	it("reads an attacker exactly beside as the boundary", function()
		expect(dotFor(Vector3.new(10, 0, 0))).toBeCloseTo(BESIDE, 5)
		expect(dotFor(Vector3.new(-10, 0, 0))).toBeCloseTo(BESIDE, 5)
	end)

	it("reads an attacker to the back-left", function()
		expect(dotFor(Vector3.new(-10, 0, -10))).toBeCloseTo(-DIAGONAL, 5)
	end)

	it("reads an attacker to the back-right", function()
		expect(dotFor(Vector3.new(10, 0, -10))).toBeCloseTo(-DIAGONAL, 5)
	end)

	it("normalises, so distance does not change the direction", function()
		-- The dot has to describe an angle, not a length, or the guard's arc
		-- would widen and narrow with how far away the attacker stood.
		expect(dotFor(Vector3.new(0, 0, 1))).toBeCloseTo(dotFor(Vector3.new(0, 0, 500)), 5)
		expect(dotFor(Vector3.new(3, 0, 3))).toBeCloseTo(dotFor(Vector3.new(300, 0, 300)), 5)
	end)

	it("ignores height, judging the arc around the defender", function()
		-- An attacker directly overhead has no meaningful horizontal side, but
		-- one in front and slightly above is still in front.
		expect(dotFor(Vector3.new(0, 5, 10)) > 0).toBe(true)
		expect(dotFor(Vector3.new(0, 5, -10)) < 0).toBe(true)
	end)

	it("treats an attacker in the exact same spot as dead ahead", function()
		-- Two characters at one position have no direction between them.
		-- Normalising that would divide by zero; CombatService resolves the same
		-- degenerate case the same way for the punch cone.
		expect(dotFor(ORIGIN)).toBe(1)
	end)

	it("is judged relative to the defender's facing, not a world axis", function()
		-- Same attacker, defender turned around: what was in front becomes
		-- behind. Nothing here may depend on which way is north.
		local attacker = Vector3.new(0, 0, 10)

		expect(ParryState.attackerDot(LOOK, ORIGIN, attacker)).toBeCloseTo(FRONT, 5)
		expect(ParryState.attackerDot(-LOOK, ORIGIN, attacker)).toBeCloseTo(BACK, 5)
	end)

	it("is judged relative to the defender's position, not the origin", function()
		-- Defender standing away from the world origin, attacker just in front
		-- of them. A missing subtraction would read this as behind.
		local defender = Vector3.new(100, 0, 100)

		expect(ParryState.attackerDot(LOOK, defender, Vector3.new(100, 0, 110))).toBeCloseTo(
			FRONT,
			5
		)
		expect(ParryState.attackerDot(LOOK, defender, Vector3.new(100, 0, 90))).toBeCloseTo(BACK, 5)
	end)

	it("feeds isProtectedFrom the answer the guard needs", function()
		-- The two halves joined up, which is all ParryService does.
		local state = active()
		local front = ParryState.attackerDot(LOOK, ORIGIN, Vector3.new(0, 0, 10))
		local behind = ParryState.attackerDot(LOOK, ORIGIN, Vector3.new(0, 0, -10))

		expect(ParryState.isProtectedFrom(state, front, MIN_FACING_DOT, T0, MAX_HOLD)).toBe(true)
		expect(ParryState.isProtectedFrom(state, behind, MIN_FACING_DOT, T0, MAX_HOLD)).toBe(false)
	end)
end)
