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

	Input connections and the CharacterAdded connection are made once, in
	Start(). Respawning only swaps the Humanoid reference and re-states the
	intent; it never reconnects anything, so there is nothing to leak or
	duplicate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)

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
	Tells the server whether the player is asking to sprint, if that has changed
	since the last time it was told.

	`force` re-states it regardless, which a respawn does: the intent survives a
	death here (holding Shift through one keeps sprinting), so the new character
	starts draining stamina for a key that was pressed before it existed, and a
	single message on spawn is cheaper than the two realms quietly disagreeing
	about it.
]]
local function sendSprintIntent(force: boolean)
	local remote = sprintRequest
	if remote == nil then
		return
	end

	if not force and lastSentSprinting == state.sprintRequested then
		return
	end

	lastSentSprinting = state.sprintRequested
	remote:FireServer(state.sprintRequested)
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

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	log.info("watching for Left Shift")
end

return RunningController
