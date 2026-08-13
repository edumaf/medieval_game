--!strict
--[[
	Config — tunable values that both the server and the client read.

	Rules:
	  * Values here are constants, not state. The table is frozen; nothing may
	    write to it at runtime.
	  * Anything the client must not know (drop tables, exploit thresholds,
	    economy rates) does NOT belong here — ReplicatedStorage is visible to
	    every client. Put those in a server-only module.
]]

export type LogLevel = "debug" | "info" | "warn"

local Config = {
	--[[
		Bumped by hand on every release. The client sends this to the server
		during the handshake so we can spot players on a stale client build.
	]]
	GameVersion = "0.1.0",

	--[[
		Lowest level that Util/Logger will print. Set to "debug" while working
		on a system; leave it at "info" on main.
	]]
	LogLevel = "info" :: LogLevel,

	--[[
		Humanoid.WalkSpeed while walking normally and while sprinting (Left
		Shift held). See src/client/Controllers/RunningController.
	]]
	NormalWalkSpeed = 16,
	SprintWalkSpeed = 24,

	--[[
		Health (and max health) every character starts at and is restored to on
		respawn. See src/server/Services/HealthService.
	]]
	NormalHealth = 100,
}

return table.freeze(Config)
