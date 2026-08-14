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

	The swing sound starts on the same line as the animation and is fitted to
	that animation's own length, so the two are one action rather than two that
	happen to overlap. It is the whoosh only: the impact is a separate sound,
	played by CombatService when the punch actually lands, and the two are
	deliberately unrelated instances so neither can interrupt the other. A punch
	that misses plays this and nothing else.

	Unlike the animation, the swing sound is heard by the attacker alone. Sounds
	created on a client do not replicate, and the server does not learn a punch
	happened until the "Hit" marker — half way through the swing, which is the
	wrong moment to start a whoosh. Making it audible to everyone would mean a
	remote whose only purpose is a sound effect. The impact, which is the half
	that matters to the player being hit, is server-side and heard by both.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Audio = require(Shared.Util.Audio)
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local PunchRules = require(Shared.Combat.PunchRules)

local ParryController = require(script.Parent.ParryController)

local log = Logger.forScope("PunchController")

local SWING_FADE_TWEEN =
	TweenInfo.new(Config.PunchSwingFadeSeconds, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

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

-- One Sound for the session, built at Start and never replaced, for the same
-- reason the Animation instance above is reused once: the asset is then loaded
-- well before the first click, and `TimeLength` can be read to fit the sound to
-- the swing. Rebuilding it per punch, or per character, would mean the first
-- swing after every respawn played before its length was known, and so
-- unfitted.
--
-- Parented to SoundService rather than to the character, which also means it
-- cannot be destroyed underneath this controller when a character is removed.
local swingSound: Sound? = nil
local swingFade: Tween? = nil

-- Bumped every time the swing is started or stopped. The fade and the stop that
-- follows it are scheduled ahead in time, and a punch thrown before they arrive
-- must not have its own sound faded out by the previous punch's timers.
local swingGeneration = 0

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
	Silences the swing, cancels anything scheduled against it, and puts it back
	at its configured volume ready for the next one.

	Safe to call when nothing is playing, so every path that ends a swing — a
	new punch, the fade running out, a character going away — can call it
	without checking first. Bumping the generation is what makes it also mean
	"forget any timer that was going to touch this sound".
]]
local function stopSwing()
	swingGeneration += 1

	if swingFade then
		swingFade:Cancel()
		swingFade = nil
	end

	local sound = swingSound
	if sound then
		sound:Stop()
		-- The fade leaves the volume at zero. Without this the next punch would
		-- be silent, and the one after that, for the rest of the session.
		sound.Volume = Config.PunchSwingSound.volume
	end
end

--[[
	Starts the swing sound alongside the animation, fitted to it.

	`animationSeconds` is the track's own length, read from the loaded asset
	rather than written down here, so a re-exported animation of a different
	length re-fits the sound instead of drifting out of step with it. Zero means
	the length is not known yet (the asset has not loaded, or there is no
	animation at all), and the sound simply plays untouched — see
	Audio.fitPlaybackSpeed.

	Speed handles as much of the difference as it can without pitching the sound
	somewhere it does not belong; a fade takes off whatever is left, so the
	whoosh is finished by the time the fist is back down.
]]
local function playSwing(animationSeconds: number)
	local sound = swingSound
	if sound == nil then
		return
	end

	-- Restarts rather than layers: one swing is playing at any moment, exactly
	-- as one animation is. The impact sound is a separate instance owned by the
	-- server, so nothing here can cut it off.
	stopSwing()
	local thisGeneration = swingGeneration

	sound.PlaybackSpeed = Audio.fitPlaybackSpeed(
		sound.TimeLength,
		animationSeconds,
		Config.PunchSwingMinPlaybackSpeed,
		Config.PunchSwingMaxPlaybackSpeed
	)
	sound.TimePosition = 0
	sound:Play()

	local fadeStart = Audio.fadeStartSeconds(
		sound.TimeLength,
		animationSeconds,
		sound.PlaybackSpeed,
		Config.PunchSwingFadeSeconds
	)
	if fadeStart == nil then
		-- Shorter than the swing already. It ends on its own.
		return
	end

	task.delay(fadeStart, function()
		if swingGeneration ~= thisGeneration then
			return
		end

		local fade = TweenService:Create(sound, SWING_FADE_TWEEN, { Volume = 0 })
		swingFade = fade
		fade:Play()

		task.delay(Config.PunchSwingFadeSeconds, function()
			if swingGeneration ~= thisGeneration then
				return
			end
			stopSwing()
		end)
	end)
end

--[[
	Drops the current character's track and its marker connection, and silences
	any swing still playing on it.

	Called before loading a new one and again when the character goes away, so
	there is only ever one live marker connection and a dead character's swing
	can never land a hit — or keep whooshing — for the character that replaced
	it.
]]
local function releaseTrack()
	if markerConn then
		markerConn:Disconnect()
		markerConn = nil
	end
	punchTrack = nil
	stopSwing()
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
		-- existed. The swing still gets its sound, with no length to fit it to.
		playSwing(0)
		requestHit()
		return
	end

	-- Play() on a track that is already playing does nothing, which would
	-- swallow the marker for a punch thrown while the previous swing is still
	-- running. Stopping first makes every allowed click restart the swing and
	-- reach "Hit" exactly once.
	track:Stop(0)
	track:Play()

	-- Immediately after Play, and fitted to this track's own length, so the
	-- whoosh and the animation are one action rather than two started near each
	-- other. Track.Length is the published animation's real duration, so a
	-- re-export of a different length re-fits the sound on its own.
	playSwing(track.Length)
end

function PunchController.Start()
	-- Built before anything can click, so the asset is loading from the moment
	-- the controller starts rather than from the first punch. Audio.create
	-- answers nil for an empty id, which leaves playSwing a no-op and the punch
	-- otherwise unchanged — the same "not uploaded yet" state the animation has.
	swingSound = Audio.create(Config.PunchSwingSound, SoundService)

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
