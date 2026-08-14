--!strict
--[[
	StaminaBarController — drives the existing StarterGui.StaminaBar screen from
	the stamina StaminaController receives.

	Display only. It never touches the pool, and there is nothing for it to touch
	it with: stamina reaches this client as a server -> client message and has no
	return path. See StaminaService.

	Layout is Studio-owned (see docs/ui-workflow.md). This file creates nothing,
	styles nothing and positions nothing. It drives exactly two properties --
	StaminaBar.Enabled and Fill.Size -- and depends on this hierarchy, which is a
	contract with the designer:

		StaminaBar (ScreenGui)  ResetOnSpawn = false, ships Enabled = false
		  Bar (Frame)
		    Track (Frame)       ClipsDescendants = true
		      Fill (Frame)      width driven from current/max

	Deliberately narrower than the health bar's contract: no Amount label, since
	stamina reads as a bar rather than as a number. Renaming any of the four
	breaks this controller the same way renaming a function would. Every lookup
	below warns by name if it fails, so a stale place file reads as one clear
	line in Output instead of a nil index.

	Nothing here is bound to a character, so a respawn needs no handling: the
	ScreenGui survives (ResetOnSpawn = false), and the server sends the new
	character's full pool, which hides the bar again. That is also why the
	visibility rule is written against the value rather than against a Humanoid.

	The fill is eased towards the last value the server sent rather than snapped
	to it, because the server sends about five updates a second and snapping to
	those would visibly step. The easing runs on a Heartbeat connection that
	exists only while the bar is actually catching up and disconnects the moment
	it arrives -- an idle player costs nothing per frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Logger = require(Shared.Util.Logger)
local StaminaState = require(Shared.Stamina.StaminaState)

local StaminaController = require(script.Parent.StaminaController)

local log = Logger.forScope("StaminaBarController")

local INSTANCE_WAIT_TIMEOUT_SECONDS = 10

-- Roughly how long the fill takes to cover a gap it is behind by. Short enough
-- that the bar still reads as responsive to a punch landing, long enough to
-- smooth over the gaps between updates.
local SMOOTHING_SECONDS = 0.12

-- How close counts as arrived, as a fraction of the whole bar. Below this the
-- easing would be moving the fill by less than a pixel on any sane bar, so it
-- snaps and stops.
local SETTLED_EPSILON = 0.001

local StaminaBarController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local fill: Frame? = nil

-- What the server last said, and what is currently drawn. They differ only
-- while the easing is catching up.
local targetFraction = 1
local shownFraction = 1

local easingConn: RBXScriptConnection? = nil

--[[
	Pushes the currently drawn fraction onto the two properties this controller
	owns.

	The bar stays visible until the fill has actually arrived at full, not from
	the instant the number reaches it -- otherwise the last stretch of a refill
	is spent hidden and the bar appears to vanish part-empty. This is the easing
	finishing, not a fade-out timer: at full stamina with nothing in flight it is
	hidden on the same frame.
]]
local function render()
	local fillFrame = fill
	local screenGui = screen
	if fillFrame == nil or screenGui == nil then
		return
	end

	fillFrame.Size = UDim2.fromScale(shownFraction, 1)
	screenGui.Enabled = targetFraction < 1 or shownFraction < 1
end

local function onHeartbeat(deltaTime: number)
	local gap = targetFraction - shownFraction

	if math.abs(gap) <= SETTLED_EPSILON then
		shownFraction = targetFraction
		render()

		if easingConn then
			easingConn:Disconnect()
			easingConn = nil
		end
		return
	end

	-- Framerate-independent: the fraction of the remaining gap covered this
	-- frame is derived from how long the frame actually was, so the bar takes
	-- the same wall-clock time to catch up at 30fps as at 240.
	shownFraction += gap * math.min(deltaTime / SMOOTHING_SECONDS, 1)
	render()
end

local function onStaminaChanged(state: StaminaState.StaminaState)
	targetFraction = StaminaState.fillFraction(state)

	-- Rendered immediately as well as on the next frame, so the Enabled flip
	-- happens on the message rather than one frame after it.
	render()

	-- Only while there is a gap to close, so a bar that is already showing the
	-- right value -- a full pool on spawn, most of all -- never holds a
	-- per-frame connection open.
	if easingConn == nil and math.abs(targetFraction - shownFraction) > SETTLED_EPSILON then
		easingConn = RunService.Heartbeat:Connect(onHeartbeat)
	end
end

--[[
	Resolves one expected UI child, warning by full name if it is missing or is
	not the class this controller expects to drive.
]]
local function waitForUiChild(parent: Instance, name: string, className: string): Instance?
	local child = parent:WaitForChild(name, INSTANCE_WAIT_TIMEOUT_SECONDS)
	if child == nil then
		log.warn(`{parent:GetFullName()}.{name} is missing; is your place file up to date?`)
		return nil
	end

	if not child:IsA(className) then
		log.warn(`{child:GetFullName()} is a {child.ClassName}, expected a {className}`)
		return nil
	end

	return child
end

--[[
	Resolves the whole StaminaBar hierarchy once. Returns false if any part of it
	is missing, in which case the controller stays inert rather than warning on
	every stamina change for the rest of the session.
]]
local function findUi(): boolean
	local playerGui = player:WaitForChild("PlayerGui", INSTANCE_WAIT_TIMEOUT_SECONDS)
	if playerGui == nil then
		log.warn("PlayerGui never appeared; the stamina bar cannot be driven")
		return false
	end

	local screenGui = waitForUiChild(playerGui, "StaminaBar", "ScreenGui")
	if screenGui == nil then
		return false
	end

	local bar = waitForUiChild(screenGui, "Bar", "Frame")
	if bar == nil then
		return false
	end

	local track = waitForUiChild(bar, "Track", "Frame")
	if track == nil then
		return false
	end

	local fillFrame = waitForUiChild(track, "Fill", "Frame")
	if fillFrame == nil then
		return false
	end

	screen = screenGui :: ScreenGui
	fill = fillFrame :: Frame
	return true
end

function StaminaBarController.Start()
	if not findUi() then
		return
	end

	StaminaController.onChanged(onStaminaChanged)

	-- StaminaController assumes a full pool until the server says otherwise, and
	-- a full pool is a hidden bar. Drawing that now means the designer's preview
	-- fill is never on screen, even for the frame before the first update.
	onStaminaChanged(StaminaController.getState())

	log.info("driving StarterGui.StaminaBar")
end

return StaminaBarController
