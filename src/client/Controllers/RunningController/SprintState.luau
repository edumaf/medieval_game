--!strict
--[[
	SprintState — pure sprint-intent state, kept separate from
	RunningController so it is testable without a Humanoid or input devices.

	This tracks only whether the player is *requesting* to sprint (Left Shift
	held). Whether that request is currently applied to a Humanoid is
	RunningController's job — a request can exist with no Humanoid to apply it
	to (no character yet, or between deaths).
]]

export type SprintState = {
	sprintRequested: boolean,
}

local SprintState = {}

--[[
	The state a fresh controller (or a fresh character) starts in: not
	sprinting until Shift is pressed again.
]]
function SprintState.initial(): SprintState
	return { sprintRequested = false }
end

--[[
	Left Shift pressed. Idempotent: pressing it again while already held
	yields the same requested state.
]]
function SprintState.withInputBegan(_state: SprintState): SprintState
	return { sprintRequested = true }
end

--[[
	Left Shift released. Idempotent: releasing it again while already up
	yields the same requested state.
]]
function SprintState.withInputEnded(_state: SprintState): SprintState
	return { sprintRequested = false }
end

--[[
	The WalkSpeed that should be applied for this state. Takes the two speeds
	as arguments rather than reading Config directly, so this stays pure.
]]
function SprintState.walkSpeed(state: SprintState, normalSpeed: number, sprintSpeed: number): number
	return if state.sprintRequested then sprintSpeed else normalSpeed
end

return SprintState
