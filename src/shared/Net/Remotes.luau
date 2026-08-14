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
export type RemoteName = "Handshake" | "ParryStateRequest" | "PunchRequest"

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
}

return {
	Definitions = table.freeze(Definitions),
}
