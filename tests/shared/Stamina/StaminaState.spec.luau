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

	describe("canBlock", function()
		it("allows a guard while there is stamina left", function()
			expect(StaminaState.canBlock(StaminaState.new(MAX_STAMINA))).toBe(true)
			expect(StaminaState.canBlock(StaminaState.consume(StaminaState.new(MAX_STAMINA), 99.5)))
				.toBe(true)
		end)

		it("refuses a guard on an empty pool", function()
			local empty = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA)

			expect(StaminaState.canBlock(empty)).toBe(false)
		end)

		it("allows one again as soon as any stamina is back", function()
			local empty = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA)
			local recovered = StaminaState.regenerate(empty, 1)

			expect(StaminaState.canBlock(recovered)).toBe(true)
		end)
	end)

	describe("damageMultiplier", function()
		local ZERO_MULTIPLIER = Config.ZeroStaminaPunchDamageMultiplier

		it("leaves a punch alone while there is stamina left", function()
			expect(StaminaState.damageMultiplier(StaminaState.new(MAX_STAMINA), ZERO_MULTIPLIER))
				.toBe(1)
		end)

		it("leaves a punch alone with barely any stamina left", function()
			-- The rule is "empty", not "low". Anything above zero punches at full
			-- strength, so the cliff is where the pool runs out and nowhere else.
			local nearlyEmpty = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA - 1)

			expect(StaminaState.damageMultiplier(nearlyEmpty, ZERO_MULTIPLIER)).toBe(1)
		end)

		it("reduces a punch thrown on an empty pool", function()
			local empty = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA)

			expect(StaminaState.damageMultiplier(empty, ZERO_MULTIPLIER)).toBe(ZERO_MULTIPLIER)
		end)

		it("derives the shipped punch's reduced damage from PunchDamage", function()
			-- What CombatService actually computes. Asserted against the config
			-- rather than against 7.5 so retuning the punch retunes this with it.
			local empty = StaminaState.consume(StaminaState.new(MAX_STAMINA), MAX_STAMINA)
			local damage = Config.PunchDamage
				* StaminaState.damageMultiplier(empty, ZERO_MULTIPLIER)

			expect(damage).toBe(Config.PunchDamage * Config.ZeroStaminaPunchDamageMultiplier)
			expect(damage < Config.PunchDamage).toBe(true)
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
			expect(StaminaState.shouldReplicate(MAX_STAMINA, MAX_STAMINA, MAX_STAMINA, STEP))
				.toBe(false)
			expect(StaminaState.shouldReplicate(0, 0, MAX_STAMINA, STEP)).toBe(false)
		end)

		it("holds back a change smaller than one step", function()
			local justUnderAStep = MAX_STAMINA - (MAX_STAMINA * STEP) / 2

			expect(StaminaState.shouldReplicate(MAX_STAMINA, justUnderAStep, MAX_STAMINA, STEP))
				.toBe(false)
		end)

		it("sends a change of a whole step, in either direction", function()
			local step = MAX_STAMINA * STEP

			expect(StaminaState.shouldReplicate(MAX_STAMINA, MAX_STAMINA - step, MAX_STAMINA, STEP))
				.toBe(true)
			expect(StaminaState.shouldReplicate(50, 50 + step, MAX_STAMINA, STEP)).toBe(true)
		end)

		it("always sends the moment the pool empties, however small the last drain", function()
			-- The zero-stamina rules are an exact test, so the client may never
			-- be left approximating this one between two threshold updates.
			expect(StaminaState.shouldReplicate(0.01, 0, MAX_STAMINA, STEP)).toBe(true)
		end)

		it("always sends the moment the pool fills, however small the last regen", function()
			-- The bar hides at exactly full, so the same applies at the top.
			expect(
				StaminaState.shouldReplicate(MAX_STAMINA - 0.01, MAX_STAMINA, MAX_STAMINA, STEP)
			).toBe(true)
		end)
	end)
end)
