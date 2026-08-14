--!strict
--[[
	ParryState — the phases a parry moves through, and the geometry a raised
	guard is judged by.

	Shared rather than server-only because both sides need the same vocabulary:
	ParryController drives its own copy to decide what to animate and how fast
	to walk, and ParryService keeps the authoritative one that decides damage.
	The two are kept in step by the transitions below travelling over
	ParryStateRequest, so there is one definition of what "guarding" means
	rather than one per realm.

	Nothing here is secret. Knowing that the guard covers the forward
	hemisphere does not let a modified client widen it — ParryService recomputes
	the direction from its own view of where both characters are standing.

	Everything here is pure: no instances, no Humanoid, no BasePart, no clock.
	`Vector3` appears in `attackerDot` because a direction genuinely is a vector
	and reducing it to plain numbers at the call site would put the subtraction
	and the normalisation — the two steps most likely to be wrong — back out of
	reach of a test. It is a datatype, not an instance, so a spec can construct
	one freely.
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
	              forward hemisphere for as long as Q is held.

	There is no fourth, time-based way out of `active`. A guard lasts exactly as
	long as the player holds the key, however long that is; only an explicit
	`end` or a lifecycle event (death, respawn, disconnect) returns it to idle.
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
	    attempting. Note "ignored" means "leaves the state alone", never
	    "discarded before it is applied": a caller must always apply a valid
	    transition, or the two realms stop agreeing.
	  * "end" is honoured from every phase. A release must never be the thing
	    that gets dropped, because that is the one failure that would leave
	    somebody protected after they let go.

	This function is the complete set of ways a phase can change. Nothing here
	reads a clock, so an active guard cannot lapse on its own.
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
	How far in front of the defender the attacker is, as a dot product.

	`defenderLook` is the defender's own forward direction and is assumed to be
	unit length, which `CFrame.LookVector` always is. The offset runs from the
	defender to the attacker, so the result is 1 for an attacker dead ahead, 0
	for one directly beside, and -1 for one directly behind — the same quantity
	PunchRules calls `facingDot`, with the two roles swapped. Everything is
	relative to the defender's own orientation; no world axis appears anywhere.

	Two characters standing in exactly the same spot have no direction between
	them. That degenerate case answers "dead ahead" rather than normalising a
	zero vector, matching how CombatService resolves the same situation for the
	punch cone.
]]
function ParryState.attackerDot(
	defenderLook: Vector3,
	defenderPosition: Vector3,
	attackerPosition: Vector3
): number
	local offset = attackerPosition - defenderPosition
	if offset.Magnitude == 0 then
		return 1
	end

	return defenderLook:Dot(offset.Unit)
end

--[[
	Whether a guard is up and facing the direction the attack is arriving from.

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
