--!strict
--[[
	Covers the rules that decide which vignette a health change deserves, and
	which of two vignettes wins when they arrive close together. No PlayerGui,
	Humanoid or Tween involved here -- see docs/testing.md for the Studio steps
	that cover the drawing and the character bindings.

	The tuning is built here rather than read from Config so these stay tests of
	the rules rather than of the shipped numbers, which Config.spec.luau covers
	separately. The values are deliberately round: intensity spans 0.2 to 0.8,
	so half a health bar is exactly 0.5.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local ScreenEffectState = require(
	StarterPlayer.StarterPlayerScripts.Client.Controllers.ScreenEffectsController.ScreenEffectState
)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local MAX_HEALTH = 100

local DAMAGE_COLOR = Color3.fromRGB(150, 15, 15)
local HEAL_COLOR = Color3.fromRGB(40, 175, 65)
local DEATH_COLOR = Color3.fromRGB(110, 0, 0)

local TUNING: ScreenEffectState.Tuning = {
	damageColor = DAMAGE_COLOR,
	healColor = HEAL_COLOR,
	deathColor = DEATH_COLOR,
	minIntensity = 0.2,
	maxIntensity = 0.8,
	deathIntensity = 1,
	minHealthChange = 1,
	edgeReach = 0.2,
	deathEdgeReach = 0.45,
}

--[[
	The effect for a health change, asserted to exist. Every call in this file
	that uses it is a case the rules are supposed to draw something for, so a
	nil here is the test failing rather than a case to branch on.
]]
local function effectFor(previous: number, current: number): ScreenEffectState.ScreenEffect
	local effect = ScreenEffectState.forHealthChange(previous, current, MAX_HEALTH, TUNING)
	assert(effect ~= nil, `expected an effect for {previous} -> {current}`)
	return effect
end

--[[
	The state reached by playing `effects` in order, starting from nothing.
]]
local function after(
	effects: { ScreenEffectState.ScreenEffect }
): ScreenEffectState.ScreenEffectState
	local state = ScreenEffectState.initial()
	for _, effect in effects do
		state = ScreenEffectState.withEffect(state, effect)
	end
	return state
end

--[[
	What `state` is showing, asserted to be showing anything at all.
]]
local function showing(state: ScreenEffectState.ScreenEffectState): ScreenEffectState.ScreenEffect
	local effect = ScreenEffectState.showing(state)
	assert(effect ~= nil, "expected something to be showing")
	return effect
end

describe("ScreenEffectsController.ScreenEffectState", function()
	describe("initial", function()
		it("starts with nothing on screen", function()
			expect(ScreenEffectState.showing(ScreenEffectState.initial())).toBeNil()
			expect(ScreenEffectState.isShowingDeath(ScreenEffectState.initial())).toBe(false)
		end)
	end)

	describe("damage", function()
		it("draws red when health decreases", function()
			local effect = effectFor(100, 75)

			expect(effect.kind).toBe("damage")
			expect(effect.color).toBe(DAMAGE_COLOR)
		end)

		it("scales intensity with the fraction of the bar lost", function()
			-- 0.2 at nothing, 0.8 at everything, so half the bar is the midpoint.
			expect(effectFor(100, 50).intensity).toBeCloseTo(0.5, 6)
			expect(effectFor(100, 0.5).intensity).toBeCloseTo(0.797, 2)
		end)

		it(
			"draws a small hit weaker than a moderate one, and that weaker than a large one",
			function()
				local small = effectFor(100, 95)
				local moderate = effectFor(100, 75)
				local large = effectFor(100, 30)

				expect(small.intensity < moderate.intensity).toBe(true)
				expect(moderate.intensity < large.intensity).toBe(true)
			end
		)

		it("never draws a hit weaker than the minimum or stronger than the maximum", function()
			-- The floor keeps a scratch visible; the ceiling is what keeps every
			-- ordinary hit weaker than dying.
			expect(effectFor(100, 99).intensity >= TUNING.minIntensity).toBe(true)
			expect(effectFor(100, 0.5).intensity <= TUNING.maxIntensity).toBe(true)
		end)

		it("holds the vignette at its resting reach", function()
			-- Only death spreads towards the centre.
			expect(effectFor(100, 30).reach).toBe(TUNING.edgeReach)
		end)

		it("ignores a change too small to be worth drawing", function()
			-- Roblox's passive regeneration, and HealthService snapping it back,
			-- both arrive as changes this size. See
			-- Config.ScreenEffectMinHealthChange.
			expect(ScreenEffectState.forHealthChange(100, 99.9, MAX_HEALTH, TUNING)).toBeNil()
			expect(ScreenEffectState.forHealthChange(100, 100.1, MAX_HEALTH, TUNING)).toBeNil()
		end)

		it("ignores health that did not move", function()
			expect(ScreenEffectState.forHealthChange(60, 60, MAX_HEALTH, TUNING)).toBeNil()
		end)
	end)

	describe("healing", function()
		it("draws green when health increases", function()
			local effect = effectFor(50, 80)

			expect(effect.kind).toBe("heal")
			expect(effect.color).toBe(HEAL_COLOR)
		end)

		it("scales intensity with the fraction of the bar restored", function()
			expect(effectFor(50, 100).intensity).toBeCloseTo(0.5, 6)
		end)

		it(
			"draws a small heal weaker than a moderate one, and that weaker than a large one",
			function()
				local small = effectFor(50, 55)
				local moderate = effectFor(50, 75)
				local large = effectFor(1, 100)

				expect(small.intensity < moderate.intensity).toBe(true)
				expect(moderate.intensity < large.intensity).toBe(true)
			end
		)

		it("draws a heal and a hit of the same size at the same strength", function()
			-- The two effects differ in colour, not in how loud they are.
			expect(effectFor(100, 60).intensity).toBe(effectFor(20, 60).intensity)
		end)

		it("holds the vignette at its resting reach", function()
			expect(effectFor(20, 100).reach).toBe(TUNING.edgeReach)
		end)
	end)

	describe("death", function()
		it("draws red, stronger than any hit can be", function()
			local death = ScreenEffectState.death(TUNING)

			expect(death.kind).toBe("death")
			expect(death.color).toBe(DEATH_COLOR)
			expect(death.intensity > effectFor(100, 0.5).intensity).toBe(true)
		end)

		it("expands further towards the centre than a hit does", function()
			expect(ScreenEffectState.death(TUNING).reach > effectFor(100, 30).reach).toBe(true)
		end)

		it("reads a killing blow as a death rather than as damage", function()
			-- Whichever of HealthChanged and Humanoid.Died the client sees first
			-- has to produce the same thing, or the killing blow would flash red
			-- and then be interrupted by the death.
			expect(effectFor(25, 0).kind).toBe("death")
		end)

		it("reads a lethal hit smaller than the drawing floor as a death", function()
			-- The floor drops changes too small to matter. Dying always matters.
			expect(effectFor(0.5, 0).kind).toBe("death")
		end)

		it("does not read health climbing out of a negative value as a death", function()
			expect(effectFor(-10, 0).kind).toBe("heal")
		end)
	end)

	describe("withEffect", function()
		it("shows an effect arriving on a clear screen", function()
			local state = after({ effectFor(100, 75) })

			expect(showing(state).kind).toBe("damage")
		end)

		it("replaces a hit with a newer heal", function()
			local state = after({ effectFor(100, 75), effectFor(75, 100) })

			expect(showing(state).kind).toBe("heal")
			expect(showing(state).color).toBe(HEAL_COLOR)
		end)

		it("replaces a heal with a newer hit", function()
			local state = after({ effectFor(50, 100), effectFor(100, 60) })

			expect(showing(state).kind).toBe("damage")
			expect(showing(state).color).toBe(DAMAGE_COLOR)
		end)

		it("survives a damage, heal, damage sequence", function()
			local state = after({ effectFor(100, 80), effectFor(80, 95), effectFor(95, 40) })

			expect(showing(state).kind).toBe("damage")
			expect(showing(state).intensity).toBe(effectFor(95, 40).intensity)
		end)

		it("does not stack repeated damage past a single hit", function()
			-- Four identical hits in a row must look like one of them, not like
			-- four of them added together.
			local once = after({ effectFor(100, 75) })
			local repeated = after({
				effectFor(100, 75),
				effectFor(75, 50),
				effectFor(50, 25),
				effectFor(25, 10),
			})

			expect(showing(repeated).intensity).toBe(showing(once).intensity)
		end)

		it("keeps the stronger peak when a lighter hit lands during a heavier one", function()
			-- Otherwise a scratch arriving mid-fade would visibly drop the
			-- screen from a heavy hit's strength to its own.
			local heavy = effectFor(100, 40)
			local light = effectFor(40, 35)
			local state = after({ heavy, light })

			expect(showing(state).intensity).toBe(heavy.intensity)
			expect(showing(state).kind).toBe("damage")
		end)

		it("rises to the stronger peak when a heavier hit lands during a lighter one", function()
			local light = effectFor(100, 95)
			local heavy = effectFor(95, 30)
			local state = after({ light, heavy })

			expect(showing(state).intensity).toBe(heavy.intensity)
		end)

		it("keeps the stronger peak across repeated healing too", function()
			local large = effectFor(10, 90)
			local small = effectFor(90, 95)
			local state = after({ large, small })

			expect(showing(state).kind).toBe("heal")
			expect(showing(state).intensity).toBe(large.intensity)
		end)

		it("redraws even a repeat of the same effect", function()
			-- The controller restarts its tween on any state it did not already
			-- have, so an identical second hit has to come back as a new state
			-- or it would not be redrawn at all.
			local first = after({ effectFor(100, 75) })
			local second = ScreenEffectState.withEffect(first, effectFor(75, 50))

			expect(second).never.toBe(first)
		end)

		it("lets a death replace anything that is showing", function()
			local state = after({ effectFor(100, 40), ScreenEffectState.death(TUNING) })

			expect(ScreenEffectState.isShowingDeath(state)).toBe(true)
			expect(showing(state).color).toBe(DEATH_COLOR)
		end)

		it("keeps a death showing when more damage arrives behind it", function()
			local dead = after({ ScreenEffectState.death(TUNING) })
			local afterDamage = ScreenEffectState.withEffect(dead, effectFor(100, 75))

			expect(ScreenEffectState.isShowingDeath(afterDamage)).toBe(true)
			-- The same table, not merely an equal one: that identity is how the
			-- controller knows there is nothing new to play.
			expect(afterDamage).toBe(dead)
		end)

		it("keeps a death showing when a heal arrives behind it", function()
			local dead = after({ ScreenEffectState.death(TUNING) })
			local afterHeal = ScreenEffectState.withEffect(dead, effectFor(50, 100))

			expect(afterHeal).toBe(dead)
			expect(ScreenEffectState.isShowingDeath(afterHeal)).toBe(true)
		end)

		it("keeps a death showing when a second death arrives", function()
			local dead = after({ ScreenEffectState.death(TUNING) })
			local twice = ScreenEffectState.withEffect(dead, ScreenEffectState.death(TUNING))

			expect(twice).toBe(dead)
		end)

		it("clears back to nothing, so a respawn can start over", function()
			local dead = after({ ScreenEffectState.death(TUNING) })
			local respawned = ScreenEffectState.initial()

			expect(ScreenEffectState.isShowingDeath(dead)).toBe(true)
			expect(ScreenEffectState.showing(respawned)).toBeNil()

			-- And the fresh state takes an ordinary hit again, rather than
			-- staying locked out by the death that preceded it.
			expect(showing(ScreenEffectState.withEffect(respawned, effectFor(100, 75))).kind).toBe(
				"damage"
			)
		end)

		it("leaves the state it was given untouched", function()
			-- Every state is a value. A controller holding on to one must never
			-- see it change underneath.
			local first = after({ effectFor(100, 75) })
			local firstEffect = showing(first)

			ScreenEffectState.withEffect(first, ScreenEffectState.death(TUNING))

			expect(showing(first)).toBe(firstEffect)
			expect(showing(first).kind).toBe("damage")
		end)
	end)

	describe("degenerate health values", function()
		it("draws nothing for a NaN health value", function()
			local nan = 0 / 0

			expect(ScreenEffectState.forHealthChange(nan, 50, MAX_HEALTH, TUNING)).toBeNil()
			expect(ScreenEffectState.forHealthChange(50, nan, MAX_HEALTH, TUNING)).toBeNil()
		end)

		it(
			"draws a change at full strength when there is no max health to judge it against",
			function()
				-- Dividing by a zero or negative MaxHealth is the same trap
				-- HealthDisplay.fillFraction guards; here the answer is the ceiling
				-- rather than nothing, because health did genuinely move.
				local effect = ScreenEffectState.forHealthChange(50, 20, 0, TUNING)
				assert(effect ~= nil, "expected an effect")

				expect(effect.kind).toBe("damage")
				expect(effect.intensity).toBe(TUNING.maxIntensity)
			end
		)

		it("never draws stronger than the maximum, however large the change", function()
			local effect = ScreenEffectState.forHealthChange(100000, 1, MAX_HEALTH, TUNING)
			assert(effect ~= nil, "expected an effect")

			expect(effect.intensity).toBe(TUNING.maxIntensity)
		end)
	end)
end)
