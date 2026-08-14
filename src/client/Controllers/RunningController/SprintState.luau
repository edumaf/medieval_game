--!strict
--[[
	SprintState — pure movement-intent state, kept separate from
	RunningController so it is testable without a Humanoid or input devices.

	This tracks only what the player is *requesting*: sprint (Left Shift held)
	and parry (Q held). Whether either request is currently applied to a
	Humanoid is RunningController's job — a request can exist with no Humanoid
	to apply it to (no character yet, or between deaths).

	The parry intent lives here, rather than ParryController setting WalkSpeed
	itself, because WalkSpeed must have exactly one writer. Two controllers
	assigning it would fight: releasing Shift would clear a parry's slowdown,
	and ending a parry would clear a sprint. Keeping both intents in one state
	means the speed is always recomputed from both, so neither can strand the
	other. The file keeps its name for the sake of a small diff; it is now
	movement intent rather than sprint intent alone.
]]

export type SprintState = {
	sprintRequested: boolean,
	parryRequested: boolean,
}

local SprintState = {}

--[[
	The state a fresh controller (or a fresh character) starts in: neither
	sprinting nor parrying until a key is pressed again.
]]
function SprintState.initial(): SprintState
	return { sprintRequested = false, parryRequested = false }
end

--[[
	Left Shift pressed. Idempotent: pressing it again while already held
	yields the same requested state.
]]
function SprintState.withInputBegan(state: SprintState): SprintState
	return { sprintRequested = true, parryRequested = state.parryRequested }
end

--[[
	Left Shift released. Idempotent: releasing it again while already up
	yields the same requested state.
]]
function SprintState.withInputEnded(state: SprintState): SprintState
	return { sprintRequested = false, parryRequested = state.parryRequested }
end

--[[
	A parry began — the key press, not the Hold marker. The slowdown covers the
	wind-up as well as the held guard, so starting a parry costs something even
	if it is cancelled before it protects anything.

	Idempotent, and it preserves the sprint request rather than clearing it, so
	a player who parries mid-sprint returns to sprinting the moment the parry
	ends without having to release and re-press Shift.
]]
function SprintState.withParryBegan(state: SprintState): SprintState
	return { sprintRequested = state.sprintRequested, parryRequested = true }
end

--[[
	A parry ended, for any reason: Q released, the character died, or it was
	replaced on respawn. Idempotent.
]]
function SprintState.withParryEnded(state: SprintState): SprintState
	return { sprintRequested = state.sprintRequested, parryRequested = false }
end

--[[
	The WalkSpeed that should be applied for this state. Takes the three speeds
	as arguments rather than reading Config directly, so this stays pure.

	Parry outranks sprint: holding both keys walks at the parry speed. A guard
	you can sprint out of is not a guard, and the slowdown is what the
	protection costs — letting Shift cancel it would make the parry strictly
	better than not parrying.
]]
function SprintState.walkSpeed(
	state: SprintState,
	normalSpeed: number,
	sprintSpeed: number,
	parrySpeed: number
): number
	if state.parryRequested then
		return parrySpeed
	end

	return if state.sprintRequested then sprintSpeed else normalSpeed
end

return SprintState
