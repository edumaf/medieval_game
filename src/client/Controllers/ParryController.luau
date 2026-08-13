--!strict
--[[
	ParryController — hold Q to guard.

	This controller has no authority over anything. It plays an animation, asks
	RunningController to slow the player down, and tells the server which phase
	it has reached; whether a punch is actually stopped is decided entirely by
	ParryService and CombatService. Nothing here is worth lying to, because
	nothing here decides anything.

	Timing comes from the animation, not from this file. Pressing Q starts the
	guard and begins the wind-up; the protected phase begins when the track
	reaches its "Hold" marker, which the animator placed on the frame the guard
	is fully raised. A task.wait() here would have to be re-tuned by hand on
	every re-export and would drift the moment it was not — the same reason
	PunchController fires on its "Hit" marker rather than on a timer.

	The pose is held by freezing the track (AdjustSpeed(0)) at that marker
	rather than by looping it or re-playing it, so the animation is started
	exactly once per parry and the marker fires exactly once.

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
local ParryState = require(Shared.Combat.ParryState)

local RunningController = require(script.Parent.RunningController)

local log = Logger.forScope("ParryController")

-- Long enough that dropping the guard reads as lowering it rather than
-- snapping out of it, short enough that the pose is gone well before the
-- player could be hit again.
local STOP_FADE_SECONDS = 0.15

local ParryController = {}

local player = Players.LocalPlayer

local parryRequest: RemoteEvent? = nil
local state = ParryState.initial()

-- One Animation instance for the session. LoadAnimation copies what it needs,
-- so the same instance can back a track on every character the player gets.
local animation: Animation? = nil

-- The track belongs to the current character's Animator, so all three of these
-- are replaced on every respawn. The connections are kept so they can be
-- dropped: a marker on a character that is going away must never raise a guard
-- for the character that replaced it.
local parryTrack: AnimationTrack? = nil
local markerConn: RBXScriptConnection? = nil
local diedConn: RBXScriptConnection? = nil

local function sendTransition(transition: ParryState.Transition)
	if parryRequest then
		parryRequest:FireServer(transition)
	end
end

--[[
	Drops the current character's track, its marker connection and its death
	connection.

	Called before binding a new character and again when the character goes
	away, so there is only ever one live marker connection.
]]
local function releaseCharacter()
	if markerConn then
		markerConn:Disconnect()
		markerConn = nil
	end
	if diedConn then
		diedConn:Disconnect()
		diedConn = nil
	end

	local track = parryTrack
	if track then
		-- Unfreeze before letting go: a track left at speed 0 would still be
		-- paused if this same Animator were ever reused.
		track:AdjustSpeed(1)
		track:Stop(0)
	end
	parryTrack = nil
end

--[[
	Ends the parry, whatever phase it was in and whatever ended it — Q released,
	death, or a character being replaced.

	A no-op when there is no parry to end, so it is safe to call from every one
	of those paths without any of them having to check first. This is the only
	place the guard is given up, which is what makes "the player can never get
	permanently stuck parrying" a property of one function rather than of four
	call sites.
]]
local function endParry()
	if not ParryState.isEngaged(state) then
		return
	end

	state = ParryState.apply(state, "end")

	local track = parryTrack
	if track then
		-- Speed first: stopping a track that is still frozen at Hold would fade
		-- out a paused pose, and leave it paused for the next parry.
		track:AdjustSpeed(1)
		track:Stop(STOP_FADE_SECONDS)
	end

	RunningController.setParryActive(false)
	sendTransition("end")
end

--[[
	The animation reached the frame the guard is up. This is the moment the
	player becomes protected, and the only such moment.
]]
local function onHoldReached()
	-- The marker fires for whatever is playing on this track. Only a live
	-- attempt may be promoted, so a marker arriving with no parry behind it
	-- cannot raise a guard.
	if not ParryState.isAttempting(state) then
		return
	end

	state = ParryState.apply(state, "hold")

	local track = parryTrack
	if track then
		-- Freezing the track keeps the guard pose applied for as long as Q is
		-- held, with no loop, no re-play and no per-frame work. Roblox keeps
		-- applying a playing track's current pose at speed 0.
		track:AdjustSpeed(0)
	end

	sendTransition("hold")
end

--[[
	Binds the current character: the death connection, and the parry animation
	with its "Hold" marker.

	A respawn replaces the character, and an AnimationTrack belongs to the
	Animator it was loaded on, so the old track is dropped and a new one is
	loaded rather than reused. Within one character the track is loaded once and
	replayed for every parry.

	Tolerates an empty Config.ParryAnimationId: the parry still works, it just
	plays nothing and reaches the guard on the key press instead. That keeps the
	system usable if the animation is ever unpublished.
]]
local function bindCharacter(character: Model)
	releaseCharacter()

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	-- WaitForChild yields, so the player may have respawned again while this
	-- was waiting. Binding to a character that is no longer the live one would
	-- leave the guard playing on a corpse.
	if player.Character ~= character then
		return
	end

	-- Death ends the parry even though the character is still around: the
	-- server drops its record when the character is replaced, so holding the
	-- pose past death would show a protection the player no longer has.
	diedConn = humanoid.Died:Connect(endParry)

	if Config.ParryAnimationId == "" then
		return
	end

	local animator = humanoid:WaitForChild("Animator") :: Animator
	if player.Character ~= character then
		return
	end

	if animation == nil then
		local instance = Instance.new("Animation")
		instance.AnimationId = Config.ParryAnimationId
		animation = instance
	end

	local track = animator:LoadAnimation(animation :: Animation)
	-- Action so the guard reads over the walk/idle animations Roblox plays on
	-- the same rig, matching the punch. The player keeps walking while guarding,
	-- so this has to win against the walk cycle.
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false

	markerConn = track:GetMarkerReachedSignal(Config.ParryHoldMarkerName):Connect(onHoldReached)
	parryTrack = track
end

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	-- gameProcessedEvent covers typing a "q" in chat.
	if gameProcessedEvent or input.KeyCode ~= Enum.KeyCode.Q then
		return
	end

	-- Holding a key repeats InputBegan on some platforms, and a player can mash
	-- it. ParryState would ignore the repeats anyway; refusing here also stops
	-- the animation being restarted underneath a guard that is already raised.
	if ParryState.isEngaged(state) then
		return
	end

	state = ParryState.apply(state, "begin")
	-- The slowdown starts with the attempt, not with the guard, so a parry that
	-- is cancelled before Hold has still cost the player something.
	RunningController.setParryActive(true)
	sendTransition("begin")

	local track = parryTrack
	if track == nil then
		-- No animation, so no marker will ever arrive. Reach the guard on the
		-- press, which is what PunchController does for its own missing
		-- animation. Without this the player would be slowed and unable to
		-- punch, but never protected.
		onHoldReached()
		return
	end

	-- Stop(0) first so a track still fading out from the previous parry cannot
	-- swallow this Play() -- Play() on an already-playing track does nothing,
	-- and that would cost the player the marker and so the whole guard.
	track:AdjustSpeed(1)
	track:Stop(0)
	track:Play()
end

-- Deliberately does not check gameProcessedEvent, for the same reason
-- RunningController does not: releasing Q while a text box happens to have
-- focus would otherwise leave the player guarding with no way to stop.
local function onInputEnded(input: InputObject, _gameProcessedEvent: boolean)
	if input.KeyCode ~= Enum.KeyCode.Q then
		return
	end

	endParry()
end

--[[
	Whether a parry is winding up or being held right now. PunchController reads
	this to avoid starting a swing the server is going to refuse.
]]
function ParryController.isEngaged(): boolean
	return ParryState.isEngaged(state)
end

function ParryController.Start()
	-- Yields until the remote replicates, which is why this is Start and not
	-- Init.
	parryRequest = Net.getEvent("ParryStateRequest")

	player.CharacterAdded:Connect(function(character: Model)
		-- A parry is deliberately NOT resumed through a respawn, even if Q is
		-- still held. Sprint does resume (see RunningController), because a
		-- speed can just be re-applied; a guard cannot, because the new
		-- character would have to be dropped straight into the Hold pose having
		-- never played the wind-up. The player presses Q again.
		endParry()
		bindCharacter(character)
	end)
	player.CharacterRemoving:Connect(function()
		endParry()
		releaseCharacter()
	end)
	if player.Character then
		bindCharacter(player.Character)
	end

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	log.info("watching for Q")
end

return ParryController
