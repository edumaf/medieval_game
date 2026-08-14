--!strict
--[[
	RunningController — sprint while Left Shift is held, and the one writer of
	Humanoid.WalkSpeed.

	ParryController reports its phase here through setParryActive rather than
	setting WalkSpeed itself, so the two systems cannot fight over the property.
	See SprintState for why both intents live in one state.

	The speed itself is still applied locally: Humanoid.WalkSpeed is a replicated
	property and a player's own character is client-network-owned by default, so
	setting it here already reaches the server and other clients.

	What has changed is that something now cares. Stamina is charged for
	sprinting, and it is charged on the server, so this controller reports its
	sprint intent over SprintStateRequest -- one boolean, on the frame it
	changes, never on a schedule and never per frame. It reports; it does not
	decide. Nothing is sent about how much stamina to spend, because the server
	drains the pool from its own clock and would ignore a number from here
	anyway. See docs/decisions.md for what this does and does not close.

	Running the pool empty takes the sprint away until it has recovered. The
	rule is StaminaState.sprintLocked and the pool is the server's, arriving
	here through StaminaController -- this controller evaluates a shared
	predicate against a server-owned number and applies the result to the
	property it already owns. It does not decide when a player is exhausted any
	more than it decides how much stamina a sprint costs.

	The boolean reported over the remote is therefore whether the player is
	*sprinting*, not whether Shift is down. That distinction is what lets the
	pool refill under a held key: the server regenerates a player it cannot see
	sprinting, so a client that kept reporting a held key at zero would pin its
	own pool there and never recover.

	Input connections, the CharacterAdded connection and the stamina
	subscription are made once, in Start(). Respawning only swaps the Humanoid
	reference and re-states the intent; it never reconnects anything, so there
	is nothing to leak or duplicate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local StaminaState = require(Shared.Stamina.StaminaState)

local StaminaController = require(script.Parent.StaminaController)

local SprintState = require(script.SprintState)

local log = Logger.forScope("RunningController")

local RunningController = {}

local player = Players.LocalPlayer
local humanoid: Humanoid? = nil
local state = SprintState.initial()

local sprintRequest: RemoteEvent? = nil

-- What the server was last told. Sending only on a change is what keeps a held
-- key down to two messages -- one on press, one on release -- rather than a
-- stream of them for as long as the player is running.
local lastSentSprinting: boolean? = nil

--[[
	Tells the server whether the player is sprinting, if that has changed since
	the last time it was told.

	`force` re-states it regardless, which a respawn does: the intent survives a
	death here (holding Shift through one keeps sprinting), so the new character
	starts draining stamina for a key that was pressed before it existed, and a
	single message on spawn is cheaper than the two realms quietly disagreeing
	about it.

	The lockout is part of what is reported, so exhaustion costs one message and
	recovery costs one more -- the same two-messages-per-state-change budget a
	held key already had, rather than a stream while the pool refills.
]]
local function sendSprintIntent(force: boolean)
	local remote = sprintRequest
	if remote == nil then
		return
	end

	local sprinting = SprintState.isSprinting(state)

	if not force and lastSentSprinting == sprinting then
		return
	end

	lastSentSprinting = sprinting
	remote:FireServer(sprinting)
end

--[[
	Applies the current sprint-intent state to whichever Humanoid is active
	right now. A no-op while there is no character -- the request is still
	remembered in `state` and gets applied the moment a Humanoid appears.
]]
local function applyWalkSpeed()
	if humanoid == nil then
		return
	end
	humanoid.WalkSpeed = SprintState.walkSpeed(
		state,
		Config.NormalWalkSpeed,
		Config.SprintWalkSpeed,
		Config.ParryWalkSpeed
	)
end

--[[
	Re-evaluates the stamina lockout against the pool the server last sent, and
	applies it if it has moved.

	Called on every StaminaChanged, which is at most a handful a second and
	never per frame. The early return keeps that down to real work only on the
	two transitions that matter -- becoming exhausted, and recovering -- so the
	steady drain in between costs a comparison.

	The latch lives in `state` rather than here: StaminaState.sprintLocked is
	pure and takes the previous answer, exactly as StaminaState.shouldReplicate
	takes the last value sent.
]]
local function refreshStaminaLock()
	local locked = StaminaState.sprintLocked(
		StaminaController.getState(),
		state.staminaLocked,
		Config.SprintRecoveryStaminaFraction
	)

	if locked == state.staminaLocked then
		return
	end

	state = SprintState.withStaminaLocked(state, locked)
	applyWalkSpeed()
	sendSprintIntent(false)
end

--[[
	Parry intent, handed over by ParryController on every phase change.

	This controller stays the only writer of WalkSpeed. The speed is recomputed
	from both intents on every change rather than saved and restored, so a parry
	that ends while Shift is still held drops straight back to the sprint speed,
	and there is no modifier left behind to go stale.

	Safe to call before Start() has found a Humanoid: the request is remembered
	in `state` and applied the moment one appears.
]]
function RunningController.setParryActive(active: boolean)
	state = if active then SprintState.withParryBegan(state) else SprintState.withParryEnded(state)
	applyWalkSpeed()
end

--[[
	A respawn replaces the character wholesale, so the only thing to do here
	is point at the new Humanoid and re-apply whatever the player is
	currently requesting -- if Shift is still held through a respawn, the new
	character starts sprinting immediately, matching what holding the key
	would produce on the original character.
]]
local function onCharacterAdded(character: Model)
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	applyWalkSpeed()
	sendSprintIntent(true)
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or input.KeyCode ~= Enum.KeyCode.LeftShift then
		return
	end
	state = SprintState.withInputBegan(state)
	applyWalkSpeed()
	sendSprintIntent(false)
end

-- Deliberately does not check gameProcessedEvent: if it did, releasing Shift
-- while a text box happens to have focus would leave sprintRequested stuck
-- true with no way to clear it.
local function onInputEnded(input: InputObject, _gameProcessedEvent: boolean)
	if input.KeyCode ~= Enum.KeyCode.LeftShift then
		return
	end
	state = SprintState.withInputEnded(state)
	applyWalkSpeed()
	sendSprintIntent(false)
end

function RunningController.Start()
	-- Yields until the remote replicates, which is why this is Start and not
	-- Init. Until it returns, sendSprintIntent is a no-op and the speed still
	-- applies locally -- the player sprints, and the server starts charging for
	-- it a moment later.
	sprintRequest = Net.getEvent("SprintStateRequest")

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	-- An empty pool takes the sprint away, and recovering to
	-- Config.SprintRecoveryStaminaFraction gives it back. Both arrive here as an
	-- ordinary stamina update: the server sends both ends of the pool exactly
	-- (StaminaState.shouldReplicate), so the transition to zero is never a value
	-- this client had to approximate.
	StaminaController.onChanged(refreshStaminaLock)

	-- StaminaController assumes a full pool until the server says otherwise, so
	-- this normally changes nothing. It matters when a StaminaChanged has
	-- already landed before this controller subscribed -- both Start()s run in
	-- their own thread -- in which case the lockout would otherwise wait for the
	-- next update to notice.
	refreshStaminaLock()

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	log.info("watching for Left Shift")
end

return RunningController
