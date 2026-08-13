--!strict
--[[
	Covers the developer allow-list lookup.

	canUseTestCommands is not covered here: it branches on
	RunService:IsStudio() and needs a real Player, so it is a Studio check —
	see "Manual verification: test command access" in docs/testing.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DeveloperAccess = require(ServerScriptService.Server.DeveloperAccess)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

-- A UserId that is actually on the list, so the positive case is covered.
-- Without this, `isDeveloperUserId` could be `return false` and every other
-- assertion here would still pass. Update it if this person leaves the
-- project — a failure here means the list changed, which is worth noticing.
local A_CONFIGURED_DEVELOPER = 11399930306

describe("DeveloperAccess.isDeveloperUserId", function()
	it("accepts a UserId that is on the list", function()
		expect(DeveloperAccess.isDeveloperUserId(A_CONFIGURED_DEVELOPER)).toBe(true)
	end)

	it("rejects a UserId that is not on the list", function()
		expect(DeveloperAccess.isDeveloperUserId(1)).toBe(false)
	end)

	it("returns a boolean rather than the raw table value", function()
		-- The list stores `true`, and a missing key reads as nil. Callers gate
		-- on this directly, so nil leaking out would be a silent bug.
		expect(typeof(DeveloperAccess.isDeveloperUserId(2))).toBe("boolean")
	end)

	it("rejects UserIds that could never be real", function()
		-- Guards against an `if userId then` style check creeping in: 0 and
		-- negatives are truthy in Luau.
		expect(DeveloperAccess.isDeveloperUserId(0)).toBe(false)
		expect(DeveloperAccess.isDeveloperUserId(-1)).toBe(false)
	end)
end)
