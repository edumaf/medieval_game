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

	Follows the HealthService pattern: state in a module-local table keyed by
	Player, Init() registers the remote handler before any client can reach
	it, and per-player state is released on PlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local PunchRules = require(Shared.Combat.PunchRules)

local HealthService = require(script.Parent.HealthService)

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
	-- Recorded before the hit checks, so a swing that connects with nothing
	-- still costs the attacker their cooldown.
	lastPunchAt[attacker] = now

	local attackerRoot = rootPartOf(attacker)
	if attackerRoot == nil or not isAlive(attacker) then
		return
	end

	local origin = attackerRoot.Position
	local lookVector = attackerRoot.CFrame.LookVector

	-- Two parallel arrays: PunchRules works in plain numbers so it can be
	-- unit tested, so the Player instances stay here and are matched back up
	-- by index.
	local candidates: { PunchRules.Candidate } = {}
	local targets: { Player } = {}

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
	local remaining = HealthService.takeDamage(target, Config.PunchDamage)
	log.info(`{attacker.Name} punched {target.Name} for {Config.PunchDamage} -> {remaining}`)
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
