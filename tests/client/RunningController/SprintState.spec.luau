--!strict
--[[
	Covers the pure movement-intent state RunningController wires up to actual
	input and a Humanoid. No Roblox character or input device involved here —
	see docs/decisions.md for the Studio steps that cover those.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local SprintState =
	require(StarterPlayer.StarterPlayerScripts.Client.Controllers.RunningController.SprintState)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local NORMAL_SPEED = 16
local SPRINT_SPEED = 24
local PARRY_SPEED = 8

--[[
	The speed RunningController would apply for this state, with the shipped
	numbers. Wraps the speed arguments so they do not have to be repeated in
	every assertion.
]]
local function speedOf(state: SprintState.SprintState): number
	return SprintState.walkSpeed(state, NORMAL_SPEED, SPRINT_SPEED, PARRY_SPEED)
end

--[[
	A state with Shift held and stamina exhausted, which is the situation the
	whole lockout exists for.
]]
local function exhaustedAndHolding(): SprintState.SprintState
	return SprintState.withStaminaLocked(SprintState.withInputBegan(SprintState.initial()), true)
end

describe("RunningController.SprintState", function()
	it("starts out neither sprinting nor parrying", function()
		local state = SprintState.initial()

		expect(state.sprintRequested).toBe(false)
		expect(state.parryRequested).toBe(false)
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("requests sprint when Shift begins", function()
		local state = SprintState.withInputBegan(SprintState.initial())

		expect(state.sprintRequested).toBe(true)
		expect(speedOf(state)).toBe(SPRINT_SPEED)
	end)

	it("clears the sprint request when Shift ends", function()
		local sprinting = SprintState.withInputBegan(SprintState.initial())
		local state = SprintState.withInputEnded(sprinting)

		expect(state.sprintRequested).toBe(false)
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("is idempotent for repeated begin events", function()
		local once = SprintState.withInputBegan(SprintState.initial())
		local twice = SprintState.withInputBegan(once)

		expect(twice.sprintRequested).toBe(true)
		expect(twice).toEqual(once)
	end)

	it("is idempotent for repeated end events", function()
		local once = SprintState.withInputEnded(SprintState.initial())
		local twice = SprintState.withInputEnded(once)

		expect(twice.sprintRequested).toBe(false)
		expect(twice).toEqual(once)
	end)

	it("handles alternating begin/end events in sequence", function()
		local state = SprintState.initial()

		state = SprintState.withInputBegan(state)
		expect(state.sprintRequested).toBe(true)

		state = SprintState.withInputEnded(state)
		expect(state.sprintRequested).toBe(false)

		state = SprintState.withInputBegan(state)
		expect(state.sprintRequested).toBe(true)
	end)
end)

describe("RunningController.SprintState, parrying", function()
	it("slows the player while parrying", function()
		local state = SprintState.withParryBegan(SprintState.initial())

		expect(state.parryRequested).toBe(true)
		expect(speedOf(state)).toBe(PARRY_SPEED)
	end)

	it("restores normal speed when the parry ends", function()
		local parrying = SprintState.withParryBegan(SprintState.initial())
		local state = SprintState.withParryEnded(parrying)

		expect(state.parryRequested).toBe(false)
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("is idempotent for repeated parry begins", function()
		local once = SprintState.withParryBegan(SprintState.initial())
		local twice = SprintState.withParryBegan(once)

		expect(twice).toEqual(once)
	end)

	it("is idempotent for repeated parry ends", function()
		local once = SprintState.withParryEnded(SprintState.initial())
		local twice = SprintState.withParryEnded(once)

		expect(twice).toEqual(once)
	end)
end)

describe("RunningController.SprintState, parry against sprint", function()
	it("lets the parry win while both keys are held", function()
		-- Shift + Q walks at the parry speed. A guard you can sprint out of is
		-- not a guard.
		local state = SprintState.withParryBegan(SprintState.withInputBegan(SprintState.initial()))

		expect(state.sprintRequested).toBe(true)
		expect(state.parryRequested).toBe(true)
		expect(speedOf(state)).toBe(PARRY_SPEED)
	end)

	it("wins whichever key was pressed first", function()
		local parryFirst =
			SprintState.withInputBegan(SprintState.withParryBegan(SprintState.initial()))

		expect(speedOf(parryFirst)).toBe(PARRY_SPEED)
	end)

	it("resumes sprinting the moment the parry ends with Shift still held", function()
		-- The reason both intents live in one state: ending a parry must not
		-- strand a player who never released Shift at the walking speed.
		local guarding =
			SprintState.withParryBegan(SprintState.withInputBegan(SprintState.initial()))
		local state = SprintState.withParryEnded(guarding)

		expect(state.sprintRequested).toBe(true)
		expect(speedOf(state)).toBe(SPRINT_SPEED)
	end)

	it("walks normally when the parry ends and Shift was released during it", function()
		local state = SprintState.initial()

		state = SprintState.withInputBegan(state)
		state = SprintState.withParryBegan(state)
		state = SprintState.withInputEnded(state)
		expect(speedOf(state)).toBe(PARRY_SPEED)

		state = SprintState.withParryEnded(state)
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("keeps the parry when Shift is pressed and released underneath it", function()
		local state = SprintState.withParryBegan(SprintState.initial())

		state = SprintState.withInputBegan(state)
		expect(speedOf(state)).toBe(PARRY_SPEED)

		state = SprintState.withInputEnded(state)
		expect(state.parryRequested).toBe(true)
		expect(speedOf(state)).toBe(PARRY_SPEED)
	end)

	it("leaves no modifier behind after a full parry-while-sprinting cycle", function()
		-- The stale-modifier failure this design exists to make impossible: the
		-- speed is recomputed from both intents, never saved and restored.
		local state = SprintState.initial()

		state = SprintState.withInputBegan(state)
		state = SprintState.withParryBegan(state)
		state = SprintState.withParryEnded(state)
		state = SprintState.withInputEnded(state)

		expect(state).toEqual(SprintState.initial())
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)
end)

describe("RunningController.SprintState, stamina against sprint", function()
	it("starts unlocked, so a fresh character can sprint", function()
		expect(SprintState.initial().staminaLocked).toBe(false)
	end)

	it("drops an exhausted sprinter to the walking speed", function()
		-- The reported bug: stamina reached zero and the character kept running.
		local sprinting = SprintState.withInputBegan(SprintState.initial())
		expect(speedOf(sprinting)).toBe(SPRINT_SPEED)

		local exhausted = SprintState.withStaminaLocked(sprinting, true)
		expect(speedOf(exhausted)).toBe(NORMAL_SPEED)
	end)

	it("reports the player as not sprinting once the lockout engages", function()
		-- What RunningController sends the server. An exhausted player who kept
		-- reporting true would be charged a drain instead of regenerating, and
		-- would never recover while the key was held.
		expect(SprintState.isSprinting(exhaustedAndHolding())).toBe(false)
	end)

	it("keeps the sprint request while locked, rather than clearing it", function()
		-- Holding Shift through the whole exhaustion has to be enough to resume.
		expect(exhaustedAndHolding().sprintRequested).toBe(true)
	end)

	it("does not let releasing and re-pressing Shift bypass the lockout", function()
		local state = exhaustedAndHolding()

		state = SprintState.withInputEnded(state)
		expect(speedOf(state)).toBe(NORMAL_SPEED)

		state = SprintState.withInputBegan(state)
		expect(state.staminaLocked).toBe(true)
		expect(SprintState.isSprinting(state)).toBe(false)
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("resumes sprinting when the lockout releases with Shift still held", function()
		local state = SprintState.withStaminaLocked(exhaustedAndHolding(), false)

		expect(SprintState.isSprinting(state)).toBe(true)
		expect(speedOf(state)).toBe(SPRINT_SPEED)
	end)

	it("does not start sprinting on recovery if Shift was released meanwhile", function()
		local state = SprintState.withInputEnded(exhaustedAndHolding())
		state = SprintState.withStaminaLocked(state, false)

		expect(SprintState.isSprinting(state)).toBe(false)
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("leaves normal walking alone", function()
		-- Exhaustion takes the sprint away; it is not a penalty on top of it.
		local state = SprintState.withStaminaLocked(SprintState.initial(), true)

		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("keeps the parry slower than an exhausted walk", function()
		-- Parry still outranks everything: being exhausted must not speed a
		-- guarding player up from 8 to 16.
		local state = SprintState.withParryBegan(exhaustedAndHolding())

		expect(speedOf(state)).toBe(PARRY_SPEED)
	end)

	it("returns an exhausted parrying player to walking, not sprinting", function()
		local state = SprintState.withParryEnded(SprintState.withParryBegan(exhaustedAndHolding()))

		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)

	it("is idempotent in both directions", function()
		local locked = SprintState.withStaminaLocked(exhaustedAndHolding(), true)
		expect(locked).toEqual(exhaustedAndHolding())

		local sprinting = SprintState.withInputBegan(SprintState.initial())
		expect(SprintState.withStaminaLocked(sprinting, false)).toEqual(sprinting)
	end)

	it("leaves no lockout behind after a full exhaust-and-recover cycle", function()
		local state = SprintState.initial()

		state = SprintState.withInputBegan(state)
		state = SprintState.withStaminaLocked(state, true)
		state = SprintState.withStaminaLocked(state, false)
		state = SprintState.withInputEnded(state)

		expect(state).toEqual(SprintState.initial())
		expect(speedOf(state)).toBe(NORMAL_SPEED)
	end)
end)
