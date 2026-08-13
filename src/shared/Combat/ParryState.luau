--!strict
--[[
	ParryState — the phases a parry moves through, and the one geometric
	question a held guard answers.

	Shared rather than server-only because both sides need the same vocabulary:
	ParryController drives its own copy to decide what to animate and how fast
	to walk, and ParryService keeps the authoritative one that decides damage.
	The two are kept in step by the transitions below travelling over
	ParryStateRequest, so there is one definition of what "guarding" means
	rather than one per realm.

	Nothing here is secret. Knowing that the guard covers the forward
	hemisphere does not let a modified client widen it — ParryService recomputes
	the direction from its own view of where both characters are standing.

	No Roblox types in this file: the direction arrives as a plain dot product,
	so all of it is unit-testable without a character or a Humanoid.
]]

--[[
	The three phases, kept distinct rather than collapsed into one boolean
	because "asked to guard" and "actually guarding" have different
	consequences:

	  idle        Not parrying. Normal movement, normal damage, free to punch.
	  attempting  Q is down and the animation is winding up. Already slowed and
	              already unable to punch, but NOT protected — releasing Q here
	              must never have granted protection.
	  active      The animation reached its Hold marker. Protected across the
	              forward hemisphere until Q is released.
]]
export type Phase = "idle" | "attempting" | "active"

export type ParryState = {
	phase: Phase,
}

--[[
	What the client may ask of the server. These are the exact strings that
	travel over ParryStateRequest, so the wire vocabulary and the state machine
	cannot drift apart.
]]
export type Transition = "begin" | "hold" | "end"

local ParryState = {}

--[[
	The state a fresh controller, or a fresh character, starts in.
]]
function ParryState.initial(): ParryState
	return { phase = "idle" }
end

--[[
	Whether an arbitrary value that arrived from a client is one of the three
	transitions. ParryService calls this before anything else touches the
	payload — it is a type check and a range check in one, because the range is
	the whole type.
]]
function ParryState.isTransition(value: any): boolean
	return value == "begin" or value == "hold" or value == "end"
end

--[[
	The state `transition` leads to from `state`.

	Every illegal ordering is a no-op rather than an error, which is what lets
	ParryService validate a client's message by shape alone and then apply it
	without a second layer of ordering checks:

	  * "hold" from idle is ignored. A marker with no attempt behind it must
	    never produce a guard, or a modified client could skip straight past
	    the wind-up by sending one message.
	  * "begin" while already engaged is ignored, so mashing Q — or a platform
	    that repeats InputBegan while a key is held — cannot restart a guard
	    that is already being held, and cannot drop an active guard back to
	    attempting.
	  * "end" is honoured from every phase. A release must never be the thing
	    that gets dropped, because that is the one failure that would leave
	    somebody protected after they let go.
]]
function ParryState.apply(state: ParryState, transition: Transition): ParryState
	if transition == "end" then
		return { phase = "idle" }
	end

	if transition == "begin" then
		return if state.phase == "idle" then { phase = "attempting" } else state
	end

	if transition == "hold" then
		return if state.phase == "attempting" then { phase = "active" } else state
	end

	return state
end

function ParryState.isAttempting(state: ParryState): boolean
	return state.phase == "attempting"
end

function ParryState.isActive(state: ParryState): boolean
	return state.phase == "active"
end

--[[
	Whether the player is in a parry at all — winding up or holding.

	This is the predicate that costs them movement speed and their punch. Both
	apply from the moment Q goes down rather than from the Hold marker, so
	starting a parry is never free: a player who taps Q and releases before Hold
	has spent the wind-up slowed and unable to swing, and got no protection for
	it.
]]
function ParryState.isEngaged(state: ParryState): boolean
	return state.phase ~= "idle"
end

--[[
	Whether an active guard covers the direction an attack is arriving from.

	`attackerDot` is the dot product of the DEFENDER's look vector with the unit
	vector pointing at the attacker — the same quantity PunchRules calls
	`facingDot`, with the two roles swapped. 1 is an attacker dead ahead, 0 is
	one directly beside, -1 is one directly behind. It is defender-relative by
	construction, so no world-space direction enters into it.

	`minFacingDot` is a dot product rather than an angle for the same reason
	Config.PunchMinFacingDot is: it is what the comparison actually needs, and
	an angle would only have to be converted back. At the shipped 0 this is the
	forward hemisphere — front, front-left and front-right covered, the three
	rear directions not — and the comparison is >=, matching
	PunchRules.isInReach, so an attack from exactly beside is covered.

	An attempt that has not reached Hold is never protected, from any
	direction. That is the whole distinction the phases exist to keep.
]]
function ParryState.isProtectedFrom(
	state: ParryState,
	attackerDot: number,
	minFacingDot: number
): boolean
	return ParryState.isActive(state) and attackerDot >= minFacingDot
end

return ParryState
