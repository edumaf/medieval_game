--!strict
--[[
	Audio — building and starting a Sound, and the arithmetic for fitting one to
	a duration it did not come in.

	Deliberately small. Three systems need a sound now — the punch swing and the
	punch impact in combat, the damage/heal feedback in ScreenEffectsController —
	and each of them would otherwise repeat the same six property assignments
	and the same cleanup. That is what this removes, and nothing more: there is
	no sound manager, no channel, no registry, and no state. Every caller keeps
	its own Sound and decides when it starts and stops, because every one of
	them already owns the event that decides.

	It lives in `Shared/Util` rather than under `src/client` because the server
	needs it too. A punch impact has to be heard by both players, and a Sound
	created on the server inside a replicated part is heard by everyone with no
	remote involved — see CombatService and docs/decisions.md.

	The two arithmetic functions take plain numbers and touch no instance, so
	the fitting rules are unit-testable without a loaded asset.
]]

local Debris = game:GetService("Debris")

local Types = require(script.Parent.Parent.Types)

--[[
	Re-exported so a caller that only needs to name the type does not have to
	require Types as well. The definition lives in Shared/Types, next to
	everything else both realms have to agree on.
]]
export type SoundSpec = Types.SoundSpec

-- Backstop for a one-shot whose Ended never arrives — an asset that fails to
-- load, or a part destroyed underneath it. Far longer than any sound this game
-- plays, so it only ever catches the failure.
local MAX_ONE_SHOT_LIFETIME_SECONDS = 20

local Audio = {}

--[[
	Builds a Sound from `spec` under `parent`, without playing it. Returns nil
	when the spec has no id, so a caller can treat "not uploaded yet" as "no
	sound" rather than as an error.

	Use this for a sound that is played more than once and needs to keep its
	handle — the punch swing, and the two health-feedback sounds. Building it
	once means the asset is already loaded when it is first wanted, and means
	`TimeLength` can be read to fit it to something.
]]
function Audio.create(spec: SoundSpec, parent: Instance): Sound?
	if spec.id == "" then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.SoundId = spec.id
	sound.Volume = spec.volume
	sound.PlaybackSpeed = spec.playbackSpeed
	-- Applied unconditionally. Roblox ignores both for a Sound that is not
	-- parented to a BasePart, so setting them costs nothing for the flat
	-- sounds and means a spec moved onto a character behaves immediately.
	sound.RollOffMinDistance = spec.rollOffMinDistance
	sound.RollOffMaxDistance = spec.rollOffMaxDistance

	sound.Parent = parent
	return sound
end

--[[
	Builds a Sound, plays it once, and cleans it up when it finishes.

	For a fire-and-forget sound nobody needs a handle to — the punch impact,
	which belongs to the moment rather than to any system. The caller keeps no
	reference and has nothing to disconnect: the sound removes itself when it
	ends, with a Debris backstop for the case where it never does.
]]
function Audio.playOnce(spec: SoundSpec, parent: Instance): Sound?
	local sound = Audio.create(spec, parent)
	if sound == nil then
		return nil
	end

	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, MAX_ONE_SHOT_LIFETIME_SECONDS)

	sound:Play()
	return sound
end

--[[
	The playback speed that brings a `soundSeconds` sound closest to lasting
	`targetSeconds`, without letting it be pitched far enough to sound wrong.

	The honest ratio is `soundSeconds / targetSeconds` — a sound twice as long
	as the animation needs to run at 2x to end with it. That is also a full
	octave up, which turns a punch into a cartoon. So the ratio is clamped, and
	whatever the clamp refuses is left for the caller to fade out instead. Speed
	does the part of the job that is inaudible; the fade does the rest.

	Returns 1 for a sound that has not loaded yet (`TimeLength` is 0 until it
	has) and for a nonsensical target, so an unfitted sound plays at its natural
	speed rather than at zero or at infinity.
]]
function Audio.fitPlaybackSpeed(
	soundSeconds: number,
	targetSeconds: number,
	minSpeed: number,
	maxSpeed: number
): number
	if soundSeconds <= 0 or targetSeconds <= 0 then
		return 1
	end

	local ratio = soundSeconds / targetSeconds
	-- Only reachable from a NaN in either argument, which math.clamp would
	-- pass straight through into PlaybackSpeed.
	if ratio ~= ratio then
		return 1
	end

	return math.clamp(ratio, minSpeed, maxSpeed)
end

--[[
	When to start fading a sound out so it is silent by `targetSeconds`, or nil
	if it finishes on its own first and needs no fade at all.

	`playbackSpeed` is what Audio.fitPlaybackSpeed returned, because that is
	what decides how long the sound actually takes: a sound sped up to 1.3 is
	over sooner than its TimeLength says.

	Never negative. A sound already longer than its target at the moment it
	starts is faded from the start rather than from a time in the past.
]]
function Audio.fadeStartSeconds(
	soundSeconds: number,
	targetSeconds: number,
	playbackSpeed: number,
	fadeSeconds: number
): number?
	-- Checked before the comparisons rather than left to propagate: a NaN
	-- target passes `<= 0`, then passes `playSeconds <= targetSeconds`, and
	-- would come out of math.max as a delay nothing can be scheduled against.
	if
		soundSeconds ~= soundSeconds
		or targetSeconds ~= targetSeconds
		or playbackSpeed ~= playbackSpeed
	then
		return nil
	end

	if soundSeconds <= 0 or targetSeconds <= 0 or playbackSpeed <= 0 then
		return nil
	end

	if soundSeconds / playbackSpeed <= targetSeconds then
		return nil
	end

	return math.max(targetSeconds - fadeSeconds, 0)
end

return Audio
