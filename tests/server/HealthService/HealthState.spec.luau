--!strict
--[[
	Covers the pure health-state transitions HealthService wires up to an
	actual Humanoid. No Roblox character or Humanoid involved here — see
	docs/decisions.md for the Studio steps that cover those.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local HealthState = require(ServerScriptService.Server.Services.HealthService.HealthState)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local MAX_HEALTH = 100

describe("HealthService.HealthState", function()
	it("starts at max health, alive", function()
		local state = HealthState.new(MAX_HEALTH)

		expect(state.current).toBe(MAX_HEALTH)
		expect(state.max).toBe(MAX_HEALTH)
		expect(HealthState.isDead(state)).toBe(false)
	end)

	it("reduces health by the damage amount", function()
		local state = HealthState.damage(HealthState.new(MAX_HEALTH), 30)

		expect(state.current).toBe(70)
		expect(HealthState.isDead(state)).toBe(false)
	end)

	it("never reduces health below zero", function()
		local state = HealthState.damage(HealthState.new(MAX_HEALTH), 500)

		expect(state.current).toBe(0)
	end)

	it("ignores non-positive damage", function()
		local initial = HealthState.new(MAX_HEALTH)

		expect(HealthState.damage(initial, 0).current).toBe(MAX_HEALTH)
		expect(HealthState.damage(initial, -10).current).toBe(MAX_HEALTH)
	end)

	it("restores health by the heal amount", function()
		local damaged = HealthState.damage(HealthState.new(MAX_HEALTH), 40)
		local healed = HealthState.heal(damaged, 15)

		expect(healed.current).toBe(75)
		expect(HealthState.isDead(healed)).toBe(false)
	end)

	it("never heals above max health", function()
		local damaged = HealthState.damage(HealthState.new(MAX_HEALTH), 10)
		local healed = HealthState.heal(damaged, 500)

		expect(healed.current).toBe(MAX_HEALTH)
	end)

	it("ignores non-positive healing", function()
		local damaged = HealthState.damage(HealthState.new(MAX_HEALTH), 10)

		expect(HealthState.heal(damaged, 0).current).toBe(90)
		expect(HealthState.heal(damaged, -10).current).toBe(90)
	end)

	it("dies exactly when lethal damage brings health to zero", function()
		local state = HealthState.damage(HealthState.new(MAX_HEALTH), MAX_HEALTH)

		expect(state.current).toBe(0)
		expect(HealthState.isDead(state)).toBe(true)
	end)

	it("dies from damage that exceeds current health", function()
		local state = HealthState.damage(HealthState.new(MAX_HEALTH), MAX_HEALTH + 50)

		expect(state.current).toBe(0)
		expect(HealthState.isDead(state)).toBe(true)
	end)

	it("ignores further damage once dead, without erroring", function()
		local dead = HealthState.damage(HealthState.new(MAX_HEALTH), MAX_HEALTH)
		local stillDead = HealthState.damage(dead, 25)

		expect(stillDead.current).toBe(0)
		expect(HealthState.isDead(stillDead)).toBe(true)
	end)

	it("repeated death transitions are idempotent", function()
		local dead = HealthState.damage(HealthState.new(MAX_HEALTH), MAX_HEALTH)
		local deadAgain = HealthState.damage(dead, MAX_HEALTH)

		expect(deadAgain).toEqual(dead)
	end)

	it("cannot heal a dead state back to life", function()
		local dead = HealthState.damage(HealthState.new(MAX_HEALTH), MAX_HEALTH)
		local healed = HealthState.heal(dead, 50)

		expect(healed.current).toBe(0)
		expect(HealthState.isDead(healed)).toBe(true)
	end)

	it("a fresh state for a new character is unaffected by the old one's death", function()
		local dead = HealthState.damage(HealthState.new(MAX_HEALTH), MAX_HEALTH)
		local respawned = HealthState.new(MAX_HEALTH)

		expect(HealthState.isDead(dead)).toBe(true)
		expect(respawned.current).toBe(MAX_HEALTH)
		expect(HealthState.isDead(respawned)).toBe(false)
	end)
end)
