--!strict
--[[
	PunchController — left click throws a punch.

	This controller has no authority over anything. It fires PunchRequest and
	plays an animation; whether anyone was actually hit, and for how much, is
	decided entirely by CombatService. Nothing here is worth lying to, which
	is why the remote carries no arguments.

	The animation is played on the local character's own Animator. A player's
	character is client-network-owned, so that play call replicates to the
	server and to everyone else without any extra remote — the same reason
	RunningController can set WalkSpeed locally.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local PunchRules = require(Shared.Combat.PunchRules)

local log = Logger.forScope("PunchController")

local PunchController = {}

local player = Players.LocalPlayer

local punchRequest: RemoteEvent? = nil
local punchTrack: AnimationTrack? = nil
local lastPunchAt: number? = nil

--[[
	Loads the punch animation onto the current character's Animator.

	A respawn replaces the character, and an AnimationTrack belongs to the
	Animator it was loaded on, so the old track is dropped and a new one is
	loaded rather than reused.

	Does nothing while Config.PunchAnimationId is empty: the punch still
	works, it just plays no animation. That keeps the system usable before
	anyone has uploaded one.
]]
local function loadAnimation(character: Model)
	punchTrack = nil

	if Config.PunchAnimationId == "" then
		return
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator

	local animation = Instance.new("Animation")
	animation.AnimationId = Config.PunchAnimationId
	punchTrack = animator:LoadAnimation(animation)
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	-- gameProcessedEvent covers clicking a button or typing in chat.
	if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end

	-- Purely to avoid firing a remote the server is going to drop anyway.
	-- CombatService enforces the real cooldown against its own clock; this
	-- one being slightly out of step with it is harmless.
	local now = os.clock()
	if not PunchRules.canPunch(lastPunchAt, now, Config.PunchCooldownSeconds) then
		return
	end
	lastPunchAt = now

	if punchTrack then
		punchTrack:Play()
	end

	if punchRequest then
		punchRequest:FireServer()
	end
end

function PunchController.Start()
	-- Yields until the remote replicates, which is why this is Start and not
	-- Init.
	punchRequest = Net.getEvent("PunchRequest")

	player.CharacterAdded:Connect(loadAnimation)
	if player.Character then
		loadAnimation(player.Character)
	end

	UserInputService.InputBegan:Connect(onInputBegan)

	log.info("watching for left click")
end

return PunchController
