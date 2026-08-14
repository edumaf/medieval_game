--!strict
--[[
	ScreenEffectsController — the red/green vignette that reports the local
	player's health to them at the edges of their screen.

	No remote is involved, and no new one was added. HealthService owns health
	on the server and mirrors it onto Humanoid.Health/MaxHealth, and Humanoid
	properties replicate server -> client on their own, so this controller reads
	the same two signals HealthBarController already reads — HealthChanged for
	damage and healing, and Humanoid.Died for death, which ParryController also
	binds. A remote would duplicate a channel that already exists; it would also
	buy nothing in safety, because this is display-only and shows a player their
	own health. A modified client could only lie to itself about the colour of
	its own screen, while the server keeps deciding damage either way. See
	docs/decisions.md.

	What is on screen is decided in ScreenEffectState, which is pure and
	tested; this file owns the instances, the tween and the character bindings,
	and nothing else. The split is the same one HealthBarController and
	HealthDisplay use.

	How the vignette is drawn: four Frames, one per screen edge, each with a
	UIGradient that runs from opaque at the outer edge to clear at the inner
	one. Overlapping at the corners is what gives it a vignette's shape, and the
	middle of the screen is left clear at any reach below half. Three properties
	animate it and no others:

	  BackgroundTransparency  the whole effect's strength.
	  Size                    how far in from the edge each band reaches, which
	                          is what lets death expand towards the centre.
	  BackgroundColor3        red or green, set once when an effect starts.

	Unlike every other screen in this game, these instances are built here
	rather than authored in Studio (docs/ui-workflow.md). That rule exists to
	keep layout in the designer's hands, and this has no layout to hand over:
	four full-bleed bands pinned to the screen edges, with no position, no
	styling and no text for anyone to lay out, whose geometry is animated
	frame by frame from Config. Everything the designer would tune — the three
	colours, both reaches, all three durations — is in Config rather than baked
	in here. If it ever grows a border, an icon or anything with a position,
	it should move into StarterGui and be driven by name like the health bar.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)

local ScreenEffectState = require(script.ScreenEffectState)

local log = Logger.forScope("ScreenEffectsController")

local INSTANCE_WAIT_TIMEOUT_SECONDS = 10

-- Behind everything the designer put on screen. The vignette is feedback about
-- the HUD's contents, so it must never sit on top of the health bar it is
-- reporting.
local DISPLAY_ORDER = -1

-- Opaque at the outer edge, clear by the inner one. The middle keypoint bends
-- the falloff towards the edge so the colour hugs the border instead of
-- washing evenly across the band.
local EDGE_FALLOFF = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.45, 0.55),
	NumberSequenceKeypoint.new(1, 1),
})

--[[
	One edge band. `thicknessIsWidth` says which axis the band's reach is
	measured along; `gradientRotation` turns the gradient so its opaque end
	lands on that band's own screen edge — 0 is left-to-right, and every
	quarter turn moves the opaque end clockwise.
]]
type BandLayout = {
	name: string,
	anchorPoint: Vector2,
	position: UDim2,
	thicknessIsWidth: boolean,
	gradientRotation: number,
}

local BAND_LAYOUTS: { BandLayout } = {
	{
		name = "Left",
		anchorPoint = Vector2.new(0, 0),
		position = UDim2.fromScale(0, 0),
		thicknessIsWidth = true,
		gradientRotation = 0,
	},
	{
		name = "Right",
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.fromScale(1, 0),
		thicknessIsWidth = true,
		gradientRotation = 180,
	},
	{
		name = "Top",
		anchorPoint = Vector2.new(0, 0),
		position = UDim2.fromScale(0, 0),
		thicknessIsWidth = false,
		gradientRotation = 90,
	},
	{
		name = "Bottom",
		anchorPoint = Vector2.new(0, 1),
		position = UDim2.fromScale(0, 1),
		thicknessIsWidth = false,
		gradientRotation = 270,
	},
}

local TUNING: ScreenEffectState.Tuning = {
	damageColor = Config.ScreenEffectDamageColor,
	healColor = Config.ScreenEffectHealColor,
	deathColor = Config.ScreenEffectDeathColor,
	minIntensity = Config.ScreenEffectMinIntensity,
	maxIntensity = Config.ScreenEffectMaxIntensity,
	deathIntensity = Config.ScreenEffectDeathIntensity,
	minHealthChange = Config.ScreenEffectMinHealthChange,
	edgeReach = Config.ScreenEffectEdgeReach,
	deathEdgeReach = Config.ScreenEffectDeathEdgeReach,
}

