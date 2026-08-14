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
	Everything needed to build one Sound, as stored in Config and consumed by
	Shared/Util/Audio. Shared rather than client-side because the server builds
	one too: the punch impact is created server-side so both players hear it.

	`id` is an `rbxassetid://` string, or empty for "no sound uploaded yet" —
	the same convention Config.PunchAnimationId uses, and handled the same way.

	The two roll-off distances are always present, because Roblox's Sound always
	has them, but they only do anything for a sound parented to a BasePart. A
	Sound anywhere else — SoundService, a ScreenGui — plays flat at full volume
	wherever the listener is standing, and ignores both. That is what the
	damage, healing and punch-swing sounds rely on, and it is why their values
	here are inert rather than absent: a spec that is later re-parented onto a
	character should not have to grow two new fields to start behaving.
]]
export type SoundSpec = {
	id: string,
	volume: number,
	playbackSpeed: number,
	rollOffMinDistance: number,
	rollOffMaxDistance: number,
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
