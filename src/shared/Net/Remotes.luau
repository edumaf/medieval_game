--!strict
--[[
	Remotes — the complete list of remotes this game has.

	Adding a remote is a two-line change here plus a handler on the server. Keep
	this list short: every entry is a hole in the client/server boundary that
	somebody has to validate.

	Naming: <Noun><Verb>, e.g. InventoryEquipRequest, QuestStateChanged.
]]

export type RemoteClass = "RemoteEvent" | "RemoteFunction"

--[[
	Union of every declared remote name. Net's accessors take this type, so a
	typo in a remote name is a type error, not a runtime nil.
]]
export type RemoteName =
	"Handshake"
	| "ParryStateRequest"
	| "PunchRequest"
	| "SprintStateRequest"
	| "StaminaChanged"

local Definitions: { [string]: RemoteClass } = {
	-- Client asks the server which build it is running, right after it boots.
	Handshake = "RemoteFunction",

	-- Client reports where its own parry has got to: "begin" when Q goes down,
	-- "hold" on the frame the parry animation's "Hold" marker fires, "end"
	-- when Q is released or the character goes away. Nothing else is sent —
	-- not the attacker, not a direction, not a damage number — because
	-- ParryService decides what the phase is worth from its own view of where
	-- both characters are standing. The one thing a modified client controls
	-- is when it claims to reach the guard, and the worst that buys is
	-- skipping the wind-up: the arc, the liveness and the damage stay
	-- server-side. Validated in ParryService, which accepts these three
	-- strings and nothing else.
	ParryStateRequest = "RemoteEvent",

	-- Client reports that the player's punch connected, on the frame the
	-- punch animation's "Hit" marker fires. Deliberately carries no
	-- arguments: the server decides who was hit, and for how much, from its
	-- own view of the world. There is nothing here for a modified client to
	-- forge except the timing, which CombatService rate-limits.
	PunchRequest = "RemoteEvent",

	-- Client reports whether the player is sprinting, as a single boolean, on
	-- the frame it changes and never otherwise. Nothing else is sent — no
	-- speed, no position, and above all no stamina number — because
	-- StaminaService drains the pool from its own clock and only needs to know
	-- which state the player is in. Validated in StaminaService, which accepts
	-- a boolean and nothing else.
	--
	-- "Sprinting" rather than "holding the key": a player whose pool has run
	-- empty is not sprinting even with Shift down, and reports false, which is
	-- what lets the server regenerate them. See SprintState.isSprinting.
	--
	-- This is the remote docs/decisions.md's sprinting section has been pointing
	-- at: the first system that cares whether a player is really sprinting has
	-- to track that intent server-side rather than reading a WalkSpeed the
	-- client owns. What it does and does not guarantee is written up there.
	SprintStateRequest = "RemoteEvent",

	-- Server tells one client what its own stamina is, as (current, max). Fired
	-- only when the pool has moved far enough to be worth a message, or has
	-- landed exactly on empty or full — never per frame, and never to anybody
	-- but the player it belongs to. See StaminaState.shouldReplicate.
	--
	-- Server -> client only. There is no client -> server direction here and
	-- there must not be one: stamina is server-owned, so a client has nothing
	-- to say about it.
	StaminaChanged = "RemoteEvent",
}

return {
	Definitions = table.freeze(Definitions),
}
