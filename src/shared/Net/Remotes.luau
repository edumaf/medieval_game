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
export type RemoteName = "Handshake"

local Definitions: { [string]: RemoteClass } = {
	-- Client asks the server which build it is running, right after it boots.
	Handshake = "RemoteFunction",
}

return {
	Definitions = table.freeze(Definitions),
}
