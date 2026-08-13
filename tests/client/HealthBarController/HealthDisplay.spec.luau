--!strict
--[[
	Covers the pure health-to-presentation maths HealthBarController pushes
	onto Fill.Size and Amount.Text. No Humanoid, ScreenGui or PlayerGui
	involved here -- see docs/testing.md for the Studio steps that cover the
	wiring itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local HealthDisplay =
	require(StarterPlayer.StarterPlayerScripts.Client.Controllers.HealthBarController.HealthDisplay)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local MAX_HEALTH = 100

describe("HealthBarController.HealthDisplay", function()
	describe("fillFraction", function()
		it("fills the bar completely at full health", function()
			expect(HealthDisplay.fillFraction(MAX_HEALTH, MAX_HEALTH)).toBe(1)
		end)

		it("fills proportionally between empty and full", function()
			expect(HealthDisplay.fillFraction(75, MAX_HEALTH)).toBe(0.75)
			expect(HealthDisplay.fillFraction(50, MAX_HEALTH)).toBe(0.5)
			expect(HealthDisplay.fillFraction(25, MAX_HEALTH)).toBe(0.25)
		end)

		it("empties the bar at zero health", function()
			expect(HealthDisplay.fillFraction(0, MAX_HEALTH)).toBe(0)
		end)

		it("handles fractional health", function()
			expect(HealthDisplay.fillFraction(12.5, MAX_HEALTH)).toBe(0.125)
		end)

		it("clamps health above the maximum to a full bar", function()
			expect(HealthDisplay.fillFraction(MAX_HEALTH + 50, MAX_HEALTH)).toBe(1)
		end)

		it("clamps negative health to an empty bar", function()
			expect(HealthDisplay.fillFraction(-10, MAX_HEALTH)).toBe(0)
		end)

		it("returns 0 rather than NaN when MaxHealth is zero", function()
			local fraction = HealthDisplay.fillFraction(0, 0)

			expect(fraction).toBe(0)
			-- Guards the reason for the special case: NaN would corrupt the
			-- UDim2 rather than merely look wrong.
			expect(fraction ~= fraction).toBe(false)
		end)

		it("returns 0 rather than infinity when MaxHealth is zero but health is not", function()
			expect(HealthDisplay.fillFraction(50, 0)).toBe(0)
		end)

		it("returns 0 when MaxHealth is negative", function()
			expect(HealthDisplay.fillFraction(50, -100)).toBe(0)
		end)
	end)

	describe("text", function()
		it("shows current over maximum", function()
			expect(HealthDisplay.text(MAX_HEALTH, MAX_HEALTH)).toBe("100/100")
			expect(HealthDisplay.text(75, MAX_HEALTH)).toBe("75/100")
			expect(HealthDisplay.text(25, MAX_HEALTH)).toBe("25/100")
		end)

		it("shows exactly zero as 0", function()
			expect(HealthDisplay.text(0, MAX_HEALTH)).toBe("0/100")
		end)

		it("rounds fractional health up", function()
			expect(HealthDisplay.text(12.5, MAX_HEALTH)).toBe("13/100")
			expect(HealthDisplay.text(0.4, MAX_HEALTH)).toBe("1/100")
		end)

		it("never shows 0 health while the character is still alive", function()
			for _, health in { 0.01, 0.1, 0.4, 0.5, 0.9 } do
				expect(HealthDisplay.text(health, MAX_HEALTH)).never.toBe("0/100")
			end
		end)

		it("never shows more than the maximum", function()
			expect(HealthDisplay.text(MAX_HEALTH + 50, MAX_HEALTH)).toBe("100/100")
		end)

		it("shows negative health as 0", function()
			expect(HealthDisplay.text(-10, MAX_HEALTH)).toBe("0/100")
		end)

		it("shows a whole number for a fractional maximum", function()
			expect(HealthDisplay.text(50, 99.5)).toBe("50/100")
		end)

		it("stays coherent when MaxHealth is zero or negative", function()
			expect(HealthDisplay.text(0, 0)).toBe("0/0")
			expect(HealthDisplay.text(50, 0)).toBe("0/0")
			expect(HealthDisplay.text(50, -100)).toBe("0/0")
		end)
	end)
end)
