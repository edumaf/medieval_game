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

	Stamina exhaustion is the third input, and it is here for the same reason:
	it changes the speed, and everything that changes the speed has to be
	recomputed from one state or the inputs strand each other. It is not a
	fourth thing this file decides, though -- the rule itself is
	StaminaState.sprintLocked, shared with the server, and RunningController
	hands the answer in through withStaminaLocked. This file only knows that a
	locked sprint is not a sprint.
]]

export type SprintState = {
	sprintRequested: boolean,
	parryRequested: boolean,

	-- Whether stamina has locked sprinting out. Kept separate from
	-- sprintRequested rather than clearing it, so a player who holds Shift
	-- through the whole exhaustion resumes sprinting the moment the lock
	-- releases, without having to release and press the key again.
	staminaLocked: boolean,
}

local SprintState = {}

--[[
	The state a fresh controller (or a fresh character) starts in: neither
	sprinting nor parrying until a key is pressed again.
]]
function SprintState.initial(): SprintState
	return { sprintRequested = false, parryRequested = false, staminaLocked = false }
end

--[[
	Left Shift pressed. Idempotent: pressing it again while already held
	yields the same requested state.

	Deliberately does not consider the lockout: the request is recorded whether
	or not it can be acted on right now, which is what lets a player who pressed
	Shift while exhausted start sprinting the moment the pool recovers rather
	than having to notice the bar and press it again.
]]
function SprintState.withInputBegan(state: SprintState): SprintState
	return {
		sprintRequested = true,
		parryRequested = state.parryRequested,
		staminaLocked = state.staminaLocked,
	}
end

--[[
	Left Shift released. Idempotent: releasing it again while already up
	yields the same requested state.
]]
function SprintState.withInputEnded(state: SprintState): SprintState
	return {
		sprintRequested = false,
		parryRequested = state.parryRequested,
		staminaLocked = state.staminaLocked,
	}
end

--[[
	The stamina lockout, as decided by StaminaState.sprintLocked against the
	pool the server last sent. Idempotent.

	Preserves the sprint request rather than clearing it, so the lock releasing
	is enough to resume a sprint that was interrupted by exhaustion.
]]
function SprintState.withStaminaLocked(state: SprintState, locked: boolean): SprintState
	return {
		sprintRequested = state.sprintRequested,
		parryRequested = state.parryRequested,
		staminaLocked = locked,
	}
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
	return {
		sprintRequested = state.sprintRequested,
		parryRequested = true,
		staminaLocked = state.staminaLocked,
	}
end

--[[
	A parry ended, for any reason: Q released, the character died, or it was
	replaced on respawn. Idempotent.
]]
function SprintState.withParryEnded(state: SprintState): SprintState
	return {
		sprintRequested = state.sprintRequested,
		parryRequested = false,
		staminaLocked = state.staminaLocked,
	}
end

--[[
	Whether the player is actually sprinting, as opposed to asking to.

	Both consumers read this rather than sprintRequested, which is the point of
	having it: the speed below and the bit RunningController reports to the
	server are then the same answer by construction, and an exhausted player
	cannot end up running at 24 while telling the server they have stopped, or
	the reverse.

	Parry is deliberately not part of this. It outranks sprint for the *speed*,
	but a parrying player is still asking to sprint, and the server bills a
	guard from its own parry phase rather than from this bit -- so folding parry
	in here would send a pair of messages per guard to change a drain the server
	does not read.
]]
function SprintState.isSprinting(state: SprintState): boolean
	return state.sprintRequested and not state.staminaLocked
end

--[[
	The WalkSpeed that should be applied for this state. Takes the three speeds
	as arguments rather than reading Config directly, so this stays pure.

	Parry outranks sprint: holding both keys walks at the parry speed. A guard
	you can sprint out of is not a guard, and the slowdown is what the
	protection costs — letting Shift cancel it would make the parry strictly
	better than not parrying.

	An exhausted player walks at the normal speed rather than at a fourth
	"tired" one. Running out of stamina takes the sprint away; it is not a
	penalty on top of it, and normal walking is unaffected by any of this.
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

	return if SprintState.isSprinting(state) then sprintSpeed else normalSpeed
end

return SprintState
