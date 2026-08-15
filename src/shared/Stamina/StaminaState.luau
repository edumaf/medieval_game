--!strict
--[[
	StaminaState — the pure arithmetic behind a stamina pool.

	Kept separate from StaminaService so every rule below is testable without a
	player, a character or a clock. Mirrors HealthService/HealthState.luau: the
	state is a plain table, every transition returns a new one, and nothing here
	reads a clock or touches an Instance.

	Shared rather than server-only, for the same reason PunchRules is shared: the
	client reuses the exhaustion answer to avoid starting a parry the server is
	going to refuse, and reuses `fillFraction` to draw the bar. Nothing here is
	secret —
	every number it works with already lives in Config, and knowing the drain
	rate does not let a modified client drain more slowly, because the server
	recomputes the pool from its own clock and never accepts a stamina value from
	anyone.

	Two invariants hold for every function in this file:

	  * `current` is never below zero and never above `max`. Both ends clamp.
	  * There is no "dead" latch, unlike HealthState. An empty pool is an
	    ordinary state that regenerates back out of itself, which is exactly what
	    the zero-stamina rules are defined against.
]]

export type StaminaState = {
	current: number,
	max: number,
}

local StaminaState = {}

--[[
	The state a fresh character starts in: a full pool.

	A non-positive `max` is floored at zero rather than rejected, so a
	mis-configured Config produces an empty pool instead of a state whose two
	fields disagree about which end is which.
]]
function StaminaState.new(max: number): StaminaState
	local ceiling = math.max(max, 0)
	return { current = ceiling, max = ceiling }
end

--[[
	Whether the pool is exhausted. This is the predicate the whole zero-stamina
	rule set is written against: no blocking, and punches at the reduced
	multiplier.

	Compares with `<=` rather than `== 0` deliberately. Every path into this
	module clamps at zero, so a negative can only arrive from a state somebody
	built by hand — and answering "not empty" for a negative pool would be the
	one reading that lets a bug hand out full-strength punches.
]]
function StaminaState.isEmpty(state: StaminaState): boolean
	return state.current <= 0
end

function StaminaState.isFull(state: StaminaState): boolean
	return state.current >= state.max
end

--[[
	Spends stamina. Non-positive amounts are ignored, so a drain computed from a
	zero or backwards time step cannot refund anything, and `current` is clamped
	so it never goes below zero however large the amount is.
]]
function StaminaState.consume(state: StaminaState, amount: number): StaminaState
	if amount <= 0 then
		return state
	end

	return { current = math.max(state.current - amount, 0), max = state.max }
end

--[[
	Restores stamina. Non-positive amounts are ignored and `current` is clamped
	so it never exceeds `max`.

	There is no "cannot regenerate while empty" rule here on purpose — running
	out of stamina is meant to be recoverable, which is the whole difference
	between this and HealthState's one-way death.
]]
function StaminaState.regenerate(state: StaminaState, amount: number): StaminaState
	if amount <= 0 then
		return state
	end

	return { current = math.min(state.current + amount, state.max), max = state.max }
end

--[[
	Whether the player is exhausted, given whether they already were.

	**The** definition of exhaustion in this game. Everything that an empty pool
	takes away reads this one answer and no other: sprinting (RunningController
	applies it to WalkSpeed), guarding (ParryService refuses a begin and
	StaminaService ends a live guard), punch damage (CombatService multiplies by
	zero), and the exhaustion vignette. One rule, so "cannot start", "cannot
	continue", "does no damage" and "is being told about it" can never drift
	apart.

	A latch rather than a plain predicate, because "recovered enough" is not a
	property of the current value alone. The two ends are deliberately different:

	  * It engages on an empty pool, whatever emptied it -- sprinting, a guard,
	    or a punch. All three spend the same pool and all three reach zero the
	    same way.
	  * It releases only once the pool is back to `recoveryFraction` of its
	    maximum, which is what stops it flickering off after one tick of
	    regeneration and what makes exhaustion a state the player has to climb
	    out of rather than a threshold they hover on.

	The asymmetry is the point, and it is also why a player who has never been
	exhausted is unaffected: with `wasExhausted` false, anything above zero
	answers false, so the last few points of a full pool spend exactly as
	normally as the first few. The recovery fraction only ever gates the way
	*out*.

	`wasExhausted` is the caller's previous answer, exactly as shouldReplicate
	takes `lastSent`. That is what keeps the memory in the caller and this
	function pure. StaminaService is the caller that matters -- it holds the
	authoritative latch and replicates the result -- so no client is deciding
	this for itself.
]]
function StaminaState.isExhausted(
	state: StaminaState,
	wasExhausted: boolean,
	recoveryFraction: number
): boolean
	if StaminaState.isEmpty(state) then
		return true
	end

	if wasExhausted then
		return StaminaState.fillFraction(state) < recoveryFraction
	end

	return false
end

--[[
	Fraction of the bar to fill, always within [0, 1].

	A `max` of zero or less has no meaningful fill, so this returns 0 rather than
	dividing: 0/0 is NaN and x/0 is infinity, and either one reaching a UDim2
	corrupts the bar instead of just looking wrong.

	HealthDisplay.fillFraction does the same arithmetic for the health bar. The
	two are not shared because that one also owns the health label's rounding
	policy and belongs to HealthBarController; unifying them means moving a
	module that this feature has no other reason to touch.
]]
function StaminaState.fillFraction(state: StaminaState): number
	if state.max <= 0 then
		return 0
	end

	local fraction = state.current / state.max
	-- NaN is the one value math.clamp cannot rescue.
	if fraction ~= fraction then
		return 0
	end

	return math.clamp(fraction, 0, 1)
end

--[[
	Whether a change is worth a network message.

	This is the whole replication policy, kept here so it can be tested without a
	remote. StaminaService calls it once per tick per player and only fires
	StaminaChanged when it answers true, which is what keeps a continuously
	draining pool down to a handful of messages a second instead of one per
	frame.

	  * A pool that has never been sent is always worth sending.
	  * A value identical to the last one sent never is, so a player sitting at
	    full or pinned at zero costs nothing at all.
	  * Both ends of the pool are always sent the moment they are reached. The
	    zero-stamina rules and the bar's own hide-at-full behaviour are exact
	    tests, so neither may be left to a client approximating between two
	    threshold updates.
	  * Anything else has to have moved by `stepFraction` of the pool.
]]
function StaminaState.shouldReplicate(
	lastSent: number?,
	current: number,
	max: number,
	stepFraction: number
): boolean
	if lastSent == nil then
		return true
	end
	if current == lastSent then
		return false
	end
	if current <= 0 or current >= max then
		return true
	end

	return math.abs(current - lastSent) >= max * stepFraction
end

return StaminaState
