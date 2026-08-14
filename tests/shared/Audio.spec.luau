--!strict
--[[
	Covers the arithmetic that fits a sound to a duration it did not come in:
	how far it may be pitched, and when what is left has to be faded out
	instead. No Sound, no loaded asset and no clock -- see docs/testing.md for
	the Studio steps that cover whether the result actually sounds right.

	The numbers here are deliberately round rather than the shipped ones, which
	Config.spec.luau covers separately.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Audio = require(ReplicatedStorage.Shared.Util.Audio)
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local MIN_SPEED = 0.8
local MAX_SPEED = 1.25
local FADE_SECONDS = 0.1

describe("Shared.Util.Audio", function()
	describe("fitPlaybackSpeed", function()
		it("leaves a sound that already lasts the right time alone", function()
			expect(Audio.fitPlaybackSpeed(1, 1, MIN_SPEED, MAX_SPEED)).toBe(1)
		end)

		it("speeds up a sound that is too long", function()
			-- 1.2s into 1s is a ratio of 1.2, inside the bounds, so it is taken
			-- in full and the sound needs no fade at all.
			expect(Audio.fitPlaybackSpeed(1.2, 1, MIN_SPEED, MAX_SPEED)).toBeCloseTo(1.2, 6)
		end)

		it("slows down a sound that is too short", function()
			expect(Audio.fitPlaybackSpeed(0.9, 1, MIN_SPEED, MAX_SPEED)).toBeCloseTo(0.9, 6)
		end)

		it("refuses to pitch a much longer sound all the way", function()
			-- The honest ratio is 3. Taking it would be an octave and a half up,
			-- which is a different sound; the cap is what keeps the fade
			-- responsible for the rest.
			expect(Audio.fitPlaybackSpeed(3, 1, MIN_SPEED, MAX_SPEED)).toBe(MAX_SPEED)
		end)

		it("refuses to pitch a much shorter sound all the way", function()
			expect(Audio.fitPlaybackSpeed(0.1, 1, MIN_SPEED, MAX_SPEED)).toBe(MIN_SPEED)
		end)

		it("stays inside the bounds for every ratio", function()
			for _, soundSeconds in { 0.01, 0.5, 1, 2, 60 } do
				local speed = Audio.fitPlaybackSpeed(soundSeconds, 1, MIN_SPEED, MAX_SPEED)

				expect(speed >= MIN_SPEED).toBe(true)
				expect(speed <= MAX_SPEED).toBe(true)
			end
		end)

		it("plays at natural speed when the sound has not loaded yet", function()
			-- Sound.TimeLength is 0 until the asset arrives, and a ratio built
			-- from it would put a zero into PlaybackSpeed.
			expect(Audio.fitPlaybackSpeed(0, 1, MIN_SPEED, MAX_SPEED)).toBe(1)
		end)

		it("plays at natural speed when there is nothing to fit to", function()
			-- A punch thrown with no animation loaded has no length to match.
			expect(Audio.fitPlaybackSpeed(1, 0, MIN_SPEED, MAX_SPEED)).toBe(1)
			expect(Audio.fitPlaybackSpeed(1, -1, MIN_SPEED, MAX_SPEED)).toBe(1)
		end)

		it("plays at natural speed rather than passing a NaN into PlaybackSpeed", function()
			local nan = 0 / 0

			expect(Audio.fitPlaybackSpeed(nan, 1, MIN_SPEED, MAX_SPEED)).toBe(1)
			expect(Audio.fitPlaybackSpeed(1, nan, MIN_SPEED, MAX_SPEED)).toBe(1)
		end)
	end)

	describe("fadeStartSeconds", function()
		it("asks for no fade when the sound finishes first", function()
			expect(Audio.fadeStartSeconds(0.5, 1, 1, FADE_SECONDS)).toBeNil()
		end)

		it("asks for no fade when the sound finishes exactly on time", function()
			expect(Audio.fadeStartSeconds(1, 1, 1, FADE_SECONDS)).toBeNil()
		end)

		it("fades out so the sound is silent by the target", function()
			-- 2s of sound against a 1s target: the fade has to be over by 1s, so
			-- it starts a fade's length before that.
			expect(Audio.fadeStartSeconds(2, 1, 1, FADE_SECONDS)).toBeCloseTo(0.9, 6)
		end)

		it("accounts for the speed the sound is actually playing at", function()
			-- 1.2s at 1.25x lasts 0.96s, which fits inside a 1s target, so
			-- pitching alone was enough and no fade is needed.
			expect(Audio.fadeStartSeconds(1.2, 1, 1.25, FADE_SECONDS)).toBeNil()
			-- The same sound at natural speed does not fit, and does.
			expect(Audio.fadeStartSeconds(1.2, 1, 1, FADE_SECONDS)).toBeCloseTo(0.9, 6)
		end)

		it("never asks for a fade in the past", function()
			-- A target shorter than the fade itself would otherwise produce a
			-- negative delay, which task.delay treats as "next frame" but which
			-- is a nonsense value to compute.
			expect(Audio.fadeStartSeconds(10, 0.05, 1, FADE_SECONDS)).toBe(0)
		end)

		it("asks for no fade when either duration is missing", function()
			expect(Audio.fadeStartSeconds(0, 1, 1, FADE_SECONDS)).toBeNil()
			expect(Audio.fadeStartSeconds(1, 0, 1, FADE_SECONDS)).toBeNil()
		end)

		it("asks for no fade rather than dividing by a stopped playback speed", function()
			expect(Audio.fadeStartSeconds(2, 1, 0, FADE_SECONDS)).toBeNil()
			expect(Audio.fadeStartSeconds(2, 1, -1, FADE_SECONDS)).toBeNil()
		end)

		it("asks for no fade rather than scheduling one against a NaN", function()
			local nan = 0 / 0

			expect(Audio.fadeStartSeconds(nan, 1, 1, FADE_SECONDS)).toBeNil()
			expect(Audio.fadeStartSeconds(2, nan, 1, FADE_SECONDS)).toBeNil()
			expect(Audio.fadeStartSeconds(2, 1, nan, FADE_SECONDS)).toBeNil()
		end)

		it("agrees with fitPlaybackSpeed on a sound the bounds could not fix", function()
			-- The pair as they are actually used: fit first, then fade whatever
			-- the cap refused. A 3s sound against a 1s swing is capped at 1.25,
			-- so it still runs 2.4s and must be faded out at 0.9s.
			local speed = Audio.fitPlaybackSpeed(3, 1, MIN_SPEED, MAX_SPEED)
			local fadeStart = Audio.fadeStartSeconds(3, 1, speed, FADE_SECONDS)

			expect(speed).toBe(MAX_SPEED)
			expect(fadeStart).toBeCloseTo(0.9, 6)
		end)
	end)
end)
