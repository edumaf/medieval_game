--!strict
--[[
	Types — type definitions shared by the server and the client.

	Anything that crosses the client/server boundary, or that more than one
	system needs to agree on, belongs here. Types that only one module uses
	should stay in that module.

	This module intentionally returns an empty table: it exists for its exported
	types, which you reach through a normal require:

		local Types = require(ReplicatedStorage.Shared.Types)
		local session: Types.PlayerSession = ...
]]

--[[
	The lifecycle contract every service (server) and controller (client)
	follows. Both hooks are optional. See Runtime/Bootstrap.luau for the rules
	about what may happen in each.
]]
export type LifecycleModule = {
	Init: (() -> ())?,
	Start: (() -> ())?,
}

--[[
	Server-side record of a connected player. Server-authoritative: the client
	never sends or edits this.
]]
export type PlayerSession = {
	userId: number,
	joinedAtUnix: number,
}

--[[
	Payload the server returns from the Handshake RemoteFunction. Used to detect
	a client running a stale build against a newer server.
]]
export type HandshakeResponse = {
	gameVersion: string,
	serverTimeNow: number,
}

return {}
