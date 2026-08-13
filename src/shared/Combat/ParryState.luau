--!strict
--[[
	ParryState — the phases a parry moves through, the geometry a guard is
	judged by, and the lifetime the server allows it.

	Shared rather than server-only because both sides need the same vocabulary:
	ParryController drives its own copy to decide what to animate and how fast
	to walk, and ParryService keeps the authoritative one that decides damage.
	The two are kept in step by the transitions below travelling over
	ParryStateRequest, so there is one definition of what "guarding" means
	rather than one per realm.

	Nothing here is secret. Knowing that the guard covers the forward
	hemisphere does not let a modified client widen it — ParryService recomputes
	the direction from its own view of where both characters are standing.

	Everything here is pure: no instances, no Humanoid, no BasePart, no clock of
	its own. `Vector3` appears in `attackerDot` because a direction genuinely is
	a vector and reducing it to plain numbers at the call site would put the
	subtraction and the normalisation — the two steps most likely to be wrong —
	back out of reach of a test. It is a datatype, not an instance, so a spec can
	construct one freely. Times arrive as parameters for the same reason: the
	caller reads the clock, this module only compares.
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
	              forward hemisphere until Q is released, or until the guard
	              outlives the maximum hold below.
]]
export type Phase = "idle" | "attempting" | "active"

--[[
	`activatedAt` is the reading of the caller's clock at the moment the guard
	went up, and is nil in every other phase. It exists so the server can put a
	ceiling on how long one guard may last without running a timer: the check
	happens when somebody throws a punch, not on a schedule.

	Both sides carry the field, but only the server's copy is ever compared
	against a clock — the two realms never share a time base, so a client's
	`activatedAt` is meaningless to the server and is never sent.
]]
export type ParryState = {
	phase: Phase,
	activatedAt: number?,
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
	return { phase = "idle", activatedAt = nil }
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
	The state `transition` leads to from `state`. `now` is the caller's clock,
	recorded as `activatedAt` when — and only when — this call raises the guard.

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
]]
function ParryState.apply(state: ParryState, transition: Transition, now: number): ParryState
	if transition == "end" then
		return { phase = "idle", activatedAt = nil }
	end

	if transition == "begin" then
		if state.phase ~= "idle" then
			return state
		end
		return { phase = "attempting", activatedAt = nil }
	end

	if transition == "hold" then
		if state.phase ~= "attempting" then
			return state
		end
		return { phase = "active", activatedAt = now }
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

	Deliberately blind to the maximum hold below. A guard that has outlived its
	protection is still a guard the player is holding the key for, so it still
	costs them their punch; what expires is the protection, not the commitment.
]]
function ParryState.isEngaged(state: ParryState): boolean
	return state.phase ~= "idle"
end

--[[
	Whether a raised guard has been held longer than the server allows.

	This is a ceiling on one guard's lifetime, and it is emphatically NOT a
	wind-up timer — it says nothing about when protection begins, only about
	when it stops. Its reason for existing is that "end" is a message from the
	client, and a client that simply never sends one would otherwise stay
	protected for the whole life of its character. Nothing else in the design
	bounds that.

	Evaluated on demand, against the clock reading the caller supplies, so no
	timer or Heartbeat connection is needed to enforce it.

	A clock that has gone backwards yields a negative hold, which is treated as
	not expired — the same direction PunchRules.canPunch errs in, and for the
	same reason: a bad reading should never silently take away something the
	player is entitled to.
]]
function ParryState.isExpired(state: ParryState, now: number, maxHoldSeconds: number): boolean
	local activatedAt = state.activatedAt
	if state.phase ~= "active" or activatedAt == nil then
		return false
	end

	local held = now - activatedAt
	return held >= 0 and held > maxHoldSeconds
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
	Whether a guard is up, still within its allowed lifetime, and facing the
	direction the attack is arriving from.

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
	minFacingDot: number,
	now: number,
	maxHoldSeconds: number
): boolean
	return ParryState.isActive(state)
		and not ParryState.isExpired(state, now, maxHoldSeconds)
		and attackerDot >= minFacingDot
end

return ParryState
