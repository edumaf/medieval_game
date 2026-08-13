--!strict
--[[
	HealthBarController — drives the existing StarterGui.HealthBar screen from
	the local player's Humanoid.

	No remote is involved. HealthService owns health on the server and mirrors
	it onto Humanoid.Health/MaxHealth, and Humanoid properties replicate
	server -> client on their own, so this controller only has to read them.
	Adding a remote would duplicate a channel that already exists; it is also
	unnecessary for safety, since this bar is display-only and shows a player
	their own health -- a modified client could only lie to itself, while the
	server keeps deciding damage either way.

	Layout is Studio-owned (see docs/ui-workflow.md). This file creates
	nothing, styles nothing and positions nothing. It drives exactly three
	properties -- HealthBar.Enabled, Fill.Size and Amount.Text -- and depends
	on this hierarchy, which is a contract with the designer:

		HealthBar (ScreenGui)   ResetOnSpawn = false, ships Enabled = false
		  Bar (Frame)
		    Track (Frame)
		      Fill (Frame)      width driven from health/maxHealth
		    Amount (TextLabel)  text driven from health and maxHealth

	Renaming any of those breaks this controller the same way renaming a
	function would. Every lookup below warns by name if it fails, so a stale
	place file reads as one clear line in Output instead of a nil index.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Logger = require(Shared.Util.Logger)

local HealthDisplay = require(script.HealthDisplay)

local log = Logger.forScope("HealthBarController")

local INSTANCE_WAIT_TIMEOUT_SECONDS = 10

local HealthBarController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local fill: Frame? = nil
local amount: TextLabel? = nil

-- Only the connections are kept, never the Humanoid itself: there is then no
-- reference that can go stale when a character is replaced.
local healthChangedConn: RBXScriptConnection? = nil
local maxHealthChangedConn: RBXScriptConnection? = nil

--[[
	Pushes a health pair onto the two properties this controller owns. All of
	the clamping, the divide-by-zero guard and the rounding live in
	HealthDisplay, so this stays a straight assignment.
]]
local function render(health: number, maxHealth: number)
	local fillFrame = fill
	local amountLabel = amount
	if fillFrame == nil or amountLabel == nil then
		return
	end

	fillFrame.Size = UDim2.new(HealthDisplay.fillFraction(health, maxHealth), 0, 1, 0)
	amountLabel.Text = HealthDisplay.text(health, maxHealth)
end

local function disconnectHumanoid()
	if healthChangedConn then
		healthChangedConn:Disconnect()
		healthChangedConn = nil
	end
	if maxHealthChangedConn then
		maxHealthChangedConn:Disconnect()
		maxHealthChangedConn = nil
	end
end

--[[
	Resolves one expected UI child, warning by full name if it is missing or
	is not the class this controller expects to drive.
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
	Resolves the whole HealthBar hierarchy once. Returns false if any part of
	it is missing, in which case the controller stays inert rather than
	erroring on every health change for the rest of the session.
]]
local function findUi(): boolean
	local playerGui = player:WaitForChild("PlayerGui", INSTANCE_WAIT_TIMEOUT_SECONDS)
	if playerGui == nil then
		log.warn("PlayerGui never appeared; the health bar cannot be driven")
		return false
	end

	local screenGui = waitForUiChild(playerGui, "HealthBar", "ScreenGui")
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

	local amountLabel = waitForUiChild(bar, "Amount", "TextLabel")
	if amountLabel == nil then
		return false
	end

	screen = screenGui :: ScreenGui
	fill = fillFrame :: Frame
	amount = amountLabel :: TextLabel
	return true
end

local function onCharacterAdded(character: Model)
	-- A respawn lands here again. Drop the previous character's connections
	-- first so a dead Humanoid can never render over a live one.
	disconnectHumanoid()

	local found = character:WaitForChild("Humanoid", INSTANCE_WAIT_TIMEOUT_SECONDS)
	if found == nil then
		log.warn(`{character.Name} has no Humanoid; the health bar will not update for it`)
		return
	end
	local humanoid = found :: Humanoid

	-- WaitForChild yields, so the player may have respawned again while this
	-- was waiting. Binding to a character that is no longer the live one
	-- would pin the bar to a corpse.
	if player.Character ~= character then
		return
	end

	healthChangedConn = humanoid.HealthChanged:Connect(function(health: number)
		render(health, humanoid.MaxHealth)
	end)
	maxHealthChangedConn = humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		render(humanoid.Health, humanoid.MaxHealth)
	end)

	-- HealthService has usually set both properties before this runs, and
	-- neither event fires again until something changes them, so read the
	-- current values instead of waiting for a change that may never come.
	render(humanoid.Health, humanoid.MaxHealth)

	-- Enabled only now: until this point the bar still carries the designer's
	-- 75/100 preview, and showing that before real health arrives would be a
	-- visible lie.
	local screenGui = screen
	if screenGui then
		screenGui.Enabled = true
	end
end

function HealthBarController.Start()
	if not findUi() then
		return
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		-- The ScreenGui itself survives (ResetOnSpawn = false), so the bar
		-- holds its last values -- 0/100 after a death -- until the new
		-- character reports its own. Only the connections have to go.
		disconnectHumanoid()
	end)

	-- The character can exist before this controller starts.
	if player.Character then
		onCharacterAdded(player.Character)
	end

	log.info("driving StarterGui.HealthBar")
end

return HealthBarController
