--!strict
--[[
	Guards the invariants other systems rely on: Config is immutable, and
	GameVersion stays in a shape the handshake can compare.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Types = require(ReplicatedStorage.Shared.Types)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Shared.Config", function()
	it("is frozen so no system can mutate shared configuration at runtime", function()
		expect(table.isfrozen(Config)).toBe(true)
	end)

	it("exposes a three-part GameVersion", function()
		expect(Config.GameVersion).toEqual(expect.any("string"))
		expect(string.match(Config.GameVersion, "^%d+%.%d+%.%d+$")).never.toBeNil()
	end)

	it("uses a log level Logger understands", function()
		local allowed = { debug = true, info = true, warn = true }
		expect(allowed[Config.LogLevel]).toBe(true)
	end)

	it("states the punch animation as an asset id, or as no animation at all", function()
		-- A malformed id is silent in game: the track loads, plays nothing,
		-- and the "Hit" marker never arrives, so punches simply stop landing.
		-- Empty is the supported "no animation" state, which PunchController
		-- handles by reporting the hit on the click.
		expect(Config.PunchAnimationId).toEqual(expect.any("string"))
		if Config.PunchAnimationId ~= "" then
			expect(string.match(Config.PunchAnimationId, "^rbxassetid://%d+$")).never.toBeNil()
		end
	end)

	it("names a hit marker for PunchController to bind", function()
		expect(Config.PunchHitMarkerName).toEqual(expect.any("string"))
		expect(#Config.PunchHitMarkerName > 0).toBe(true)
	end)

	it("keeps lag compensation smaller than the punch range itself", function()
		-- The allowance is meant to cover the gap between where a running
		-- target is drawn and where it is. Letting it grow past the reach
		-- would turn the punch into something you could land from clean across
		-- the gap, which is the failure mode the tuning has to stay clear of.
		expect(Config.PunchMaxCompensationStuds >= 0).toBe(true)
		expect(Config.PunchMaxCompensationStuds < Config.PunchRange).toBe(true)
	end)

	it("compensates for a plausible fraction of a second", function()
		-- Negative would push targets away; a large value would hand a sprinting
		-- target several extra studs of reach.
		expect(Config.PunchLagCompensationSeconds >= 0).toBe(true)
		expect(Config.PunchLagCompensationSeconds <= 0.5).toBe(true)
	end)

	it("states the parry animation as an asset id, or as no animation at all", function()
		-- Same failure mode as the punch animation: a malformed id loads a
		-- track that plays nothing, so the "Hold" marker never arrives and the
		-- parry winds up forever without ever protecting anyone. Empty is the
		-- supported "no animation" state, which ParryController handles by
		-- reaching the guard on the key press.
		expect(Config.ParryAnimationId).toEqual(expect.any("string"))
		if Config.ParryAnimationId ~= "" then
			expect(string.match(Config.ParryAnimationId, "^rbxassetid://%d+$")).never.toBeNil()
		end
	end)

	it("names a hold marker for ParryController to bind", function()
		expect(Config.ParryHoldMarkerName).toEqual(expect.any("string"))
		expect(#Config.ParryHoldMarkerName > 0).toBe(true)
	end)

	it("ships the agreed parry numbers", function()
		-- Pinned deliberately. Both were settled decisions rather than tuning
		-- knobs, and each has a rule attached that is not obvious from the
		-- number alone: the arc is the forward hemisphere, and the slowdown is
		-- half of walking. Changing one should be a decision, not a diff nobody
		-- noticed.
		expect(Config.ParryWalkSpeed).toBe(8)
		expect(Config.ParryMinFacingDot).toBe(0)
	end)

	it("guards at least the forward hemisphere and never the back", function()
		-- Below 0 the guard would start covering directions behind the
		-- defender, which is the "invulnerable from everywhere" failure the
		-- feature is defined against. Above 1 nothing could ever be parried.
		expect(Config.ParryMinFacingDot >= 0).toBe(true)
		expect(Config.ParryMinFacingDot <= 1).toBe(true)
	end)

	it("keeps dying visibly stronger than any hit can be", function()
		-- ScreenEffectsController scales a hit between the two intensities and
		-- draws a death at the third. If an ordinary hit could reach the death
		-- intensity, the two effects would stop being distinguishable, which is
		-- the one thing the death vignette exists to be.
		expect(Config.ScreenEffectMinIntensity > 0).toBe(true)
		expect(Config.ScreenEffectMinIntensity < Config.ScreenEffectMaxIntensity).toBe(true)
		expect(Config.ScreenEffectMaxIntensity < Config.ScreenEffectDeathIntensity).toBe(true)
		expect(Config.ScreenEffectDeathIntensity <= 1).toBe(true)
	end)

	it("leaves the middle of the screen clear until the player dies", function()
		-- The four bands meet at half the screen. A resting reach at or above
		-- that would cover the centre during ordinary combat; a death reach at
		-- or below the resting one would make dying darken the edges rather
		-- than spread inwards.
		expect(Config.ScreenEffectEdgeReach > 0).toBe(true)
		expect(Config.ScreenEffectEdgeReach < 0.5).toBe(true)
		expect(Config.ScreenEffectEdgeReach < Config.ScreenEffectDeathEdgeReach).toBe(true)
		expect(Config.ScreenEffectDeathEdgeReach <= 0.5).toBe(true)
	end)

	it("draws a hit quickly and a death slowly", function()
		-- A hit has to register at the moment it lands, so its rise is much
		-- shorter than its fade. A death is the opposite: the slow spread is
		-- what makes it read as dying rather than as being hit hard.
		expect(Config.ScreenEffectRiseSeconds > 0).toBe(true)
		expect(Config.ScreenEffectRiseSeconds < Config.ScreenEffectFadeSeconds).toBe(true)
		expect(Config.ScreenEffectFadeSeconds < Config.ScreenEffectDeathRiseSeconds).toBe(true)
		expect(Config.ScreenEffectClearSeconds > 0).toBe(true)
	end)

	it("keeps exhaustion visible, but never as loud as dying", function()
		-- The ordering is the whole point: above the floor so running out of
		-- stamina cannot be mistaken for a scratch, and below dying so nothing
		-- survivable ever looks like death.
		expect(Config.ScreenEffectExhaustionIntensity > Config.ScreenEffectMinIntensity).toBe(true)
		expect(Config.ScreenEffectExhaustionIntensity < Config.ScreenEffectDeathIntensity).toBe(
			true
		)
	end)

	it("draws exhaustion in a dark grey that is not pure black", function()
		-- Near-black reads as draining; a flat 0,0,0 edge reads as the screen
		-- having failed. Kept dark enough that it cannot be confused with the
		-- red and green health effects.
		local color = Config.ScreenEffectExhaustionColor
		local brightest = math.max(color.R, color.G, color.B)

		expect(brightest > 0).toBe(true)
		expect(brightest < 0.35).toBe(true)
	end)

	it("holds the exhaustion vignette before fading it", function()
		-- The hold is what separates this from a damage flash, and the long fade
		-- is what makes it read as recovering. A zero hold would collapse it
		-- into another hit.
		expect(Config.ScreenEffectExhaustionRiseSeconds > 0).toBe(true)
		expect(Config.ScreenEffectExhaustionHoldSeconds > 0).toBe(true)
		expect(Config.ScreenEffectExhaustionRiseSeconds < Config.ScreenEffectExhaustionFadeSeconds).toBe(
			true
		)
	end)

	it("ignores health changes too small to be worth a flash", function()
		-- Zero would let Roblox's passive regeneration, and HealthService
		-- snapping it back, flicker the screen. Anything as large as a punch
		-- would drop hits that should be drawn.
		expect(Config.ScreenEffectMinHealthChange > 0).toBe(true)
		expect(Config.ScreenEffectMinHealthChange < Config.PunchDamage).toBe(true)
	end)

	it("states every sound as an asset id, or as no sound at all", function()
		-- Same convention and same failure mode as the two animation ids: a
		-- malformed id is silent in game, and empty is the supported "not
		-- uploaded yet" state that Audio.create answers nil for.
		local sounds: { Types.SoundSpec } = {
			Config.PunchSwingSound,
			Config.PunchImpactSound,
			Config.ScreenEffectDamageSound,
			Config.ScreenEffectHealSound,
			-- Ships with an empty id, which is the "not uploaded yet" case this
			-- test exists to allow. Every other property still has to be sane,
			-- so that filling in the id is the only change needed.
			Config.ScreenEffectExhaustionSound,
		}

		for _, spec in sounds do
			expect(spec.id).toEqual(expect.any("string"))
			if spec.id ~= "" then
				expect(string.match(spec.id, "^rbxassetid://%d+$")).never.toBeNil()
			end

			-- Zero volume is a sound nobody can hear, which is indistinguishable
			-- from a broken one; above 1 is clipping.
			expect(spec.volume > 0).toBe(true)
			expect(spec.volume <= 1).toBe(true)

			-- Zero or negative would never finish, and Audio's fade arithmetic
			-- divides by it.
			expect(spec.playbackSpeed > 0).toBe(true)
		end
	end)

	it("freezes each sound spec, not just the config around them", function()
		-- table.freeze is shallow, so without freezing these individually they
		-- would be the one writable corner of an otherwise immutable Config.
		expect(table.isfrozen(Config.PunchSwingSound)).toBe(true)
		expect(table.isfrozen(Config.PunchImpactSound)).toBe(true)
		expect(table.isfrozen(Config.ScreenEffectDamageSound)).toBe(true)
		expect(table.isfrozen(Config.ScreenEffectHealSound)).toBe(true)
		expect(table.isfrozen(Config.ScreenEffectExhaustionSound)).toBe(true)
	end)

	it("gives the punch impact a longer reach than the swing has", function()
		-- The impact is the half of the punch other players are meant to hear,
		-- and the only one of the four that is actually positional. The
		-- ordering is the part worth pinning: a swing audible from further away
		-- than the hit it belongs to would be backwards.
		expect(
			Config.PunchImpactSound.rollOffMaxDistance > Config.PunchSwingSound.rollOffMaxDistance
		).toBe(true)

		for _, spec in { Config.PunchSwingSound, Config.PunchImpactSound } :: { Types.SoundSpec } do
			expect(spec.rollOffMinDistance > 0).toBe(true)
			expect(spec.rollOffMinDistance < spec.rollOffMaxDistance).toBe(true)
		end
	end)

	it("keeps the swing's pitch correction within a tone either way", function()
		-- These bounds are what stops fitting the sound to the animation from
		-- turning it into a different sound; whatever they refuse is faded out
		-- instead. Straddling 1 is what lets a sound be corrected in either
		-- direction.
		expect(Config.PunchSwingMinPlaybackSpeed > 0).toBe(true)
		expect(Config.PunchSwingMinPlaybackSpeed <= 1).toBe(true)
		expect(Config.PunchSwingMaxPlaybackSpeed >= 1).toBe(true)
		expect(Config.PunchSwingMaxPlaybackSpeed <= 2).toBe(true)

		-- The fade has to fit inside the swing it is trimming.
		expect(Config.PunchSwingFadeSeconds > 0).toBe(true)
		expect(Config.PunchSwingFadeSeconds < Config.PunchCooldownSeconds).toBe(true)
	end)

	it("ships a stamina pool with room in it", function()
		-- Everything else in the stamina system divides by this or clamps to it.
		expect(Config.MaxStamina > 0).toBe(true)
	end)

	it("spends stamina in the three ways the system charges for", function()
		-- Any of these at zero silently switches off the cost of an action
		-- without switching off the feature, which is the kind of retune that
		-- reads as "stamina is broken" rather than as a number being wrong.
		expect(Config.SprintStaminaDrainPerSecond > 0).toBe(true)
		expect(Config.ParryStaminaDrainPerSecond > 0).toBe(true)
		expect(Config.PunchStaminaCost > 0).toBe(true)
	end)

	it("regenerates, and leaves a full pool worth more than one punch", function()
		expect(Config.StaminaRegenPerSecond > 0).toBe(true)
		-- A pool that cannot cover a single swing would mean every punch after
		-- the first landed at the reduced multiplier, which is not a difficulty
		-- setting, it is the feature never being off.
		expect(Config.PunchStaminaCost < Config.MaxStamina).toBe(true)
	end)

	it("weakens an exhausted punch without erasing or strengthening it", function()
		-- At 0 the punch would deal nothing and read as a broken hit; at or above
		-- 1 running out of stamina would be free or an upgrade.
		expect(Config.ZeroStaminaPunchDamageMultiplier > 0).toBe(true)
		expect(Config.ZeroStaminaPunchDamageMultiplier < 1).toBe(true)
	end)

	it("makes an exhausted sprinter wait for a real fraction of the pool", function()
		-- At or below 0 the lockout would release on the first tick of
		-- regeneration and the player would judder between walking and sprinting
		-- ten times a second, which is the failure the second threshold exists to
		-- prevent. At or above 1 only a completely full pool would ever release
		-- it, which turns a short exhaustion into the whole regeneration.
		expect(Config.SprintRecoveryStaminaFraction > 0).toBe(true)
		expect(Config.SprintRecoveryStaminaFraction < 1).toBe(true)
	end)

	it("buys back more sprint than the recovery costs to reach", function()
		-- The exhaustion has to be a rhythm rather than a tax: recovering to the
		-- threshold and spending it again should leave the player sprinting for a
		-- usable stretch, not for a step. Both sides are derived from the shipped
		-- rates, so retuning either drain or regen re-checks this.
		local recovered = Config.MaxStamina * Config.SprintRecoveryStaminaFraction
		local sprintSeconds = recovered / Config.SprintStaminaDrainPerSecond

		expect(sprintSeconds >= 1).toBe(true)
	end)

	it("ticks stamina often enough to be a bar rather than a counter", function()
		-- The pool is integrated against real elapsed time, so this only decides
		-- how often the number moves. A quarter of a second is where a drain
		-- would start to look stepped even after the client smooths it.
		expect(Config.StaminaTickIntervalSeconds > 0).toBe(true)
		expect(Config.StaminaTickIntervalSeconds <= 0.25).toBe(true)
	end)

	it("replicates stamina in steps that are neither per-frame nor per-quarter", function()
		-- At or below 0 every tick would send a message, which is the per-frame
		-- spam this threshold exists to prevent; above a quarter of the pool the
		-- bar would visibly jump between updates.
		expect(Config.StaminaReplicationStepFraction > 0).toBe(true)
		expect(Config.StaminaReplicationStepFraction <= 0.25).toBe(true)
	end)

	it("counts a sprint as moving at less than a walk", function()
		-- The threshold only rules out standing still. Set anywhere near the
		-- walking speed it would stop charging for real sprints -- including
		-- every one made uphill or against a wall.
		expect(Config.StaminaSprintMinMoveSpeed > 0).toBe(true)
		expect(Config.StaminaSprintMinMoveSpeed < Config.NormalWalkSpeed).toBe(true)
	end)

	it("keeps sprinting faster than walking, and walking faster than guarding", function()
		-- The precedence RunningController applies, asserted as an ordering so
		-- retuning any one of the three cannot silently invert it. A parry speed
		-- at or above the walking speed would make guarding strictly better than
		-- not guarding; one at or below zero would root the player in place.
		expect(Config.ParryWalkSpeed > 0).toBe(true)
		expect(Config.ParryWalkSpeed < Config.NormalWalkSpeed).toBe(true)
		expect(Config.NormalWalkSpeed < Config.SprintWalkSpeed).toBe(true)
	end)
end)
