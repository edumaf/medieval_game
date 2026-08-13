--!strict
--[[
	HealthDisplay — pure health-to-presentation maths, kept separate from
	HealthBarController so it is testable without a Humanoid or a ScreenGui.
	Mirrors RunningController/SprintState.luau and HealthService/HealthState.luau.

	Everything here takes plain numbers and returns plain values. It never
	touches an Instance, so a bad Humanoid value can be tested directly rather
	than reproduced in Studio.

	Rounding policy for the label:
	  * Exactly zero health shows "0". A dead character reads as dead.
	  * Any health above zero rounds UP, so 0.4 shows as "1" rather than "0" —
	    the label must never say 0 while the character is still alive.
	  * MaxHealth rounds up too. Rounding both the same direction is what
	    guarantees the left number never exceeds the right one, since health is
	    clamped into [0, max] first.
]]

local HealthDisplay = {}

--[[
	Health clamped into the range the bar can actually represent. A Humanoid
	can report values outside it (overheal, or a negative left by another
	system), and both the fill and the label need the same clamped number or
	they would disagree.
]]
local function clampHealth(health: number, maxHealth: number): number
	return math.clamp(health, 0, math.max(maxHealth, 0))
end

--[[
	Fraction of the bar to fill, always within [0, 1].

	A MaxHealth of zero or less has no meaningful fill, so it returns 0 rather
	than dividing: 0/0 is NaN and x/0 is infinity, and either one reaching a
	UDim2 corrupts the bar instead of just looking wrong.
]]
function HealthDisplay.fillFraction(health: number, maxHealth: number): number
	if maxHealth <= 0 then
		return 0
	end

	local fraction = health / maxHealth
	-- NaN is the one value math.clamp cannot rescue, and it only gets here if
	-- Humanoid.Health itself is NaN.
	if fraction ~= fraction then
		return 0
	end

	return math.clamp(fraction, 0, 1)
end

--[[
	The "current/max" string for the Amount label. See the rounding policy at
	the top of this file.
]]
function HealthDisplay.text(health: number, maxHealth: number): string
	local displayMax = math.max(math.ceil(maxHealth), 0)

	local clamped = clampHealth(health, maxHealth)
	local displayHealth = if clamped <= 0 then 0 else math.ceil(clamped)

	return `{displayHealth}/{displayMax}`
end

return HealthDisplay
