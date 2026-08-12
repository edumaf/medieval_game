--!strict
--[[
	RunningController — sprint while Left Shift is held.

	Client-only, no remote involved: Humanoid.WalkSpeed is a replicated
	property and a player's own character is client-network-owned by default,
	so setting it locally already reaches the server and other clients. There
	is currently nothing (stamina, combat, speed-gated rewards) a modified
	client could gain by lying about its speed -- see docs/decisions.md for
	when that stops being true and this needs server validation.

	Input connections and the CharacterAdded connection are made once, in
	Start(). Respawning only swaps the Humanoid reference; it never
	reconnects anything, so there is nothing to leak or duplicate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)

local SprintState = require(script.SprintState)

local log = Logger.forScope("RunningController")

local RunningController = {}

local player = Players.LocalPlayer
local humanoid: Humanoid? = nil
local state = SprintState.initial()

--[[
	Applies the current sprint-intent state to whichever Humanoid is active
	right now. A no-op while there is no character -- the request is still
	remembered in `state` and gets applied the moment a Humanoid appears.
]]
local function applyWalkSpeed()
	if humanoid == nil then
		return
	end
	humanoid.WalkSpeed =
		SprintState.walkSpeed(state, Config.NormalWalkSpeed, Config.SprintWalkSpeed)
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
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or input.KeyCode ~= Enum.KeyCode.LeftShift then
		return
	end
	state = SprintState.withInputBegan(state)
	applyWalkSpeed()
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
end

function RunningController.Start()
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	log.info("watching for Left Shift")
end

return RunningController
