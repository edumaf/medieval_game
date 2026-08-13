--!strict
--[[
	HealthService — the server's authoritative record of every player's
	health.

	Health lives entirely in this module's local state, keyed by Player. The
	server is the only writer: other server systems (future Combat, etc.) call
	takeDamage/heal directly — there is no remote for mutating health, and
	there must not be one. Humanoid.Health/MaxHealth are mirrored one-way from
	this state, purely so Roblox's own death/ragdoll handling (and any future
	health bar) have something to read. See docs/decisions.md for why this
	project keeps its own state instead of trusting Humanoid.Health directly.

	Follows the SessionService pattern: state in a module-local table, Init()
	registers nothing that depends on another module, Start() connects to
	Players/Humanoid events and catches up on anyone already here, and
	everything per-character is released on CharacterRemoving, with a second,
	defensive release on PlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local DeveloperAccess = require(script.Parent.Parent.DeveloperAccess)
local Logger = require(Shared.Util.Logger)

local HealthState = require(script.HealthState)

local log = Logger.forScope("HealthService")

type Record = {
	state: HealthState.HealthState,
	humanoid: Humanoid,
	healthChangedConn: RBXScriptConnection?,
	diedConn: RBXScriptConnection?,
}

local records: { [Player]: Record } = {}

local HealthService = {}

--[[
	Writes `record.state.current` onto the Humanoid so Roblox's own
	death/ragdoll handling and any future health bar see the authoritative
	value. This is also what corrects Humanoid.Health back to the
	authoritative value inside the HealthChanged handler below; once the two
	already match, applying it again is a no-op, so that cannot loop.
]]
local function applyToHumanoid(record: Record)
	record.humanoid.Health = record.state.current
end

--[[
	Disconnects and forgets whatever character is currently tracked for
	`player`, if any. Safe to call when there is nothing to release.
]]
local function releaseCharacter(player: Player)
	local record = records[player]
	if record == nil then
		return
	end

	if record.healthChangedConn then
		record.healthChangedConn:Disconnect()
	end
	if record.diedConn then
		record.diedConn:Disconnect()
	end
	records[player] = nil
end

local function onCharacterAdded(player: Player, character: Model)
	-- A respawn calls this again; drop whatever the previous character left
	-- behind first so its connections and health state cannot leak into the
	-- new one.
	releaseCharacter(player)

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = Config.NormalHealth

	local record: Record = {
		state = HealthState.new(Config.NormalHealth),
		humanoid = humanoid,
		healthChangedConn = nil,
		diedConn = nil,
	}
	records[player] = record

	record.healthChangedConn = humanoid.HealthChanged:Connect(function()
		-- Anything that moved Humanoid.Health without going through this
		-- service — Roblox's built-in passive regen, fall damage, or a
		-- modified client — gets corrected back to the authoritative value.
		if humanoid.Health ~= record.state.current then
			applyToHumanoid(record)
		end
	end)

	record.diedConn = humanoid.Died:Connect(function()
		log.info(`{player.Name}'s Humanoid died`)
	end)

	applyToHumanoid(record)
end

--[[
	Current health, or nil if the player has no active character (not spawned
	yet, or already left).
]]
function HealthService.getHealth(player: Player): number?
	local record = records[player]
	return if record then record.state.current else nil
end

--[[
	Max health for the player's active character, or nil if there is none.
]]
function HealthService.getMaxHealth(player: Player): number?
	local record = records[player]
	return if record then record.state.max else nil
end

--[[
	Whether the player's active character is dead, or nil if there is none.
]]
function HealthService.isDead(player: Player): boolean?
	local record = records[player]
	return if record then HealthState.isDead(record.state) else nil
end

--[[
	Applies damage to the player's active character. Returns the resulting
	health, or nil if the player has no active character. See
	HealthState.damage for the clamping and death rules; this only adds the
	Humanoid mirror and a death log line, logged exactly once per death.
]]
function HealthService.takeDamage(player: Player, amount: number): number?
	local record = records[player]
	if record == nil then
		return nil
	end

	local wasDead = HealthState.isDead(record.state)
	record.state = HealthState.damage(record.state, amount)
	applyToHumanoid(record)

	if not wasDead and HealthState.isDead(record.state) then
		log.info(`{player.Name} reached 0 health`)
	end

	return record.state.current
end

--[[
	Restores health to the player's active character. Returns the resulting
	health, or nil if the player has no active character. See HealthState.heal
	for the clamping rules and why a dead character cannot be healed.
]]
function HealthService.heal(player: Player, amount: number): number?
	local record = records[player]
	if record == nil then
		return nil
	end

	record.state = HealthState.heal(record.state, amount)
	applyToHumanoid(record)
	return record.state.current
end

--[[
	Manual test hook: typing "/damage 20" or "/heal 20" in chat calls the
	matching API above. There is no Combat system yet to exercise
	takeDamage/heal by hand any other way. Who may reach this is decided by
	DeveloperAccess — see that module for why it is not a plain IsStudio()
	check.
]]
local function onChatted(player: Player, message: string)
	local command, amountText = string.match(message, "^/(%a+)%s+(%-?%d+)$")
	local amount = amountText and tonumber(amountText)
	if amount == nil then
		return
	end

	if command == "damage" then
		log.info(`{player.Name} /damage {amount} -> {HealthService.takeDamage(player, amount)}`)
	elseif command == "heal" then
		log.info(`{player.Name} /heal {amount} -> {HealthService.heal(player, amount)}`)
	end
end

--[[
	Wires up one player: current and future characters, and — for whoever
	DeveloperAccess allows — the manual damage/heal chat commands.
	Player.CharacterAdded,
	Player.CharacterRemoving and Player.Chatted are events on the Player
	instance itself, which Roblox disconnects automatically when the player
	leaves, so — unlike the per-character Humanoid connections above — these
	never need an explicit disconnect.
]]
local function attachPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		-- Releases immediately rather than waiting for the next spawn, so no
		-- stale Humanoid reference or connection sits around between a
		-- character being removed and the (possibly delayed) respawn.
		releaseCharacter(player)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	if DeveloperAccess.canUseTestCommands(player) then
		player.Chatted:Connect(function(message: string)
			onChatted(player, message)
		end)
	end
end

function HealthService.Start()
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(releaseCharacter)

	-- A player — and possibly their character — can already exist before this
	-- service starts.
	for _, player in Players:GetPlayers() do
		attachPlayer(player)
	end
end

return HealthService
