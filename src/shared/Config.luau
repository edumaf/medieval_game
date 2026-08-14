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
		Humanoid.WalkSpeed while walking normally, while sprinting (Left Shift
		held) and while parrying (Q held). See
		src/client/Controllers/RunningController, which is the only thing that
		writes WalkSpeed — parry outranks sprint, so holding both gives
		ParryWalkSpeed.
	]]
	NormalWalkSpeed = 16,
	SprintWalkSpeed = 24,
	ParryWalkSpeed = 8,

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

	--[[
		Stamina. Authority lives in src/server/Services/StaminaService, which
		owns the pool, runs the one update loop and replicates the value; the
		pure arithmetic is in src/shared/Stamina/StaminaState; the bar is drawn
		by src/client/Controllers/StaminaBarController.

		Shared for the same reason the punch and parry numbers are: a player can
		measure every one of these by playing for a minute, and knowing them does
		not let a modified client drain more slowly. The server integrates the
		pool from its own clock and never accepts a stamina value from anyone.

		The values below are a first pass, tuned on paper rather than in Team
		Test — retune them together once the bar has actually been played with.
	]]

	-- Size of a full stamina pool. Every character spawns with this much.
	MaxStamina = 100,

	-- Stamina spent per second of sprinting, so roughly eight seconds of
	-- continuous sprint from full.
	--
	-- Only ever charged while the server can see the character actually moving:
	-- holding Left Shift standing still is not sprinting, and a player who holds
	-- it out of habit should not be paying for it.
	SprintStaminaDrainPerSecond = 12,

	-- Stamina spent per second of holding a guard, so roughly twelve seconds of
	-- continuous parry from full.
	--
	-- Charged for the whole engaged phase, wind-up included, matching the
	-- slowdown and the punch lockout — see ParryState.isEngaged for why those
	-- start at the key press rather than at the Hold marker.
	--
	-- This outranks the sprint drain rather than stacking with it, exactly as
	-- ParryWalkSpeed outranks SprintWalkSpeed: a player holding both keys is
	-- walking at 8, so charging them for a sprint they are not doing would be
	-- paying twice for one state.
	ParryStaminaDrainPerSecond = 8,

	-- Stamina spent by one valid swing, so ten punches from a full pool.
	--
	-- Charged once per swing the server accepts, at the same point the swing
	-- costs the attacker their cooldown — a punch that misses, or that is
	-- parried, still cost the effort of throwing it.
	PunchStaminaCost = 10,

	-- Stamina restored per second while sprinting, punching and parrying are all
	-- idle, so ten seconds from empty back to full.
	--
	-- There is deliberately no delay before this starts: the pool begins
	-- refilling on the tick after the last stamina-consuming action stops.
	StaminaRegenPerSecond = 10,

	-- What a punch thrown on an empty pool is worth, as a multiplier on
	-- PunchDamage. CombatService multiplies the two, so the reduced damage is
	-- always derived and the number 7.5 appears nowhere.
	ZeroStaminaPunchDamageMultiplier = 0.3,

	-- How full the pool has to be, as a fraction of MaxStamina, before a player
	-- who has run themselves empty may sprint again.
	--
	-- This is the second threshold of a deliberate hysteresis, and it is what
	-- makes exhaustion a state rather than a stutter. A single threshold at zero
	-- would let the first tick of regeneration buy a tick of sprinting: at the
	-- shipped rates the pool would gain 1 and immediately spend 1.2, ten times a
	-- second, and the player would judder between 16 and 24 for as long as they
	-- held the key.
	--
	-- At 0.25 an exhausted player walks for two and a half seconds and gets
	-- about two seconds of sprint back. Raising it lengthens the recovery;
	-- lowering it towards zero brings the judder back. The lockout is released
	-- by this fraction alone and never by the key, so releasing Shift and
	-- pressing it again cannot shorten it -- see StaminaState.sprintLocked.
	SprintRecoveryStaminaFraction = 0.25,

	-- How often StaminaService's single Heartbeat loop actually steps every
	-- player's pool. The step is integrated against real elapsed time, so this
	-- changes how often the pool moves, never how fast it drains.
	StaminaTickIntervalSeconds = 0.1,

	-- How far the pool must move, as a fraction of MaxStamina, before the server
	-- sends the owning client another StaminaChanged. At 0.02 a full-speed drain
	-- costs about five messages a second instead of one per frame; the client
	-- smooths between them. Both ends of the pool are always sent exactly,
	-- whatever this is set to — see StaminaState.shouldReplicate.
	StaminaReplicationStepFraction = 0.02,

	-- How fast a character has to actually be travelling, in studs per second
	-- along the ground, before the server counts them as sprinting. A guard
	-- against paying for a sprint that is not happening (standing still, or
	-- running into a wall), not a gameplay dial.
	StaminaSprintMinMoveSpeed = 1,

	--[[
		Parrying. Authority lives in src/server/Services/ParryService, which
		CombatService consults before it deals damage; input and animation in
		src/client/Controllers/ParryController; the shared phases and the
		direction test in src/shared/Combat/ParryState.

		Shared for the same reason the punch numbers are: a player can measure
		the guard's arc by being hit from behind once, and knowing the number
		does not let a modified client widen it. The server recomputes the
		direction from its own view of where both characters are standing.
	]]

	-- How far in front of the DEFENDER an attack must come from for a held
	-- guard to stop it, as a dot product of the defender's look vector with
	-- the direction the attacker is in: 1 is dead ahead, 0 is directly beside,
	-- -1 is directly behind.
	--
	-- 0 is the forward hemisphere — front, front-left and front-right are
	-- covered, the three rear directions are not. The comparison is >=,
	-- matching PunchRules.isInReach, so an attack from exactly beside the
	-- defender counts as covered.
	--
	-- Raising this narrows the guard towards a frontal cone (0.5 would make it
	-- the same 120 degrees as the punch); it must never go below 0, which
	-- would start protecting the defender's back.
	ParryMinFacingDot = 0,

	-- rbxassetid:// of the parry animation. Empty string means "no animation
	-- uploaded yet" — the parry still works, it just plays nothing and reaches
	-- the guard on the key press instead of on the marker.
	ParryAnimationId = "rbxassetid://82891306050913",

	-- Name of the animation event marker on that animation, placed on the
	-- frame the guard is fully raised. ParryController enters the protected
	-- state when the track reaches it and freezes the track there, so this is
	-- the parry's timing in exactly the way PunchHitMarkerName is the punch's.
	-- A re-export that renames or drops the marker leaves the parry winding up
	-- forever — slowed and unable to punch, but never protected — and nothing
	-- errors. The two values have to be changed together.
	ParryHoldMarkerName = "Hold",

	--[[
		The damage/heal/death screen vignette. Drawn entirely by
		src/client/Controllers/ScreenEffectsController; the rules that turn a
		health change into one of these are in its ScreenEffectState.

		Purely cosmetic, and shared config only because that is where this
		project keeps its tunable numbers. Nothing on the server reads any of
		them, and nothing a player could learn from them is worth hiding — the
		vignette reports health the player can already see on their own health
		bar.
	]]

	-- The three colours the vignette is tinted with. Damage and death are both
	-- red so they read as the same language, with death darker and far
	-- stronger; healing is green so it cannot be mistaken for either.
	ScreenEffectDamageColor = Color3.fromRGB(150, 15, 15),
	ScreenEffectHealColor = Color3.fromRGB(40, 175, 65),
	ScreenEffectDeathColor = Color3.fromRGB(110, 0, 0),

	-- Peak opacity at the screen edge for a health change, as a fraction of
	-- the health bar that moved: losing everything reaches the maximum, and
	-- the smallest change still reaches the minimum so a scratch is visible
	-- rather than invisible.
	--
	-- The maximum is deliberately below the death intensity below. Dying has
	-- to be unmistakably stronger than being hit hard, and that is only true
	-- while these two stay ordered.
	ScreenEffectMinIntensity = 0.25,
	ScreenEffectMaxIntensity = 0.75,
	ScreenEffectDeathIntensity = 1,

	-- Health changes smaller than this are not drawn at all. Roblox's own
	-- passive regeneration moves a Humanoid by roughly a tenth of a point at a
	-- time, and HealthService snaps each of those back to its authoritative
	-- value (see docs/decisions.md), so both edges of that correction reach
	-- the client as health changes. Without a floor the screen would flicker
	-- red and green while nothing was happening.
	ScreenEffectMinHealthChange = 1,

	-- How far in from each screen edge the vignette reaches, as a fraction of
	-- the screen. The four bands are drawn one per edge and fade to nothing
	-- towards the middle, so the centre stays clear at the resting reach; at
	-- 0.5 opposite bands meet and the whole screen is covered.
	--
	-- The death reach is what makes dying expand towards the centre rather
	-- than merely darken, so it must stay above the resting one.
	ScreenEffectEdgeReach = 0.22,
	ScreenEffectDeathEdgeReach = 0.45,

	-- How long a health-change vignette takes to reach its peak and then fade
	-- away again. The rise is short because the point of it is to tell the
	-- player they were hit at the moment they were hit.
	ScreenEffectRiseSeconds = 0.06,
	ScreenEffectFadeSeconds = 0.45,

	-- Death takes far longer, and does not fade on its own: it grows from the
	-- edges to its peak over this long and then stays there until the player
	-- respawns. That slow spread is the whole difference between dying and
	-- being hit.
	ScreenEffectDeathRiseSeconds = 1.2,

	-- How long the vignette takes to disappear when a new character arrives.
	-- Short, but not instant — a death vignette that vanished on one frame
	-- would read as a glitch rather than as respawning.
	ScreenEffectClearSeconds = 0.3,

	--[[
		Sound. Each entry is a Types.SoundSpec: an asset id, a volume, a
		playback speed, and how far away it can be heard.

		An empty `id` means "no sound uploaded yet" and is a supported state,
		exactly as it is for the punch and parry animations: the system still
		works, it just plays nothing. Audio.create returns nil for one.

		Only PunchImpactSound is actually positional. The other three are
		parented to SoundService rather than to a character, and Roblox ignores
		roll-off entirely for a Sound that is not under a BasePart — so their
		distances below are inert, and are there so a spec that is later moved
		onto a character behaves without having to grow new fields.

		Frozen individually because table.freeze is shallow. Without this the
		nested tables would be the one writable corner of a config the rest of
		the game is guaranteed cannot change under it.
	]]

	-- The fist travelling, not the impact. Played by PunchController the moment
	-- the swing animation starts, and fitted to that animation's length — see
	-- the playback speed bounds below.
	--
	-- Heard by the attacker alone, and so flat: sounds made on a client do not
	-- replicate, and the attacker is always exactly where their own listener
	-- is, so a position would make no audible difference. Making it audible to
	-- everyone would mean moving it onto the character *and* adding a remote
	-- whose only purpose is a sound — see docs/decisions.md.
	PunchSwingSound = table.freeze({
		id = "rbxassetid://71966554416300",
		volume = 0.5,
		playbackSpeed = 1,
		rollOffMinDistance = 6,
		rollOffMaxDistance = 45,
	}),

	-- The hit landing. Played by CombatService, on the server, from the
	-- target's HumanoidRootPart, so both players hear it from where the punch
	-- actually connected. This one is genuinely positional, and carries
	-- further than the swing would: a punch you can see across a courtyard
	-- should be a punch you can hear.
	PunchImpactSound = table.freeze({
		id = "rbxassetid://120665243125186",
		volume = 0.7,
		playbackSpeed = 1,
		rollOffMinDistance = 8,
		rollOffMaxDistance = 80,
	}),

	-- The two health-feedback sounds, played by ScreenEffectsController for the
	-- local player only and flat for the same reason the swing is — this is
	-- your own body reporting to you, not something happening at a place in
	-- the world.
	--
	-- Their volume is driven by the same 0-to-1 level that drives the vignette,
	-- so each one fades in and out exactly with the red or green on screen and
	-- has no duration of its own to keep in step. These are the peak volumes
	-- that level is scaled against.
	ScreenEffectDamageSound = table.freeze({
		id = "rbxassetid://95780005590485",
		volume = 0.6,
		playbackSpeed = 1,
		rollOffMinDistance = 10,
		rollOffMaxDistance = 60,
	}),
	ScreenEffectHealSound = table.freeze({
		id = "rbxassetid://119704275114635",
		volume = 0.5,
		playbackSpeed = 1,
		rollOffMinDistance = 10,
		rollOffMaxDistance = 60,
	}),

	-- How far the swing sound may be pitched to fit the punch animation.
	--
	-- Fitting exactly would mean playing it at `soundLength / animationLength`,
	-- which for a sound much longer than the swing is a large pitch shift and
	-- sounds like a different sound. These bounds cap that at roughly a tone
	-- either way; anything the cap refuses is taken off the end with a fade
	-- instead, which is inaudible where pitching is not.
	PunchSwingMinPlaybackSpeed = 0.85,
	PunchSwingMaxPlaybackSpeed = 1.3,

	-- How long that fade takes. Long enough not to click, short enough that the
	-- tail does not outlast the swing it belongs to.
	PunchSwingFadeSeconds = 0.08,
}

return table.freeze(Config)
