--!strict
--[[
	Covers the pure sprint-intent state RunningController wires up to actual
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

describe("RunningController.SprintState", function()
	it("starts out not sprinting", function()
		local state = SprintState.initial()

		expect(state.sprintRequested).toBe(false)
		expect(SprintState.walkSpeed(state, NORMAL_SPEED, SPRINT_SPEED)).toBe(NORMAL_SPEED)
	end)

	it("requests sprint when Shift begins", function()
		local state = SprintState.withInputBegan(SprintState.initial())

		expect(state.sprintRequested).toBe(true)
		expect(SprintState.walkSpeed(state, NORMAL_SPEED, SPRINT_SPEED)).toBe(SPRINT_SPEED)
	end)

	it("clears the sprint request when Shift ends", function()
		local sprinting = SprintState.withInputBegan(SprintState.initial())
		local state = SprintState.withInputEnded(sprinting)

		expect(state.sprintRequested).toBe(false)
		expect(SprintState.walkSpeed(state, NORMAL_SPEED, SPRINT_SPEED)).toBe(NORMAL_SPEED)
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
