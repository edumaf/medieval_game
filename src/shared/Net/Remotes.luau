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
export type RemoteName = "Handshake" | "PunchRequest"

local Definitions: { [string]: RemoteClass } = {
	-- Client asks the server which build it is running, right after it boots.
	Handshake = "RemoteFunction",

	-- Client reports that the player threw a punch. Deliberately carries no
	-- arguments: the server decides who was hit, and for how much, from its
	-- own view of the world. There is nothing here for a modified client to
	-- forge except the timing, which CombatService rate-limits.
	PunchRequest = "RemoteEvent",
}

return {
	Definitions = table.freeze(Definitions),
}
