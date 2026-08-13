--!strict
--[[
	PunchRules — the pure arithmetic behind a punch.

	Shared rather than server-only on purpose. The server is still the only
	thing that *enforces* these rules; the client reuses `canPunch` purely to
	avoid firing a remote it already knows the server will reject. Duplicating
	that one predicate on both sides is how the two quietly drift apart.

	Nothing here is secret. Knowing the reach or the cone angle does not let a
	modified client punch further — the server recomputes both from its own
	view of where everyone is standing.

	No Roblox types in this file: distances and dot products arrive as plain
	numbers, so all of it is unit-testable without a character or a Humanoid.
]]

--[[
	One possible target, already reduced to numbers by the caller.

	`distance` is studs between the two HumanoidRootParts. `facingDot` is the
	dot product of the attacker's look vector with the unit vector pointing at
	the target: 1 is dead ahead, 0 is directly beside, -1 is directly behind.
]]
export type Candidate = {
	distance: number,
	facingDot: number,
}

local PunchRules = {}

--[[
	Whether enough time has passed since the last punch.

	`lastPunchAt` is nil for a player who has never punched. Both timestamps
	must come from the same clock — compare server times with server times.

	A negative elapsed time (a clock that went backwards) is treated as ready
	rather than blocked, so a bad reading can never lock someone out of
	punching for the rest of the round.
]]
function PunchRules.canPunch(lastPunchAt: number?, now: number, cooldownSeconds: number): boolean
	if lastPunchAt == nil then
		return true
	end

	local elapsed = now - lastPunchAt
	return elapsed < 0 or elapsed >= cooldownSeconds
end

--[[
	Whether a candidate is close enough and far enough in front to be hit.
]]
function PunchRules.isInReach(candidate: Candidate, maxRange: number, minFacingDot: number): boolean
	return candidate.distance <= maxRange and candidate.facingDot >= minFacingDot
end

--[[
	Index of the nearest candidate that is in reach, or nil if none are.

	Returns an index rather than the target itself so this stays free of
	Roblox types; the caller keeps its own parallel array of Players.

	Nearest wins so that punching into a crowd hits whoever you are actually
	stood against, rather than whichever player happens to be first in
	Players:GetPlayers().
]]
function PunchRules.selectTargetIndex(
	candidates: { Candidate },
	maxRange: number,
	minFacingDot: number
): number?
	local bestIndex: number? = nil
	local bestDistance = math.huge

	for index, candidate in candidates do
		if
			PunchRules.isInReach(candidate, maxRange, minFacingDot)
			and candidate.distance < bestDistance
		then
			bestIndex = index
			bestDistance = candidate.distance
		end
	end

	return bestIndex
end

return PunchRules
