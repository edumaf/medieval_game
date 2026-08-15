--!strict
--[[
	StaminaController — this client's copy of its own stamina.

	It receives StaminaChanged and remembers the two numbers. That is the whole
	job. It has no authority over any of it: StaminaService owns the pool, and
	nothing here is ever sent back — a modified client editing the values below
	would be lying to nobody but itself, while the server keeps charging the real
	pool and keeps deciding what an empty one costs.

	It exists as its own controller, rather than as part of StaminaBarController,
	because two unrelated things need the number: the bar draws it, and
	ParryController refuses to start a guard without it. A gameplay controller
	requiring a UI controller to find out what its own stamina is would be
	backwards.

	The pool is assumed full until the first message arrives. That is the safe
	direction on both counts: the bar stays hidden rather than flashing an empty
	one on join, and the parry stays available rather than being refused for the
	moment before the server has said anything.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local StaminaState = require(Shared.Stamina.StaminaState)

local log = Logger.forScope("StaminaController")

local StaminaController = {}

local state = StaminaState.new(Config.MaxStamina)

-- Whether the server says this player is exhausted. Received, never computed:
-- StaminaState.isExhausted is a latch, and re-deriving it here from the values
-- above would be a second copy of the memory it needs, free to drift from the
-- one the server is actually enforcing. Assumed false until told otherwise, for
-- the same reason the pool is assumed full.
local exhausted = false

local listeners: { (StaminaState.StaminaState) -> () } = {}

local function onStaminaChanged(current: number, max: number, isExhausted: boolean)
	state = { current = current, max = max }
	exhausted = isExhausted

	for _, listener in listeners do
		listener(state)
	end
end

--[[
	The last stamina the server reported. A copy, so a caller cannot edit the
	table this controller hands to everybody else.
]]
function StaminaController.getState(): StaminaState.StaminaState
	return { current = state.current, max = state.max }
end

--[[
	Whether a guard may be started, by this client's reckoning.

	ParryController checks this before pressing anything, purely to avoid asking
	for a guard the server is going to refuse -- the same job PunchController's
	local cooldown check does. ParryService decides, from its own copy of the
	same rule applied to the server's own copy of the number.
]]
function StaminaController.canBlock(): boolean
	return not exhausted
end

--[[
	Whether the server says this player is exhausted.

	The one exhaustion answer on this client. RunningController takes the sprint
	away by it, ParryController refuses and drops a guard by it, and
	ScreenEffectsController draws the vignette when it becomes true — the same
	boolean the server is enforcing punch damage with, so none of the four can
	disagree about when a player is exhausted or when they have recovered.
]]
function StaminaController.isExhausted(): boolean
	return exhausted
end

--[[
	Registers a listener called on every update from the server.

	Listeners are never removed. Both of them (the bar and the parry) live for
	the whole session, and a remove that nothing calls is a leak waiting to look
	like a feature.
]]
function StaminaController.onChanged(listener: (StaminaState.StaminaState) -> ())
	table.insert(listeners, listener)
end

function StaminaController.Start()
	-- Yields until the remote replicates, which is why this is Start and not
	-- Init.
	local staminaChanged = Net.getEvent("StaminaChanged")

	-- Typed loosely at the boundary and narrowed by the handler's own signature,
	-- the same shape the server's handlers use. Nothing is validated here: the
	-- server is the only thing that can fire this, and it is the side that owns
	-- the number in the first place.
	staminaChanged.OnClientEvent:Connect(function(current: any, max: any, isExhausted: any)
		onStaminaChanged(current, max, isExhausted)
	end)

	log.info("listening for stamina updates")
end

return StaminaController
