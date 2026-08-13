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

	`distance` is studs between the two HumanoidRootParts, after
	`perceivedDistance` has corrected it for replication lag — see there for
	why the raw distance is the wrong thing to test a moving target against.
	`facingDot` is the dot product of the attacker's look vector with the unit
	vector pointing at the target: 1 is dead ahead, 0 is directly beside, -1 is
	directly behind, and it is always computed from live positions.
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
	The distance a hit should actually be judged against, given that the
	attacker was aiming at a copy of the target that is always slightly behind
	where the server thinks the target is.

	Every client renders other players from replicated state, so the target on
	the attacker's screen is where the target *was*, roughly a round trip ago.
	A target running away is therefore drawn nearer than the server believes it
	to be, by its own speed times that delay, and an attacker who punches when
	the target looks in reach is judged against a position the target has
	already left. That gap is what makes a chase miss while a stationary
	opponent connects.

	`recedeSpeed` is how fast the target is pulling away along the line from
	the attacker to it, in world terms — the attacker's own speed is
	deliberately not subtracted, because it is the target's replicated position
	that is stale, never the attacker's own character. In a steady chase both
	players move at the same speed and the *separation* barely changes, yet the
	target's copy is still a full sprint's worth of travel behind. Subtracting
	the attacker's velocity here would cancel the correction in exactly the
	case it exists for.

	Only the distance is corrected. The cone is judged from live positions, so
	no amount of compensation can bring somebody beside or behind the attacker
	into reach.

	A target standing still, or closing in, gets no allowance at all: the
	clamp floors at zero, so this can never make a punch harder to land than
	it was without it.
]]
function PunchRules.perceivedDistance(
	distance: number,
	recedeSpeed: number,
	compensationSeconds: number,
	maxCompensationStuds: number
): number
	local allowance = math.clamp(recedeSpeed * compensationSeconds, 0, maxCompensationStuds)
	return math.max(distance - allowance, 0)
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
