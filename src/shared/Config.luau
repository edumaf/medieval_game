--!strict
--[[
	Config — tunable values that both the server and the client read.

	Rules:
	  * Values here are constants, not state. The table is frozen; nothing may
	    write to it at runtime.
	  * Anything the client must not know (drop tables, exploit thresholds,
	    economy rates) does NOT belong here — ReplicatedStorage is visible to
	    every client. Put those in a server-only module.
]]

export type LogLevel = "debug" | "info" | "warn"

local Config = {
	--[[
		Bumped by hand on every release. The client sends this to the server
		during the handshake so we can spot players on a stale client build.
	]]
	GameVersion = "0.1.0",

	--[[
		Lowest level that Util/Logger will print. Set to "debug" while working
		on a system; leave it at "info" on main.
	]]
	LogLevel = "info" :: LogLevel,

	--[[
		Humanoid.WalkSpeed while walking normally and while sprinting (Left
		Shift held). See src/client/Controllers/RunningController.
	]]
	NormalWalkSpeed = 16,
	SprintWalkSpeed = 24,

	--[[
		Health (and max health) every character starts at and is restored to on
		respawn. See src/server/Services/HealthService.
	]]
	NormalHealth = 100,

	--[[
		Punching. Authority lives in src/server/Services/CombatService; input
		and animation in src/client/Controllers/PunchController; the shared
		arithmetic in src/shared/Combat/PunchRules.

		These sit in shared config rather than a server-only module even
		though the server validates against them, because none of them are
		worth hiding: a player can measure the reach and the cooldown by
		playing for a minute, and knowing the numbers does not let a modified
		client exceed them. The server recomputes every check from its own
		view of the world.
	]]

	-- Damage a landed punch deals.
	PunchDamage = 25,

	-- Maximum studs between the two HumanoidRootParts for a punch to land.
	--
	-- Default R15 HumanoidRootPart is 2x2x1 studs, so two characters standing
	-- front-to-front and touching are roughly 1 stud apart center to center
	-- (0.5 + 0.5), not the ~4 this comment originally claimed -- that wrong
	-- estimate is why 7, then 5, both let punches land across a gap visibly
	-- wider than an arm's reach. An R15 arm is roughly 2 studs from shoulder
	-- to fist, and the shoulder sits close to the torso surface, so a fully
	-- extended punch reaches about touching-distance (~1) + arm length (~2)
	-- + the target's own near-side offset (~0.5) from their root part.
	--
	-- That estimate came out around 3.5, and 3 was tried in Team Test. Both
	-- were tightened too far once two players were actually moving: at 3 a
	-- punch that visibly connected during a chase would miss. 4.5 is where
	-- playtesting landed, and it is deliberately above the static geometry —
	-- the lag allowance below only returns part of a moving target's error,
	-- so the reach has to carry the rest.
	--
	-- Retune this and PunchMaxCompensationStuds together. Raising one to fix
	-- chases while leaving the other is what produces a punch that lands from
	-- further than an arm looks.
	PunchRange = 4.5,

	-- Minimum seconds between one player's punches.
	PunchCooldownSeconds = 0.6,

	-- How far in front of you a target must be, as a dot product: 0.5 is a
	-- 120-degree cone, so you can hit someone slightly off to the side but
	-- never behind you.
	PunchMinFacingDot = 0.5,

	-- How far behind the server's view of the world the attacker's screen is
	-- assumed to be. A target running away is drawn nearer than it really is
	-- by its own speed times this, and PunchRules.perceivedDistance gives that
	-- much back before judging reach. Roughly a round trip on an ordinary
	-- connection.
	--
	-- A fixed value rather than the attacker's measured ping on purpose.
	-- Player:GetNetworkPing is undocumented enough that community sources
	-- disagree over whether it returns seconds or milliseconds — reading it in
	-- the wrong unit would silently pin every punch to the cap — and deriving
	-- reach from a number the attacker's own connection influences hands more
	-- range to worse connections. A constant treats everyone the same and can
	-- be tuned once the punch has been played.
	PunchLagCompensationSeconds = 0.15,

	-- Hard ceiling on that allowance, whatever the target's speed.
	--
	-- At the sprint speed above the uncorrected error is about 3.6 studs,
	-- which is now most of an entire PunchRange. Handing all of it back would
	-- give a sprinting runaway an effective reach past 8 — wider than the 7
	-- and 5 that were both tightened away for landing punches across a visible
	-- gap. So this deliberately returns only part of the error: a chase punch
	-- reaches about 6.5, and some genuinely-saw-it-connect punches on a
	-- full-sprint target will still miss.
	--
	-- That trade only exists while the reach is this tight relative to the
	-- sprint speed. Raise this if chases still feel unresponsive, lower it if
	-- punches start landing from further than an arm looks; a stationary
	-- target is unaffected either way, because its allowance is always zero.
	PunchMaxCompensationStuds = 2,

	-- rbxassetid:// of the punch animation (Punch_Right, R15). Empty string
	-- means "no animation uploaded yet" — the punch still works, it just
	-- plays nothing and reports the hit on the click instead.
	PunchAnimationId = "rbxassetid://86842108763107",

	-- Name of the animation event marker on that animation, placed on the
	-- frame where the fist connects. PunchController fires PunchRequest when
	-- the track reaches it, so this is the attack's timing — a re-export that
	-- renames or drops the marker stops punches landing, and the two values
	-- have to be changed together.
	PunchHitMarkerName = "Hit",
}

return table.freeze(Config)
