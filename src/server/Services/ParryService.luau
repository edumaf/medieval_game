--!strict
--[[
	ParryService — the server's authoritative record of who is guarding.

	The client owns the parry's *presentation*: the key, the animation, and the
	Hold marker that says the guard is up. It does not own any of the
	consequences. This service keeps the phase, and CombatService asks it two
	questions — "can this player punch?" and "does this defender's guard cover
	the direction this punch came from?" — both answered here, from server state
	and server-side character positions.

	What a modified client can do is send the three transitions early or out of
	order. That buys it one thing: skipping the wind-up. It cannot widen the
	arc, because the direction is recomputed here from both root parts; it
	cannot guard while dead or after respawning, because a character being
	replaced clears the record; and it cannot claim protection it did not ask
	for, because "hold" with no attempt behind it is a no-op inside ParryState.
	There is deliberately no server-side timing floor on the wind-up — see
	docs/decisions.md.

	Follows the CombatService pattern: state in module-local tables keyed by
	Player, Init() registers the remote handler before any client can reach it,
	and per-player state is released on PlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local ParryState = require(Shared.Combat.ParryState)
local PunchRules = require(Shared.Combat.PunchRules)

local log = Logger.forScope("ParryService")

local states: { [Player]: ParryState.ParryState } = {}
local lastAttemptAt: { [Player]: number } = {}

local ParryService = {}

--[[
	The player's phase. A player with no entry has never parried (or has just
	had their record cleared), which is idle by any other name — returning a
	fresh state rather than nil keeps every caller free of a nil check.
]]
local function stateOf(player: Player): ParryState.ParryState
	return states[player] or ParryState.initial()
end

local function onParryStateRequest(player: Player, transition: any)
	-- Anything a client sends is untrusted, including its type. For this remote
	-- the type check and the range check are the same check: there are exactly
	-- three legal values and everything else is dropped.
	if not ParryState.isTransition(transition) then
		log.warn(`{player.Name} sent a malformed parry transition; ignoring it`)
		return
	end
	local requested = transition :: ParryState.Transition

	-- Rate-limited on "begin" alone. "hold" and "end" are idempotent and can
	-- never grant anything a "begin" has not already granted, and dropping an
	-- "end" is the one failure that would leave somebody protected after they
	-- let go — so a release is always accepted, however fast it arrives.
	--
	-- PunchRules.canPunch is reused rather than copied: it is exactly this
	-- predicate ("has enough time passed, given a possibly-nil last time and a
	-- clock that may have gone backwards"), and a second hand-written copy of
	-- it is the kind of duplication that drifts. Only the constant differs.
	if requested == "begin" then
		local now = os.clock()
		if not PunchRules.canPunch(lastAttemptAt[player], now, Config.ParryMinAttemptSeconds) then
			return
		end
		lastAttemptAt[player] = now
	end

	-- Illegal orderings are no-ops inside the state machine rather than special
	-- cases here, so this handler never has to reason about what came before.
	states[player] = ParryState.apply(stateOf(player), requested)
end

--[[
	Whether `player` is in a parry at all — winding up or holding the guard.

	CombatService uses this to refuse a punch thrown out of a guard. It covers
	the wind-up as well as the held guard on purpose: the attempt is what costs
	the player their swing, so cancelling before Hold is not a way to punch for
	free.
]]
function ParryService.isEngaged(player: Player): boolean
	return ParryState.isEngaged(stateOf(player))
end

--[[
	Whether `defender` is holding a guard that covers the direction an attack
	from `attackerPosition` arrives from.

	The caller passes the root part it has already resolved rather than this
	service looking it up again, so there is one character lookup per punch and
	no second copy of CombatService's rootPartOf.

	The direction is computed here, from the defender's own CFrame, and is
	deliberately not lag-compensated: PunchRules corrects distance only, and the
	cone it judges is likewise taken from live positions. A guard that widened
	itself according to how fast somebody was running would be a different
	feature.
]]
function ParryService.isProtectedFrom(
	defender: Player,
	defenderRoot: BasePart,
	attackerPosition: Vector3
): boolean
	local state = stateOf(defender)
	if not ParryState.isActive(state) then
		return false
	end

	local lookVector = defenderRoot.CFrame.LookVector
	local offset = attackerPosition - defenderRoot.Position
	-- Two characters occupying the same spot have no meaningful direction
	-- between them; treat that as dead ahead rather than normalising a zero
	-- vector, matching how CombatService handles the same degenerate case.
	local direction = if offset.Magnitude > 0 then offset.Unit else lookVector

	return ParryState.isProtectedFrom(state, lookVector:Dot(direction), Config.ParryMinFacingDot)
end

function ParryService.Init()
	-- Registered in Init so the handler exists before the first client can
	-- possibly reach the remote.
	local parryRequest = Net.getEvent("ParryStateRequest")

	-- Any arguments beyond the first are ignored by not being accepted in the
	-- first place.
	parryRequest.OnServerEvent:Connect(function(player: Player, transition: any)
		onParryStateRequest(player, transition)
	end)
end

--[[
	A character being replaced ends whatever guard it was holding. Without this
	a player who died mid-parry would respawn still protected, having never
	pressed Q for the new character — the exact stale state that would turn a
	dropped "end" into permanent front-immunity.

	Player.CharacterRemoving is an event on the Player instance, which Roblox
	disconnects when they leave, so — unlike a per-character Humanoid connection
	— it never needs an explicit disconnect.
]]
local function attachPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		states[player] = nil
	end)
end

function ParryService.Start()
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Without this, every player who has ever parried stays in both tables
		-- for the lifetime of the server.
		states[player] = nil
		lastAttemptAt[player] = nil
	end)

	-- A player can already be here before this service starts.
	for _, player in Players:GetPlayers() do
		attachPlayer(player)
	end
end

return ParryService