local RISE_TWEEN =
	TweenInfo.new(Config.ScreenEffectRiseSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_TWEEN =
	TweenInfo.new(Config.ScreenEffectFadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEATH_TWEEN = TweenInfo.new(
	Config.ScreenEffectDeathRiseSeconds,
	Enum.EasingStyle.Quint,
	Enum.EasingDirection.Out
)
local CLEAR_TWEEN =
	TweenInfo.new(Config.ScreenEffectClearSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local ScreenEffectsController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local bands: { Frame } = {}

-- How far through the current effect the animation is, from 0 (nothing on
-- screen) to 1 (the effect at its peak). Everything the player sees is derived
-- from this one number, so there is exactly one tween running at any moment and
-- no two properties can ever animate out of step with each other.
local level: NumberValue? = nil

local activeTween: Tween? = nil

-- Bumped on every tween this controller starts. A Completed handler that finds
-- the counter has moved on belongs to a tween something replaced, and must not
-- run the step it was going to queue next -- that, not cancelling alone, is
-- what stops a fade from a previous hit finishing on top of a newer one.
local generation = 0

local state = ScreenEffectState.initial()

-- The health the current character was last seen at. Kept rather than read back
-- off the Humanoid because HealthChanged only reports the new value, and the
-- difference between the two is the entire input to the rules. nil while there
-- is no character to compare against.
local previousHealth: number? = nil

-- Only the connections are kept, never the Humanoid itself: there is then no
-- reference that can go stale when a character is replaced.
local healthChangedConn: RBXScriptConnection? = nil
local diedConn: RBXScriptConnection? = nil

--[[
	Pushes the current effect and the current level onto the four bands.

	Called for every step of the tween, and this is the only place any of the
	animated properties are written -- both the strength and the reach come out
	of the same `level`, so they cannot disagree.

	With no effect showing there is nothing to derive a colour or a reach from,
	so the bands are simply cleared.
]]
local function render()
	local driver = level
	if driver == nil then
		return
	end

	local effect = ScreenEffectState.showing(state)
	if effect == nil then
		for _, band in bands do
			band.BackgroundTransparency = 1
		end
		return
	end

	local alpha = math.clamp(driver.Value, 0, 1)
	local transparency = 1 - effect.intensity * alpha
	-- Every effect starts from the resting reach and grows towards its own.
	-- For damage and healing the two are the same value, so the bands hold
	-- their size and only the strength moves; death is what makes this a
	-- spread inwards.
	local reach = Config.ScreenEffectEdgeReach
		+ (effect.reach - Config.ScreenEffectEdgeReach) * alpha

	for index, band in bands do
		band.BackgroundTransparency = transparency
		band.Size = if BAND_LAYOUTS[index].thicknessIsWidth
			then UDim2.fromScale(reach, 1)
			else UDim2.fromScale(1, reach)
	end
end

local function setColor(color: Color3)
	for _, band in bands do
		band.BackgroundColor3 = color
	end
end

local function setVisible(visible: boolean)
	local screenGui = screen
	if screenGui then
		screenGui.Enabled = visible
	end
end

--[[
	Animates `level` to `target`, replacing whatever was running.

	`onFinished` runs only if the tween reached its target and nothing started
	another one in the meantime -- a cancelled tween raises Completed too, with
	a Cancelled state, and the generation check covers the rarer case of a
	replacement that is already finished by the time this handler runs.
]]
local function playTo(target: number, info: TweenInfo, onFinished: (() -> ())?)
	local driver = level
	if driver == nil then
		return
	end

	local previous = activeTween
	if previous then
		previous:Cancel()
	end

	generation += 1
	local thisGeneration = generation

	local tween = TweenService:Create(driver, info, { Value = target })
	activeTween = tween

	-- The one connection in this file with no matching disconnect, deliberately:
	-- it belongs to a parentless Tween that nothing references once it has
	-- finished and been replaced, so it is collected along with the tween. There
	-- is no long-lived signal here to leak off, which is what that rule is about.
	tween.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if playbackState ~= Enum.PlaybackState.Completed or generation ~= thisGeneration then
			return
		end

		activeTween = nil
		if onFinished then
			onFinished()
		end
	end)

	tween:Play()
end

--[[
	The effect has run its course. Nothing is showing, so the screen goes back
	to being nobody's business.
]]
local function finish()
	state = ScreenEffectState.initial()
	render()
	setVisible(false)
end

--[[
	Plays `effect`, unless what is already on screen outranks it. See
	ScreenEffectState.withEffect for which of the two wins.

	A tween that is part-way through is never waited for: the rise starts from
	wherever `level` currently is, so a second hit during a fade lifts the
	vignette back up from where it had got to instead of snapping to zero and
	climbing again.
]]
local function show(effect: ScreenEffectState.ScreenEffect)
	local nextState = ScreenEffectState.withEffect(state, effect)
	if nextState == state then
		return
	end

	state = nextState

	local showing = ScreenEffectState.showing(state)
	if showing == nil then
		return
	end

	setColor(showing.color)
	setVisible(true)
	render()

	if showing.kind == "death" then
		-- No fade queued. A death holds at its peak until a new character
		-- arrives and clears it.
		playTo(1, DEATH_TWEEN)
		return
	end

	playTo(1, RISE_TWEEN, function()
		playTo(0, FADE_TWEEN, finish)
	end)
end

--[[
	Takes the screen back to normal, whatever was on it. Used on respawn, which
	is the only way out of a death vignette.
]]
local function clear()
	if ScreenEffectState.showing(state) == nil then
		return
	end

	playTo(0, CLEAR_TWEEN, finish)
end

local function onHealthChanged(humanoid: Humanoid, health: number)
	local previous = previousHealth
	-- Updated even when nothing is drawn, so a run of changes too small to be
	-- worth showing is measured against the last one seen rather than
	-- accumulating into a flash the player has no explanation for.
	previousHealth = health

	if previous == nil then
		return
	end

	local effect = ScreenEffectState.forHealthChange(previous, health, humanoid.MaxHealth, TUNING)
	if effect then
		show(effect)
	end
end

local function disconnectHumanoid()
	if healthChangedConn then
		healthChangedConn:Disconnect()
		healthChangedConn = nil
	end
	if diedConn then
		diedConn:Disconnect()
		diedConn = nil
	end
	previousHealth = nil
end

local function onCharacterAdded(character: Model)
	-- A respawn lands here again. Drop the previous character's connections
	-- first so a dying Humanoid can never draw over a live one.
	disconnectHumanoid()

	-- The new character is the end of the old one's death vignette. Deliberately
	-- here rather than in CharacterRemoving: the player should still be looking
	-- at a red screen while they are waiting to respawn.
	clear()

	local found = character:WaitForChild("Humanoid", INSTANCE_WAIT_TIMEOUT_SECONDS)
	if found == nil then
		log.warn(`{character.Name} has no Humanoid; screen effects will not play for it`)
		return
	end
	local humanoid = found :: Humanoid

	-- WaitForChild yields, so the player may have respawned again while this
	-- was waiting. Binding to a character that is no longer the live one would
	-- draw a corpse's health changes.
	if player.Character ~= character then
		return
	end

	-- Read once, now, so the first HealthChanged has something to be a change
	-- *from*. Spawning at full health is not a heal, and must not flash green.
	previousHealth = humanoid.Health

	healthChangedConn = humanoid.HealthChanged:Connect(function(health: number)
		onHealthChanged(humanoid, health)
	end)

	-- Bound as well as, not instead of, the zero-health rule in
	-- ScreenEffectState.forHealthChange. Whichever of the two arrives first
	-- draws the death; the other one finds a death already showing and is
	-- ignored, so the vignette is played exactly once however Roblox orders
	-- the two events.
	diedConn = humanoid.Died:Connect(function()
		show(ScreenEffectState.death(TUNING))
	end)
end

--[[
	Builds the ScreenGui and its four bands. Returns false if there is no
	PlayerGui to build them in, in which case the controller stays inert rather
	than erroring on every health change for the rest of the session.
]]
local function buildUi(): boolean
	local playerGui = player:WaitForChild("PlayerGui", INSTANCE_WAIT_TIMEOUT_SECONDS)
	if playerGui == nil then
		log.warn("PlayerGui never appeared; screen effects cannot be drawn")
		return false
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ScreenEffects"
	-- Built straight into PlayerGui rather than cloned out of StarterGui, so
	-- nothing resets it on respawn to begin with and the death vignette stays
	-- up across the respawn wait. Set anyway, so the intent survives if this
	-- ever moves into StarterGui: clearing the effect is this controller's
	-- decision, not Roblox's.
	screenGui.ResetOnSpawn = false
	-- The effect is about the edges of the screen, so it has to reach the ones
	-- the top bar would otherwise cover.
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = DISPLAY_ORDER
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Off until something is actually being shown, so nothing is rendered and
	-- nothing can flash on join.
	screenGui.Enabled = false

	local driver = Instance.new("NumberValue")
	driver.Name = "Level"
	driver.Value = 0
	driver.Parent = screenGui

	for _, layout in BAND_LAYOUTS do
		local band = Instance.new("Frame")
		band.Name = layout.name
		band.AnchorPoint = layout.anchorPoint
		band.Position = layout.position
		band.Size = if layout.thicknessIsWidth
			then UDim2.fromScale(Config.ScreenEffectEdgeReach, 1)
			else UDim2.fromScale(1, Config.ScreenEffectEdgeReach)
		band.BackgroundColor3 = Config.ScreenEffectDamageColor
		band.BackgroundTransparency = 1
		band.BorderSizePixel = 0
		-- Inert: a band that took input would swallow the left click that
		-- throws a punch for as long as it was on screen.
		band.Active = false
		band.Parent = screenGui

		local gradient = Instance.new("UIGradient")
		gradient.Transparency = EDGE_FALLOFF
		gradient.Rotation = layout.gradientRotation
		gradient.Parent = band

		table.insert(bands, band)
	end

	screenGui.Parent = playerGui

	screen = screenGui
	level = driver

	driver.Changed:Connect(render)
	return true
end

function ScreenEffectsController.Start()
	if not buildUi() then
		return
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		-- The vignette itself is deliberately left alone: a death is still
		-- being shown at this point, and onCharacterAdded is what ends it.
		-- Only the connections have to go.
		disconnectHumanoid()
	end)

	-- The character can exist before this controller starts.
	if player.Character then
		onCharacterAdded(player.Character)
	end

	log.info("watching health for screen effects")
end

return ScreenEffectsController
