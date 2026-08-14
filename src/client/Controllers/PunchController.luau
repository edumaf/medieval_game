--!strict
--[[
	PunchController — left click throws a punch.

	This controller has no authority over anything. It fires PunchRequest and
	plays an animation; whether anyone was actually hit, and for how much, is
	decided entirely by CombatService. Nothing here is worth lying to, which
	is why the remote carries no arguments.

	Timing comes from the animation, not from this file. A left click starts
	Punch_Right; the request goes out when the track reaches its "Hit" marker,
	which the animator placed on the frame where the fist actually connects.
	That is the whole reason the marker exists — a timer here would have to be
	re-tuned by hand every time the animation is re-exported, and would drift
	the moment it was not.

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

local ParryController = require(script.Parent.ParryController)

local log = Logger.forScope("PunchController")

local PunchController = {}

local player = Players.LocalPlayer

local punchRequest: RemoteEvent? = nil
local lastPunchAt: number? = nil

-- One Animation instance for the session. LoadAnimation copies what it needs,
-- so the same instance can back a track on every character the player gets.
local animation: Animation? = nil

-- The track belongs to the current character's Animator, so both of these are
-- replaced on every respawn. The connection is kept so it can be dropped: a
-- track on a character that is going away must never reach the remote.
local punchTrack: AnimationTrack? = nil
local markerConn: RBXScriptConnection? = nil

--[[
	Tells the server the punch connected. The server decides who was in front
	of the player and applies the damage itself; see CombatService.
]]
local function requestHit()
	if punchRequest then
		punchRequest:FireServer()
	end
end

--[[
	Drops the current character's track and its marker connection.

	Called before loading a new one and again when the character goes away, so
	there is only ever one live marker connection and a dead character's swing
	can never land a hit for the character that replaced it.
]]
local function releaseTrack()
	if markerConn then
		markerConn:Disconnect()
		markerConn = nil
	end
	punchTrack = nil
end

--[[
	Loads the punch animation onto the current character's Animator and binds
	its "Hit" marker.

	A respawn replaces the character, and an AnimationTrack belongs to the
	Animator it was loaded on, so the old track is dropped and a new one is
	loaded rather than reused. Within one character the track is loaded once
	and replayed for every punch.

	Does nothing while Config.PunchAnimationId is empty: the punch still
	works, it just plays nothing and reports the hit on the click instead.
	That keeps the system usable if the animation is ever unpublished.
]]
local function loadAnimation(character: Model)
	releaseTrack()

	if Config.PunchAnimationId == "" then
		return
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator

	-- Those WaitForChild calls yield, so the player may have respawned again
	-- while this was waiting. Binding to a character that is no longer the
	-- live one would leave the punch playing on a corpse.
	if player.Character ~= character then
		return
	end

	if animation == nil then
		local instance = Instance.new("Animation")
		instance.AnimationId = Config.PunchAnimationId
		animation = instance
	end

	local track = animator:LoadAnimation(animation :: Animation)
	-- Action so the punch reads over the walk/idle animations Roblox plays on
	-- the same rig; a swing that only shows while standing still is not one.
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false

	markerConn = track:GetMarkerReachedSignal(Config.PunchHitMarkerName):Connect(requestHit)
	punchTrack = track
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	-- gameProcessedEvent covers clicking a button or typing in chat.
	if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end

	-- No punching out of a guard. CombatService refuses the request too, and
	-- that is the check that decides; this one only stops a swing playing for a
	-- punch that was never going to land. Checked before the cooldown so a
	-- refused click does not cost the player their next real punch.
	if ParryController.isEngaged() then
		return
	end

	-- Purely to avoid firing a remote the server is going to drop anyway.
	-- CombatService enforces the real cooldown against its own clock; this
	-- one being slightly out of step with it is harmless. It gates the swing
	-- rather than the request, so a punch that is not allowed does not play
	-- either.
	local now = os.clock()
	if not PunchRules.canPunch(lastPunchAt, now, Config.PunchCooldownSeconds) then
		return
	end
	lastPunchAt = now

	local track = punchTrack
	if track == nil then
		-- No animation, so no marker will ever arrive. Report the hit on the
		-- click, which is what this controller did before the animation
		-- existed.
		requestHit()
		return
	end

	-- Play() on a track that is already playing does nothing, which would
	-- swallow the marker for a punch thrown while the previous swing is still
	-- running. Stopping first makes every allowed click restart the swing and
	-- reach "Hit" exactly once.
	track:Stop(0)
	track:Play()
end

function PunchController.Start()
	-- Yields until the remote replicates, which is why this is Start and not
	-- Init.
	punchRequest = Net.getEvent("PunchRequest")

	player.CharacterAdded:Connect(loadAnimation)
	player.CharacterRemoving:Connect(releaseTrack)
	if player.Character then
		loadAnimation(player.Character)
	end

	UserInputService.InputBegan:Connect(onInputBegan)

	log.info("watching for left click")
end

return PunchController
