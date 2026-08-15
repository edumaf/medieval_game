--!strict
--[[
	ScreenEffectState — which vignette a health change deserves, and which
	vignette wins when two of them arrive close together.

	Kept separate from ScreenEffectsController so all of it is testable without
	a PlayerGui, a Humanoid or a Tween, exactly like HealthDisplay next door and
	HealthService/HealthState on the server. Nothing here touches an Instance or
	reads a clock: a health change arrives as two numbers and leaves as a
	description of what should be on screen.

	`Color3` appears in the descriptions for the same reason `Vector3` appears
	in ParryState — it is a datatype rather than an instance, a spec can build
	one freely, and reducing a colour to three numbers at the call site would
	only put it back together on the other side.

	The tuning arrives as an argument rather than being read from Config here,
	matching SprintState.walkSpeed. It keeps this module free of any opinion
	about where the numbers live, and lets a spec try tuning values the shipped
	game does not use.
]]

--[[
	The four things the screen can be showing. Damage, healing and exhaustion
	all fade on their own; death is the end of a character and stays until a new
	one arrives.

	Exhaustion is not a health change at all — it is the shared stamina
	exhaustion latch engaging, the same one that takes the sprint and the guard
	away and zeroes punch damage. It lives here rather than in a controller
	of its own because it is the same vignette, drawn by the same four bands,
	competing for the same screen as the other three, and something has to
	decide which of them wins.
]]
export type EffectKind = "damage" | "heal" | "death" | "exhaustion"

--[[
	A complete description of one vignette, in the terms the controller draws
	it in:

	  intensity  peak opacity at the screen edge, 0 to 1.
	  reach      how far in from each edge the vignette extends at its peak, as
	             a fraction of the screen. Half the screen is where opposite
	             edges meet.
]]
export type ScreenEffect = {
	kind: EffectKind,
	color: Color3,
	intensity: number,
	reach: number,
}

--[[
	Everything the rules below need in order to turn a health change into a
	ScreenEffect. Config supplies the shipped values; see there for what each
	one is tuned against.
]]
export type Tuning = {
	damageColor: Color3,
	healColor: Color3,
	deathColor: Color3,
	exhaustionColor: Color3,
	minIntensity: number,
	maxIntensity: number,
	deathIntensity: number,
	exhaustionIntensity: number,
	minHealthChange: number,
	edgeReach: number,
	deathEdgeReach: number,
}

export type ScreenEffectState = {
	showing: ScreenEffect?,
}

local ScreenEffectState = {}

--[[
	The state a fresh controller — or a fresh character — starts in: nothing on
	screen.

	This is also what a respawn resets to. Clearing the screen and starting from
	nothing are deliberately the same thing, so there is no second "cleared"
	state that could drift away from this one.
]]
function ScreenEffectState.initial(): ScreenEffectState
	return { showing = nil }
end

--[[
	How much of the health bar a change of `amount` moved, from 0 to 1.

	A max health of zero or less has no scale to judge against, so the change
	counts as the whole bar rather than dividing — the same guard, for the same
	reason, as HealthDisplay.fillFraction.
]]
local function severity(amount: number, maxHealth: number): number
	if maxHealth <= 0 then
		return 1
	end

	return math.clamp(math.abs(amount) / maxHealth, 0, 1)
end

--[[
	Peak opacity for a health change: the smallest change worth drawing sits at
	`minIntensity`, losing or regaining the entire bar sits at `maxIntensity`,
	and everything between is proportional. Both ends are floors and ceilings
	rather than curves, so a big hit can never be drawn weaker than a small one.
]]
local function changeIntensity(amount: number, maxHealth: number, tuning: Tuning): number
	local span = tuning.maxIntensity - tuning.minIntensity
	return tuning.minIntensity + span * severity(amount, maxHealth)
end

--[[
	The vignette a death deserves. Always the same one — dying is dying, and
	how hard the killing blow landed is not something the player needs told.
]]
function ScreenEffectState.death(tuning: Tuning): ScreenEffect
	return {
		kind = "death",
		color = tuning.deathColor,
		intensity = tuning.deathIntensity,
		reach = tuning.deathEdgeReach,
	}
end

--[[
	The vignette running out of stamina deserves. Always the same one, like
	death: the pool is empty, and how it got there is not something the player
	needs told.

	Drawn at the shared resting reach rather than spreading like death does, and
	at a fixed intensity that Config keeps below the death one. Being exhausted
	is a cost, not an emergency, and it must never be mistaken for either being
	hit or dying.
]]
function ScreenEffectState.exhaustion(tuning: Tuning): ScreenEffect
	return {
		kind = "exhaustion",
		color = tuning.exhaustionColor,
		intensity = tuning.exhaustionIntensity,
		reach = tuning.edgeReach,
	}
end

