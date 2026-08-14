--!strict
--[[
	CombatService — decides who gets hit by a punch, and for how much.

	The client tells the server one thing: "I punched." It does not say who it
	hit, how far away they were, or how much damage to deal, because the
	PunchRequest remote carries no arguments at all. Everything below is
	computed from the server's own view of where characters are standing, so
	the only thing a modified client can influence is how often it asks — and
	that is rate-limited here with the same cooldown the honest client uses.

	Reach is judged against where the attacker's screen showed each target
	rather than where the server has it right now, because a replicated
	character is always drawn a little behind. The correction is bounded, is
	computed from the target's own server-side velocity, and applies to
	distance only — see PunchRules.perceivedDistance.

	Damage goes through HealthService rather than touching Humanoid.Health, so
	the existing clamping, death and respawn rules apply unchanged.

	Stamina changes what a swing costs and what it is worth, not how it is
	resolved: every accepted swing spends Config.PunchStaminaCost, and one thrown
	on an empty pool deals Config.ZeroStaminaPunchDamageMultiplier of the normal
	damage. Both come from StaminaService, which owns the number; nothing about
	target selection, reach or the parry gates below changed, and a punch on an
	empty pool still lands, still hurts, and is still stopped by a guard.

	Parrying adds two gates and changes nothing else: an attacker who is in a
	parry cannot swing, and a selected target holding a guard that covers the
	direction the punch came from takes no damage. Both answers come from
	ParryService, which holds the authoritative phase. When nobody is parrying
	both gates are false and everything below runs exactly as it did before.

	A landed punch also makes a sound, from the target's root part, created here
	on the server so both players hear it from where it happened. That is the
	only presentation this service owns, and it is here because it is the only
	place that knows a punch connected — the attacker's client is never told.
	Nothing about the decision above changes for it.

	Follows the HealthService pattern: state in a module-local table keyed by
	Player, Init() registers the remote handler before any client can reach
	it, and per-player state is released on PlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Audio = require(Shared.Util.Audio)
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local PunchRules = require(Shared.Combat.PunchRules)

local HealthService = require(script.Parent.HealthService)
local ParryService = require(script.Parent.ParryService)
local StaminaService = require(script.Parent.StaminaService)

local log = Logger.forScope("CombatService")

local lastPunchAt: { [Player]: number } = {}

local CombatService = {}

--[[
	The player's HumanoidRootPart, or nil if they have no character right now
	(not spawned, mid-respawn, or already left).
]]
local function rootPartOf(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

--[[
	Whether this player currently has a living character. HealthService
	returns nil when there is no character at all, which is not the same as
	being alive, so this cannot be simplified to `not isDead(player)`.
]]
local function isAlive(player: Player): boolean
	return HealthService.isDead(player) == false
end

local function onPunchRequest(attacker: Player)
	local now = os.clock()
	if not PunchRules.canPunch(lastPunchAt[attacker], now, Config.PunchCooldownSeconds) then
		-- Spamming the remote is the one thing a modified client can do here.
		-- Drop it silently rather than logging: a laggy honest client hits
		-- this occasionally too, and a warn per attempt would be a gift to
		-- anyone wanting to flood the output.
		return
	end

	-- No punching out of a guard, whether the parry is still winding up or is
	-- already held: both hands are busy either way. PunchController refuses to
	-- play the swing too, but that gate is presentation — this is the one that
	-- decides, and it is here rather than in ParryService so the punch keeps a
	-- single authoritative path.
	--
	-- Checked before the cooldown is recorded, unlike the hit checks below. A
	-- swing that misses is still a swing and costs the attacker their cooldown;
	-- this one never happened at all. Charging for it would eat the counterpunch
	-- of anyone whose release of Q is still in flight when they click.
	if ParryService.isEngaged(attacker) then
		return
	end

	-- Recorded before the hit checks, so a swing that connects with nothing
	-- still costs the attacker their cooldown.
	lastPunchAt[attacker] = now

	local attackerRoot = rootPartOf(attacker)
	if attackerRoot == nil or not isAlive(attacker) then
		return
	end

	-- Stamina is charged here: late enough that a dead player is not billed for
	-- a swing they could not have thrown -- PunchController still fires the
	-- request on a click made with no character, since it has no animation left
	-- to gate on -- and early enough that a swing which finds nobody still
	-- costs, exactly as it costs the cooldown recorded above.
	--
	-- The multiplier is read BEFORE the cost is taken, so the swing is judged by
	-- the stamina the attacker had when they threw it. Reading it afterwards
	-- would make the punch that empties the pool land at reduced damage on a bar
	-- the player watched as full, which reads as a bug rather than as a cost;
	-- this way that punch lands in full and the next one is the weak one.
	local damageMultiplier = StaminaService.punchDamageMultiplier(attacker)
	StaminaService.consume(attacker, Config.PunchStaminaCost)

	local origin = attackerRoot.Position
	local lookVector = attackerRoot.CFrame.LookVector

	-- Three parallel arrays: PunchRules works in plain numbers so it can be
	-- unit tested, so the Player instances stay here and are matched back up
	-- by index. The root parts are kept alongside them so the parry check below
	-- can read the winner's facing without a second character lookup that could
	-- return nil for a character that went away mid-loop.
	local candidates: { PunchRules.Candidate } = {}
	local targets: { Player } = {}
	local targetRoots: { BasePart } = {}

	for _, target in Players:GetPlayers() do
		if target == attacker or not isAlive(target) then
			continue
		end

		local targetRoot = rootPartOf(target)
		if targetRoot == nil then
			continue
		end

		local offset = targetRoot.Position - origin
		local distance = offset.Magnitude
		-- Two characters occupying the same spot have no meaningful direction
		-- between them; treat that as dead ahead rather than normalising a
		-- zero vector.
		local direction = if distance > 0 then offset.Unit else lookVector

		table.insert(targets, target)
		table.insert(targetRoots, targetRoot)
		table.insert(candidates, {
			-- Judged against where the attacker saw this target rather than
			-- where it is now, so a target sprinting away is not missed purely
			-- because its replicated copy lags. See PunchRules.
			distance = PunchRules.perceivedDistance(
				distance,
				targetRoot.AssemblyLinearVelocity:Dot(direction),
				Config.PunchLagCompensationSeconds,
				Config.PunchMaxCompensationStuds
			),
			facingDot = lookVector:Dot(direction),
		})
	end

	local index =
		PunchRules.selectTargetIndex(candidates, Config.PunchRange, Config.PunchMinFacingDot)
	if index == nil then
		return
	end

	local target = targets[index]

	-- The parry is the last gate before damage, deliberately after selection
	-- rather than during it: a guarding player absorbs the punch aimed at them
	-- instead of being skipped as a candidate, so a punch never passes through
	-- somebody's guard to reach whoever is standing behind them. The attacker
	-- has already paid the cooldown either way.
	if ParryService.isProtectedFrom(target, targetRoots[index], origin) then
		log.info(`{target.Name} parried {attacker.Name}`)
		return
	end

	-- Derived from PunchDamage rather than written down, so the reduced hit is
	-- always a fraction of the real one and retuning the punch retunes both.
	local damage = Config.PunchDamage * damageMultiplier
	local remaining = HealthService.takeDamage(target, damage)

	-- The impact, played from the target's own HumanoidRootPart. This service
	-- has no hit part and no hitbox to speak of — reach is a distance between
	-- two root parts and the cone is a dot product, so the target's root part
	-- *is* where this architecture says the punch landed, and it is already
	-- resolved above rather than looked up again.
	--
	-- Made on the server, deliberately: a Sound inside a replicated part is
	-- heard by every client near it, so both players hear the hit from the
	-- right place with no remote and no second copy of "did it land". A client
	-- could not do this — it is not told whether its punch connected, which is
	-- the whole point of PunchRequest carrying no arguments.
	--
	-- After the damage rather than before it, so a punch that a guard stopped,
	-- or that reached nobody, plays nothing. A punch thrown on an empty pool
	-- does sound exactly like a full-strength one, which is deliberate: it
	-- landed, and the stamina bar is where that cost is reported. The attacker's
	-- own swing sound is a separate instance on their own client and is
	-- untouched by this.
	Audio.playOnce(Config.PunchImpactSound, targetRoots[index])

	log.info(`{attacker.Name} punched {target.Name} for {damage} -> {remaining}`)
end

function CombatService.Init()
	-- Registered in Init so the handler exists before the first client can
	-- possibly reach the remote.
	local punchRequest = Net.getEvent("PunchRequest")

	-- Any arguments a modified client attaches are ignored by not being
	-- accepted in the first place.
	punchRequest.OnServerEvent:Connect(function(attacker: Player)
		onPunchRequest(attacker)
	end)
end

function CombatService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Without this, every player who has ever punched stays in the table
		-- for the lifetime of the server.
		lastPunchAt[player] = nil
	end)
end

return CombatService
