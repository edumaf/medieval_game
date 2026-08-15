--!strict
--[[
	Covers the pure stamina arithmetic StaminaService wires up to a clock, a
	character and a remote. No player, Humanoid or RemoteEvent involved here —
	see docs/testing.md for the Studio steps that cover those.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local StaminaState = require(ReplicatedStorage.Shared.Stamina.StaminaState)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local MAX_STAMINA = 100

describe("Shared.Stamina.StaminaState", function()
	describe("a fresh pool", function()
		it("starts at max stamina", function()
			local state = StaminaState.new(MAX_STAMINA)

			expect(state.current).toBe(MAX_STAMINA)
			expect(state.max).toBe(MAX_STAMINA)
		end)

		it("starts full and not empty", function()
			local state = StaminaState.new(MAX_STAMINA)

			expect(StaminaState.isFull(state)).toBe(true)
			expect(StaminaState.isEmpty(state)).toBe(false)
		end)

		it("floors a non-positive max at zero rather than inverting the pool", function()
			local state = StaminaState.new(-50)

			expect(state.current).toBe(0)
			expect(state.max).toBe(0)
			-- Both ends at once. The service should never build one of these, but
			-- if it does, every predicate has to stay answerable.
			expect(StaminaState.isEmpty(state)).toBe(true)
			expect(StaminaState.isFull(state)).toBe(true)
		end)
	end)

	describe("consume", function()
		it("reduces stamina by the amount spent", function()
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), 30)

			expect(state.current).toBe(70)
			expect(StaminaState.isEmpty(state)).toBe(false)
			expect(StaminaState.isFull(state)).toBe(false)
		end)

		it("clamps at zero rather than going negative", function()
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), 500)

			expect(state.current).toBe(0)
			expect(StaminaState.isEmpty(state)).toBe(true)
		end)

		it("never produces a negative pool however many times it is drained", function()
			-- The sprint drain is applied every tick for as long as the key is
			-- held, so "keeps subtracting from an empty pool" is the normal case
			-- rather than an edge one.
			local state = StaminaState.new(MAX_STAMINA)
			for _ = 1, 50 do
				state = StaminaState.consume(state, 25)
				expect(state.current >= 0).toBe(true)
			end

			expect(state.current).toBe(0)
		end)

		it("ignores non-positive amounts", function()
			-- A tick with no elapsed time, or a clock that went backwards, must
			-- never refund stamina.
			local full = StaminaState.new(MAX_STAMINA)

			expect(StaminaState.consume(full, 0).current).toBe(MAX_STAMINA)
			expect(StaminaState.consume(full, -10).current).toBe(MAX_STAMINA)
		end)

		it("leaves max alone", function()
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), 40)

			expect(state.max).toBe(MAX_STAMINA)
		end)
	end)

	describe("regenerate", function()
		it("restores stamina by the amount given", function()
			local drained = StaminaState.consume(StaminaState.new(MAX_STAMINA), 40)
			local state = StaminaState.regenerate(drained, 15)

			expect(state.current).toBe(75)
		end)

		it("clamps at max rather than overfilling", function()
			local drained = StaminaState.consume(StaminaState.new(MAX_STAMINA), 10)
			local state = StaminaState.regenerate(drained, 500)

			expect(state.current).toBe(MAX_STAMINA)
			expect(StaminaState.isFull(state)).toBe(true)
		end)

		it("never exceeds max however many times it is applied", function()
			-- Regen runs on every tick a player is idle, which is most of them.
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA)
			for _ = 1, 50 do
				state = StaminaState.regenerate(state, 25)
				expect(state.current <= MAX_STAMINA).toBe(true)
			end

			expect(state.current).toBe(MAX_STAMINA)
		end)

		it("ignores non-positive amounts", function()
			local drained = StaminaState.consume(StaminaState.new(MAX_STAMINA), 10)

			expect(StaminaState.regenerate(drained, 0).current).toBe(90)
			expect(StaminaState.regenerate(drained, -10).current).toBe(90)
		end)

		it("brings an empty pool back, unlike health's one-way death", function()
			local empty = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA)
			local recovered = StaminaState.regenerate(empty, 20)

			expect(recovered.current).toBe(20)
			expect(StaminaState.isEmpty(recovered)).toBe(false)
		end)
	end)

	describe("isEmpty and isFull", function()
		it("is empty at exactly zero, and not one drain earlier", function()
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA - 0.5)

			expect(state.current).toBe(0.5)
			expect(StaminaState.isEmpty(state)).toBe(false)

			expect(StaminaState.isEmpty(StaminaState.consume(state, 0.5))).toBe(true)
		end)

		it("is full at exactly max, and not one regen earlier", function()
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), 0.5)

			expect(StaminaState.isFull(state)).toBe(false)
			expect(StaminaState.isFull(StaminaState.regenerate(state, 0.5))).toBe(true)
		end)
	end)

	describe("isExhausted", function()
		local RECOVERY = Config.StaminaRecoveryFraction

		local function poolAt(fraction: number): StaminaState.StaminaState
			return StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA * (1 - fraction))
		end

		it("leaves sprinting alone while the pool has stamina in it", function()
			expect(StaminaState.isExhausted(StaminaState.new(MAX_STAMINA), false, RECOVERY)).toBe(
				false
			)
			expect(StaminaState.isExhausted(poolAt(0.01), false, RECOVERY)).toBe(false)
		end)

		it("engages the moment the pool is empty", function()
			expect(StaminaState.isExhausted(poolAt(0), false, RECOVERY)).toBe(true)
		end)

		it("engages on an empty pool however it was emptied", function()
			-- A punch or a guard can empty the pool just as a sprint can, and the
			-- lockout is defined against the pool rather than against what drained
			-- it.
			local emptiedByPunches =
				StaminaState.consume(StaminaState.new(MAX_STAMINA), Config.PunchStaminaCost * 10)

			expect(StaminaState.isExhausted(emptiedByPunches, false, RECOVERY)).toBe(true)
		end)

		it("stays engaged through the first tick of regeneration", function()
			-- The whole reason the release threshold is not zero: one tick back
			-- would otherwise buy one tick of sprinting, ten times a second.
			local recovered = StaminaState.regenerate(poolAt(0), 1)

			expect(StaminaState.isExhausted(recovered, true, RECOVERY)).toBe(true)
		end)

		it("stays engaged just below the recovery fraction", function()
			local justShort = poolAt(RECOVERY - 0.01)

			expect(StaminaState.isExhausted(justShort, true, RECOVERY)).toBe(true)
		end)

		it("releases exactly at the recovery fraction", function()
			-- Exact rather than "past", so the threshold is a value the pool
			-- actually reaches rather than one it has to overshoot.
			expect(StaminaState.isExhausted(poolAt(RECOVERY), true, RECOVERY)).toBe(false)
		end)

		it("stays released once the pool is above the fraction", function()
			expect(StaminaState.isExhausted(poolAt(RECOVERY + 0.1), true, RECOVERY)).toBe(false)
			expect(StaminaState.isExhausted(StaminaState.new(MAX_STAMINA), true, RECOVERY)).toBe(
				false
			)
		end)

		it("re-engages if the pool empties again after recovering", function()
			local recovered = poolAt(RECOVERY)
			expect(StaminaState.isExhausted(recovered, true, RECOVERY)).toBe(false)

			local drainedAgain = StaminaState.consume(recovered, MAX_STAMINA)
			expect(StaminaState.isExhausted(drainedAgain, false, RECOVERY)).toBe(true)
		end)

		it("does not release early for a pool that was never locked", function()
			-- An unlocked player below the recovery fraction is sprinting on the
			-- last of their stamina, which is allowed. The fraction gates recovery
			-- from empty, not sprinting in general.
			expect(StaminaState.isExhausted(poolAt(RECOVERY / 2), false, RECOVERY)).toBe(false)
		end)

		it("keeps a zero-max pool locked rather than dividing by it", function()
			-- A mis-configured pool is empty by isEmpty before the release test is
			-- ever reached, so the division in fillFraction cannot be the thing
			-- that decides whether sprinting is allowed.
			expect(StaminaState.isExhausted(StaminaState.new(0), true, RECOVERY)).toBe(true)
			expect(StaminaState.isExhausted(StaminaState.new(0), false, RECOVERY)).toBe(true)
		end)
	end)

	describe("the shared exhaustion rule", function()
		local RECOVERY = Config.StaminaRecoveryFraction

		local function poolAt(fraction: number): StaminaState.StaminaState
			return StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA * (1 - fraction))
		end

		--[[
			What the sprint, the guard, punch damage and the vignette each read, as
			the callers actually derive them from the one latch. They are asserted
			together on purpose: the point of the shared rule is that these four can
			never answer differently for the same pool.
		]]
		local function consequencesOf(exhausted: boolean)
			return {
				canSprint = not exhausted,
				canGuard = not exhausted,
				punchMultiplier = if exhausted then 0 else 1,
				vignette = exhausted,
			}
		end

		it("takes everything away at once when the pool empties", function()
			local exhausted = StaminaState.isExhausted(poolAt(0), false, RECOVERY)

			expect(exhausted).toBe(true)
			expect(consequencesOf(exhausted)).toEqual({
				canSprint = false,
				canGuard = false,
				punchMultiplier = 0,
				vignette = true,
			})
		end)

		it("gives everything back at once at the recovery threshold", function()
			local exhausted = StaminaState.isExhausted(poolAt(RECOVERY), true, RECOVERY)

			expect(exhausted).toBe(false)
			expect(consequencesOf(exhausted)).toEqual({
				canSprint = true,
				canGuard = true,
				punchMultiplier = 1,
				vignette = false,
			})
		end)

		it("keeps all four withheld through a partial recovery", function()
			-- The whole reason the threshold exists. A player at a fifth of the pool
			-- is still exhausted, so none of the four may come back early.
			for _, fraction in { 0.01, 0.05, 0.1, RECOVERY - 0.01 } do
				local exhausted = StaminaState.isExhausted(poolAt(fraction), true, RECOVERY)

				expect(exhausted).toBe(true)
				expect(consequencesOf(exhausted).punchMultiplier).toBe(0)
				expect(consequencesOf(exhausted).canGuard).toBe(false)
			end
		end)

		it("leaves a player who has never been exhausted entirely alone", function()
			-- Being low is not being exhausted. Everything below the recovery
			-- threshold still sprints, guards and punches at full strength as long
			-- as the pool has never actually run out.
			for _, fraction in { 0.01, 0.1, RECOVERY - 0.01, RECOVERY, 0.9 } do
				local exhausted = StaminaState.isExhausted(poolAt(fraction), false, RECOVERY)

				expect(exhausted).toBe(false)
				expect(consequencesOf(exhausted)).toEqual({
					canSprint = true,
					canGuard = true,
					punchMultiplier = 1,
					vignette = false,
				})
			end
		end)

		it("costs a punch thrown while exhausted all of its damage", function()
			-- The rule that replaced the old reduced-damage multiplier. Derived from
			-- PunchDamage rather than written down, exactly as CombatService does it.
			local exhausted = StaminaState.isExhausted(poolAt(0), false, RECOVERY)
			local damage = Config.PunchDamage * consequencesOf(exhausted).punchMultiplier

			expect(damage).toBe(0)
		end)

		it("does not reach zero damage by any route other than exhaustion", function()
			-- A punch on a pool that is merely low still hurts in full. The cliff is
			-- exhaustion and nowhere else.
			local low = StaminaState.isExhausted(poolAt(0.02), false, RECOVERY)

			expect(Config.PunchDamage * consequencesOf(low).punchMultiplier).toBe(
				Config.PunchDamage
			)
		end)
	end)

	describe("fillFraction", function()
		it("is 1 for a full pool and 0 for an empty one", function()
			local full = StaminaState.new(MAX_STAMINA)

			expect(StaminaState.fillFraction(full)).toBe(1)
			expect(StaminaState.fillFraction(StaminaState.consume(full, MAX_STAMINA))).toBe(0)
		end)

		it("is the ratio in between", function()
			local state = StaminaState.consume(StaminaState.new(MAX_STAMINA), 25)

			expect(StaminaState.fillFraction(state)).toBe(0.75)
		end)

		it("returns 0 for a pool with no max rather than dividing by zero", function()
			-- Infinity or NaN reaching a UDim2 corrupts the bar rather than just
			-- looking wrong.
			expect(StaminaState.fillFraction({ current = 5, max = 0 })).toBe(0)
		end)

		it("clamps a state built outside the module's own transitions", function()
			expect(StaminaState.fillFraction({ current = 500, max = MAX_STAMINA })).toBe(1)
			expect(StaminaState.fillFraction({ current = -20, max = MAX_STAMINA })).toBe(0)
		end)
	end)

	describe("shouldReplicate", function()
		local STEP = Config.StaminaReplicationStepFraction

		it("always sends a value that has never been sent", function()
			expect(StaminaState.shouldReplicate(nil, MAX_STAMINA, MAX_STAMINA, STEP)).toBe(true)
		end)

		it("never re-sends a value that has not moved", function()
			-- This is what makes an idle player, and a player pinned at zero,
			-- cost nothing at all.
			expect(StaminaState.shouldReplicate(MAX_STAMINA, MAX_STAMINA, MAX_STAMINA, STEP)).toBe(
				false
			)
			expect(StaminaState.shouldReplicate(0, 0, MAX_STAMINA, STEP)).toBe(false)
		end)

		it("holds back a change smaller than one step", function()
			local justUnderAStep = MAX_STAMINA - (MAX_STAMINA * STEP) / 2

			expect(StaminaState.shouldReplicate(MAX_STAMINA, justUnderAStep, MAX_STAMINA, STEP)).toBe(
				false
			)
		end)

		it("sends a change of a whole step, in either direction", function()
			local step = MAX_STAMINA * STEP

			expect(StaminaState.shouldReplicate(MAX_STAMINA, MAX_STAMINA - step, MAX_STAMINA, STEP)).toBe(
				true
			)
			expect(StaminaState.shouldReplicate(50, 50 + step, MAX_STAMINA, STEP)).toBe(true)
		end)

		it("always sends the moment the pool empties, however small the last drain", function()
			-- The zero-stamina rules are an exact test, so the client may never
			-- be left approximating this one between two threshold updates.
			expect(StaminaState.shouldReplicate(0.01, 0, MAX_STAMINA, STEP)).toBe(true)
		end)

		it("always sends the moment the pool fills, however small the last regen", function()
			-- The bar hides at exactly full, so the same applies at the top.
			expect(StaminaState.shouldReplicate(MAX_STAMINA - 0.01, MAX_STAMINA, MAX_STAMINA, STEP)).toBe(
				true
			)
		end)
	end)
end)
