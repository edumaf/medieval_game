--!strict
--[[
	HealthState — pure health-state transitions, kept separate from
	HealthService so the numeric rules are testable without a live Humanoid or
	character. Mirrors src/client/Controllers/RunningController/SprintState.luau.

	Health can never go below zero or above `max`. Death is a one-way
	transition: once `dead` is true, both damage and healing are no-ops until a
	fresh state is created for a new character (see HealthState.new) — there is
	no revive mechanic yet.
]]

export type HealthState = {
	current: number,
	max: number,
	dead: boolean,
}

local HealthState = {}

--[[
	The state a fresh character starts in: full health, alive.
]]
function HealthState.new(max: number): HealthState
	return { current = max, max = max, dead = false }
end

function HealthState.isDead(state: HealthState): boolean
	return state.dead
end

--[[
	Applies damage. Non-positive amounts are ignored, and an already-dead
	state is unaffected by further damage. Otherwise `current` is clamped so
	it never goes below zero, and `dead` becomes true exactly once, the moment
	`current` reaches zero.
]]
function HealthState.damage(state: HealthState, amount: number): HealthState
	if state.dead or amount <= 0 then
		return state
	end

	local current = math.max(state.current - amount, 0)
	return { current = current, max = state.max, dead = current <= 0 }
end

--[[
	Restores health. Non-positive amounts are ignored, and a dead state cannot
	be healed back to life — a new character gets a fresh HealthState.new
	instead. Otherwise `current` is clamped so it never exceeds `max`.
]]
function HealthState.heal(state: HealthState, amount: number): HealthState
	if state.dead or amount <= 0 then
		return state
	end

	local current = math.min(state.current + amount, state.max)
	return { current = current, max = state.max, dead = false }
end

return HealthState
