--!strict
--[[
	Logger — scoped, level-filtered output.

	Use this instead of bare `print`. Every line is prefixed with the system that
	produced it, so the Output window stays readable once several systems are
	running, and noisy debug lines can be switched off in one place.

		local log = Logger.forScope("InventoryService")
		log.info("loaded 3 items")   --> [InventoryService] loaded 3 items
]]

local Config = require(script.Parent.Parent.Config)

export type Level = "debug" | "info" | "warn"

export type Logger = {
	debug: (message: string) -> (),
	info: (message: string) -> (),
	warn: (message: string) -> (),
}

local RANK: { [string]: number } = {
	debug = 10,
	info = 20,
	warn = 30,
}

local Logger = {}

--[[
	Creates a logger tagged with `scopeName`. Call this once per module, at the
	top, and reuse the returned table.
]]
function Logger.forScope(scopeName: string): Logger
	local prefix = `[{scopeName}]`
	local threshold = RANK[Config.LogLevel] or RANK.info

	local function emit(level: Level, message: string)
		if RANK[level] < threshold then
			return
		end

		if level == "warn" then
			warn(`{prefix} {message}`)
		else
			print(`{prefix} {message}`)
		end
	end

	return {
		debug = function(message: string)
			emit("debug", message)
		end,
		info = function(message: string)
			emit("info", message)
		end,
		warn = function(message: string)
			emit("warn", message)
		end,
	}
end

return Logger
