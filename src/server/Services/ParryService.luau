--!strict
--[[
	ParryService — the server's authoritative record of who is guarding.

	The client owns the parry's *presentation*: the key, the animation, and the
	Hold marker that says the guard is up. It does not own any of the
	consequences. This service keeps the phase, and CombatService asks it two
	questions — "can this player punch?" and "does this defender's guard cover
	the direction this punch came from?" — both answered here, from server state
	and server-side character positions.

	What the server actually guarantees, and what it does not, is written out in
	docs/decisions.md. In short: the protected phase and the direction are
	decided here; the movement slowdown is not, because WalkSpeed is still
	client-authoritative. A modified client can therefore skip the wind-up,
	guard without playing the animation, guard at full speed, and hold a guard
	for as long as it likes by never sending "end". It cannot widen the arc,
	guard from the rear, or punch while the server has it engaged.

	A guard lasts until the client says it is over, or until a lifecycle event
	ends it. There is deliberately no maximum duration: holding Q is meant to
	keep guarding for as long as the player holds it, and any ceiling that
	bounded a modified client would cut an honest one off mid-guard as well.

	Every transition that arrives with a legal shape is applied. There is no
	rate limiter on the phase, deliberately: dropping a valid transition would
	leave the client believing it is protected while this table says otherwise,
	and a silent one-sided loss of protection is far worse than the spam it
	would prevent. The state machine already makes repeats idempotent.

	Follows the CombatService pattern: state in a module-local table keyed by
	Player, Init() registers the remote handler before any client can reach it,
	and per-player state is released on PlayerRemoving.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ParryState = require(Shared.Combat.ParryState)

local states: { [Player]: ParryState.ParryState } = {}

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
	--
	-- Dropped silently, with no warn. The payload is entirely attacker
	-- controlled, so a line per rejected message is a way to flood the output
	-- on demand — the same reasoning CombatService gives for not logging a
	-- punch that arrives inside its cooldown.
	if not ParryState.isTransition(transition) then
		return
	end

	-- Illegal orderings are no-ops inside the state machine rather than special
	-- cases here, so this handler never has to reason about what came before —
	-- and every legal transition is applied, always.
	local requested = transition :: ParryState.Transition
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
	Whether `defender` is holding a live guard that covers the direction an
	attack from `attackerPosition` arrives from.

	A thin wrapper, on purpose: it reads the two things only the engine can tell
	it — where the defender is and which way they are facing — and hands them to
	ParryState, which owns the arithmetic and is unit-tested. Nothing is decided
	here.

	The caller passes the root part it has already resolved, so there is one
	character lookup per punch and no second copy of CombatService's rootPartOf.

	The direction is taken from live positions and is deliberately not
	lag-compensated: PunchRules corrects distance only, and the cone it judges is
	likewise live. A guard that widened itself according to how fast somebody was
	running would be a different feature.
]]
function ParryService.isProtectedFrom(
	defender: Player,
	defenderRoot: BasePart,
	attackerPosition: Vector3
): boolean
	local rootCFrame = defenderRoot.CFrame
	local attackerDot =
		ParryState.attackerDot(rootCFrame.LookVector, rootCFrame.Position, attackerPosition)

	return ParryState.isProtectedFrom(stateOf(defender), attackerDot, Config.ParryMinFacingDot)
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
	pressed Q for the new character.

	Note this is about character replacement, not death: a player who is dead but
	whose character is still around keeps their record until it is swapped out.
	Nothing can reach it in the meantime, because CombatService filters dead
	players out of target selection before it ever asks about a guard — the
	liveness guarantee lives there, not here.

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
		-- Without this, every player who has ever parried stays in the table for
		-- the lifetime of the server.
		states[player] = nil
	end)

	-- A player can already be here before this service starts.
	for _, player in Players:GetPlayers() do
		attachPlayer(player)
	end
end

return ParryService
