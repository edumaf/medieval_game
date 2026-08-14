--!strict
--[[
	StaminaService — the server's authoritative record of every player's
	stamina.

	Stamina lives entirely in this module's local state, keyed by Player, and the
	server is the only writer. No remote carries a stamina value towards the
	server, and there must never be one: the client's only contribution is
	whether it is holding the sprint key (SprintStateRequest, a single boolean),
	and every consequence of that is decided here.

	Three things spend the pool, and each is charged from the system that already
	owns the action rather than from a second copy of it:

	  * Sprinting  — drained by the loop below, while the sprint intent the
	                 client declared is on and the server can see the character
	                 actually moving.
	  * Parrying   — drained by the loop below, while ParryService has the player
	                 engaged. ParryService pushes that bit in on every phase
	                 change; the phase itself stays entirely its own.
	  * Punching   — charged by CombatService, once per swing it accepts.

	When nothing is spending, the same loop regenerates. That is the whole
	design: exactly one Heartbeat connection for the entire server, exactly one
	place per player where the number moves, and no second timer anywhere.

	Reaching zero has two consequences, both enforced server-side: punches drop
	to Config.ZeroStaminaPunchDamageMultiplier of their damage (applied by
	CombatService, which reads punchDamageMultiplier below), and a guard can
	neither be started nor held (enforced by ParryService, which reads canBlock
	and subscribes to onDepleted). A modified client cannot avoid either, because
	neither asks the client anything.

	Follows the HealthService pattern: state in a module-local table keyed by
	Player, Init() registers the remote handler before any client can reach it,
	per-character references released on CharacterRemoving, and everything
	released on PlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local StaminaState = require(Shared.Stamina.StaminaState)

local HealthService = require(script.Parent.HealthService)

local log = Logger.forScope("StaminaService")

type Record = {
	state: StaminaState.StaminaState,

	-- What the client says it is asking for. Never trusted as a stamina value —
	-- it says which state the player wants to be in, and the drain is computed
	-- here from this server's own clock.
	sprinting: boolean,

	-- Mirror of ParryService's authoritative phase, pushed in by setBlocking.
	-- Not a second parry state: nothing here decides it, reads it back to
	-- ParryService, or can disagree with it for longer than one function call.
	blocking: boolean,

	-- The live character, or nil between a death and the next spawn. Held rather
	-- than looked up per tick, exactly as HealthService holds its Humanoid.
	humanoid: Humanoid?,
	rootPart: BasePart?,

	-- Last value sent to this player, or nil if they have never been sent one.
	-- The whole replication policy is StaminaState.shouldReplicate reading this.
	lastSent: number?,
}

local records: { [Player]: Record } = {}
local depletedListeners: { (Player) -> () } = {}

local staminaChanged: RemoteEvent? = nil

-- Real time carried over from Heartbeat frames too small to be worth a step.
-- The pool is integrated against this rather than against the tick interval, so
-- retuning Config.StaminaTickIntervalSeconds changes how often the number moves
-- and never how fast it drains.
local sinceLastTick = 0

local StaminaService = {}

--[[
	Sends this player their own stamina, if it has moved far enough to be worth a
	message. `force` bypasses the threshold for the changes that are not gradual
	— a fresh character's full pool — where the client has nothing to smooth
	towards yet.
]]
local function replicate(player: Player, record: Record, force: boolean)
	local remote = staminaChanged
	if remote == nil then
		return
	end

	local current = record.state.current
	if
		not force
		and not StaminaState.shouldReplicate(
			record.lastSent,
			current,
			record.state.max,
			Config.StaminaReplicationStepFraction
		)
	then
		return
	end

	record.lastSent = current
	remote:FireClient(player, current, record.state.max)
end

--[[
	Whether this player currently has a living character. HealthService returns
	nil when there is no character at all, which is not the same as being alive,
	so this cannot be simplified to `not isDead(player)` — the same reasoning
	CombatService gives for its own copy of this test.
]]
local function isAlive(player: Player): boolean
	return HealthService.isDead(player) == false
end

--[[
	Whether this player should be paying the sprint drain right now.

	Two signals, either of which is enough. The first is the intent the client
	declared over SprintStateRequest. The second is the server observing a
	WalkSpeed above walking pace on a character that never declared anything,
	which is what a modified client sprinting without reporting it looks like
	from here.

	Both signals are ultimately client-owned — a player's character is
	client-network-owned, so neither the key nor the speed is something this
	server can prove — so this raises the cost of sprinting for free rather than
	preventing it. See docs/decisions.md for what would actually close that, and
	why it is not being done here.

	Then, whichever signal it was, the character has to actually be travelling.
	Ground speed only: falling past the threshold is not sprinting, and neither
	is holding the key while stood still or pressed against a wall.
]]
local function isSprinting(record: Record): boolean
	local humanoid = record.humanoid
	local rootPart = record.rootPart
	if humanoid == nil or rootPart == nil then
		return false
	end

	if not record.sprinting and humanoid.WalkSpeed <= Config.NormalWalkSpeed then
		return false
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local groundSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	return groundSpeed >= Config.StaminaSprintMinMoveSpeed
end

local function notifyDepleted(player: Player)
	for _, listener in depletedListeners do
		listener(player)
	end
end

--[[
	Moves one player's pool on by `elapsed` seconds and replicates the result if
	it is worth a message.

	A player with no living character is skipped entirely: no drain, no regen, no
	message. A corpse waiting to respawn holds whatever it died with, and the
	fresh character gets a full pool from onCharacterAdded rather than
	regenerating into one.

	Blocking outranks sprinting rather than stacking with it, matching
	SprintState.walkSpeed, where parry outranks sprint: a player holding both
	keys is walking at ParryWalkSpeed, so charging them a sprint drain as well
	would be billing them for a sprint they are not doing.
]]
local function step(player: Player, record: Record, elapsed: number)
	if not isAlive(player) then
		return
	end

	local wasEmpty = StaminaState.isEmpty(record.state)

	if record.blocking then
		record.state =
			StaminaState.consume(record.state, Config.ParryStaminaDrainPerSecond * elapsed)
	elseif isSprinting(record) then
		record.state =
			StaminaState.consume(record.state, Config.SprintStaminaDrainPerSecond * elapsed)
	else
		record.state = StaminaState.regenerate(record.state, Config.StaminaRegenPerSecond * elapsed)
	end

	-- Fired once on the transition, never for every tick spent at zero, so a
	-- listener that ends a guard cannot end it repeatedly.
	if not wasEmpty and StaminaState.isEmpty(record.state) then
		notifyDepleted(player)
	end

	replicate(player, record, false)
end

--[[
	The one update mechanism. A single connection for the whole server, made once
	in Start() and never rebuilt, iterating a table that is empty when nobody is
	playing.

	Heartbeat rather than an event because there is no event: a pool that drains
	over time has to be integrated, and there is nothing to hang that off. It is
	not stepped every frame, though — frames are accumulated until they are worth
	a tick, which also bounds how often replicate() can possibly fire.
]]
local function onHeartbeat(deltaTime: number)
	sinceLastTick += deltaTime
	if sinceLastTick < Config.StaminaTickIntervalSeconds then
		return
	end

	local elapsed = sinceLastTick
	sinceLastTick = 0

	for player, record in records do
		step(player, record, elapsed)
	end
end

--[[
	Current stamina, or nil if the player has already left. Unlike health this
	survives a death, because the pool belongs to the player's session and is
	reset by the next character rather than torn down with the old one.
]]
function StaminaService.getStamina(player: Player): number?
	local record = records[player]
	return if record then record.state.current else nil
end

--[[
	Max stamina for this player, or nil if they have already left.
]]
function StaminaService.getMaxStamina(player: Player): number?
	local record = records[player]
	return if record then record.state.max else nil
end

--[[
	Whether the player may be in a block/parry right now.

	ParryService calls this to refuse a guard that is being started on an empty
	pool. A player with no record at all — one who has left, or who has somehow
	reached this before PlayerAdded — is allowed: refusing on missing state would
	silently disable parrying, which is a far worse failure than allowing a guard
	nothing is charging for.
]]
function StaminaService.canBlock(player: Player): boolean
	local record = records[player]
	return if record then StaminaState.canBlock(record.state) else true
end

--[[
	What a punch thrown by this player right now is worth, as a multiplier on
	Config.PunchDamage.

	CombatService reads this *before* it charges the punch, so a swing is judged
	by the stamina the attacker had when they threw it: the punch that empties
	the pool still lands at full strength, and the next one is the weak one.
	Reading it afterwards would make a punch thrown on a full-looking bar deal
	reduced damage, which reads as a bug rather than as a cost.

	A player with no record punches at full strength, for the same reason
	canBlock allows a missing record.
]]
function StaminaService.punchDamageMultiplier(player: Player): number
	local record = records[player]
	if record == nil then
		return 1
	end

	return StaminaState.damageMultiplier(record.state, Config.ZeroStaminaPunchDamageMultiplier)
end

--[[
	Spends stamina, clamped at zero. Returns the remaining stamina, or nil if the
	player has no record.

	This is the whole write API other services get, and it only ever subtracts.
	There is deliberately no `grant`/`restore` counterpart: regeneration is the
	one way the pool goes up, and it happens in the loop above.
]]
function StaminaService.consume(player: Player, amount: number): number?
	local record = records[player]
	if record == nil then
		return nil
	end

	local wasEmpty = StaminaState.isEmpty(record.state)
	record.state = StaminaState.consume(record.state, amount)

	if not wasEmpty and StaminaState.isEmpty(record.state) then
		notifyDepleted(player)
	end

	-- Not deferred to the next tick: a punch is a step change rather than a
	-- gradual one, and the bar should show it landing on the frame it happened.
	replicate(player, record, false)
	return record.state.current
end

--[[
	Told by ParryService whenever its authoritative phase changes, so the loop
	knows whether to charge the guard drain.

	Deliberately a push rather than this service reading ParryService: pushing
	keeps the require one-way (ParryService -> StaminaService), and it keeps the
	phase itself in exactly one place. Nothing here can turn a guard on.
]]
function StaminaService.setBlocking(player: Player, blocking: boolean)
	local record = records[player]
	if record == nil then
		return
	end

	record.blocking = blocking
end

--[[
	Registers a listener for the moment a player's pool reaches zero.

	ParryService subscribes to end a guard that is already up. The listener runs
	on the transition only, never repeatedly while the pool sits at zero.
]]
function StaminaService.onDepleted(listener: (Player) -> ())
	table.insert(depletedListeners, listener)
end

--[[
	A fresh character starts on a full pool.

	The record itself belongs to the player rather than the character — the
	sprint intent is a held key, which outlives a respawn exactly as
	RunningController's own copy of it does — so this resets the pool and rebinds
	the character references without touching that intent.
]]
local function onCharacterAdded(player: Player, character: Model)
	local record = records[player]
	if record == nil then
		return
	end

	-- Refilled before waiting on anything, so a character whose parts are slow to
	-- arrive still spawns with a full pool rather than with whatever the
	-- previous one died on.
	record.state = StaminaState.new(Config.MaxStamina)
	record.blocking = false

	-- Forced: a respawn is a jump rather than a drain, and the client has no
	-- earlier value for this character to smooth away from.
	replicate(player, record, true)

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	-- Both WaitForChild calls yield, so the player may have left or respawned
	-- again while this was waiting. Binding to a character that is no longer the
	-- live one would drain the pool from a corpse's velocity.
	if records[player] ~= record or player.Character ~= character then
		return
	end

	record.humanoid = humanoid
	record.rootPart = rootPart
end

--[[
	Drops the references to a character that is going away. The pool and the
	sprint intent stay: the next character resets the first, and the second is
	still whatever the player is holding.
]]
local function releaseCharacter(player: Player)
	local record = records[player]
	if record == nil then
		return
	end

	record.humanoid = nil
	record.rootPart = nil
	-- A guard cannot survive its own character. ParryService drops its phase on
	-- the same event; clearing it here as well means the drain cannot be left on
	-- by an ordering between the two handlers.
	record.blocking = false
end

local function onSprintStateRequest(player: Player, sprinting: any)
	-- Anything a client sends is untrusted, including its type. For this remote
	-- the type check is the whole check: there are exactly two legal values and
	-- a boolean has no range to be out of.
	--
	-- Dropped silently, with no warn. The payload is entirely client-controlled,
	-- so a line per rejected message is a way to flood the output on demand —
	-- the same reasoning ParryService gives for its own transitions.
	if type(sprinting) ~= "boolean" then
		return
	end

	local record = records[player]
	if record == nil then
		return
	end

	record.sprinting = sprinting
end

--[[
	Opens a player's record. Player.CharacterAdded and Player.CharacterRemoving
	are events on the Player instance itself, which Roblox disconnects when the
	player leaves, so — unlike the Heartbeat connection above — they never need
	an explicit disconnect.
]]
local function attachPlayer(player: Player)
	records[player] = {
		state = StaminaState.new(Config.MaxStamina),
		sprinting = false,
		blocking = false,
		humanoid = nil,
		rootPart = nil,
		lastSent = nil,
	}

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		releaseCharacter(player)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

function StaminaService.Init()
	-- Registered in Init so the handler exists before the first client can
	-- possibly reach the remote.
	local sprintRequest = Net.getEvent("SprintStateRequest")
	staminaChanged = Net.getEvent("StaminaChanged")

	-- Any arguments beyond the first are ignored by not being accepted in the
	-- first place.
	sprintRequest.OnServerEvent:Connect(function(player: Player, sprinting: any)
		onSprintStateRequest(player, sprinting)
	end)
end

function StaminaService.Start()
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Without this, every player who has ever joined stays in the table for
		-- the lifetime of the server, and the loop keeps stepping them.
		records[player] = nil
	end)

	-- Connected before the catch-up below, which yields on WaitForChild for any
	-- character that is already here: a slow-arriving root part must not be able
	-- to hold up the loop every other player's pool depends on.
	RunService.Heartbeat:Connect(onHeartbeat)

	-- A player — and possibly their character — can already exist before this
	-- service starts.
	for _, player in Players:GetPlayers() do
		if records[player] == nil then
			attachPlayer(player)
		end
	end

	log.info(`stamina pools of {Config.MaxStamina} are open`)
end

return StaminaService