--[[
	The vignette running the stamina pool dry deserves, or nil if this change is
	not one worth drawing.

	Both arguments answer "is this player exhausted", from the caller's latched
	reading of the pool: `isExhausted` now, `wasExhausted` the time before. Only
	the rising edge draws anything, so this fires once as the pool empties,
	stays quiet for as long as it stays empty however many stamina updates
	arrive in the meantime, stays quiet as it refills, and fires again the next
	time it is run dry.

	It is deliberately blind to *what* emptied the pool. Sprinting, holding a
	guard and throwing a punch all spend the same pool and all reach zero the
	same way, and a vignette that reported only one of them would be reporting
	the cause rather than the state. The caller supplies both booleans from
	the server's own exhaustion latch, so there is still exactly one definition
	of exhaustion in this game and this function does not add a second — it only
	decides when to say so.

	An edge rather than a plain "is the pool empty" test, because the pool keeps
	replicating while it sits at zero and every one of those updates would
	otherwise redraw. The latch behind `isExhausted` supplies the hysteresis
	that also stops a player regenerating out of an empty pool being told twice:
	it does not release until Config.StaminaRecoveryFraction, which is the same
	moment the sprint, the guard and full-strength punches come back.
]]
function ScreenEffectState.forExhaustion(
	wasExhausted: boolean,
	isExhausted: boolean,
	tuning: Tuning
): ScreenEffect?
	if isExhausted and not wasExhausted then
		return ScreenEffectState.exhaustion(tuning)
	end

	return nil
end

--[[
	The vignette a move from `previous` to `current` health deserves, or nil if
	that change is not worth drawing.

	Three things produce nil, and they are different problems:

	  * No change at all. HealthService snaps Humanoid.Health back to its own
	    authoritative value whenever the two disagree, and re-applying a value
	    that already matches still raises HealthChanged.
	  * A change below `minHealthChange`. See Config.ScreenEffectMinHealthChange
	    for the flicker that floor exists to stop.
	  * A NaN anywhere in the arithmetic, which can only arrive from a Humanoid
	    that is already broken and must not be turned into an effect nothing can
	    fade out.

	Reaching zero health is reported as a death rather than as damage, so the
	killing blow draws the death vignette instead of drawing an ordinary red
	flash that the death then has to interrupt. It is deliberately only checked
	for a change that went *down*: health climbing out of a negative value is
	somebody else's bug, and answering "you died" to it would be a lie.
]]
function ScreenEffectState.forHealthChange(
	previous: number,
	current: number,
	maxHealth: number,
	tuning: Tuning
): ScreenEffect?
	local delta = current - previous
	-- NaN is the one value the comparisons below all answer false to, which
	-- would otherwise fall through as a heal of no particular size.
	if delta ~= delta then
		return nil
	end

	if delta < 0 and current <= 0 then
		return ScreenEffectState.death(tuning)
	end

	if math.abs(delta) < tuning.minHealthChange then
		return nil
	end

	local intensity = changeIntensity(delta, maxHealth, tuning)

	if delta < 0 then
		return {
			kind = "damage",
			color = tuning.damageColor,
			intensity = intensity,
			reach = tuning.edgeReach,
		}
	end

	return {
		kind = "heal",
		color = tuning.healColor,
		intensity = intensity,
		reach = tuning.edgeReach,
	}
end

--[[
	The state `effect` leads to from `state`.

	Returning `state` itself — the same table, not an equal one — is how this
	says "nothing changed, do not play anything". The controller restarts its
	tween on every state it has not already got, so identity is what separates
	a repeat that should be redrawn from one that should be ignored, in the same
	way ParryState.apply returns the untouched state for a transition it refuses.

	The three rules, in the order they apply:

	  * A death showing outranks everything until the character is replaced.
	    Damage arriving a frame after the killing blow, or a heal landing on a
	    corpse, must not wipe the death vignette off the screen.
	  * A death replaces whatever is showing, immediately. It is the one effect
	    that is not allowed to wait its turn.
	  * Otherwise the newest change wins, except that a repeat of the kind
	    already showing keeps whichever peak is higher. That is what stops
	    repeated damage both stacking (two hits are never stronger than the
	    stronger one) and flickering (a scratch landing while a heavy hit is
	    still fading restarts the fade rather than dropping the screen to the
	    scratch's own strength).

	Crossing between kinds has no such rule: a heal immediately after a hit is
	drawn green, at its own strength, because telling the player they are being
	healed is the whole point of showing it. Exhaustion crosses the same way in
	both directions — it replaces a hit still fading, and a hit landing a moment
	later replaces it, because being attacked is the more urgent of the two and
	the screen only says one thing at a time.

	Exhaustion is subject to the death rule like everything else, which is the
	whole reason it goes through this function rather than being drawn directly:
	running the pool dry a frame after the killing blow must not wipe the death
	vignette off the screen and replace it with a grey one.
]]
function ScreenEffectState.withEffect(
	state: ScreenEffectState,
	effect: ScreenEffect
): ScreenEffectState
	local showing = state.showing

	if showing ~= nil and showing.kind == "death" then
		return state
	end

	if effect.kind == "death" then
		return { showing = effect }
	end

	if showing ~= nil and showing.kind == effect.kind and showing.intensity > effect.intensity then
		return {
			showing = {
				kind = effect.kind,
				color = effect.color,
				intensity = showing.intensity,
				reach = effect.reach,
			},
		}
	end

	return { showing = effect }
end

--[[
	The vignette currently on screen, or nil if there is none.
]]
function ScreenEffectState.showing(state: ScreenEffectState): ScreenEffect?
	return state.showing
end

--[[
	Whether what is showing is a death. The controller reads this to decide
	whether to hold the vignette or let it fade: every other effect finishes on
	its own, and a death waits for a respawn.
]]
function ScreenEffectState.isShowingDeath(state: ScreenEffectState): boolean
	local showing = state.showing
	return showing ~= nil and showing.kind == "death"
end

return ScreenEffectState
