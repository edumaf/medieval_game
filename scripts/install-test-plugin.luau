--!strict
--[[
	Copies the Jest Studio plugin (plugin/JestRunner.luau) into your local
	Roblox Plugins folder so Studio loads it as a standalone plugin script.

	Run:  lune run scripts/install-test-plugin

	One-time per machine, same idea as `rojo plugin install` for the Rojo
	plugin itself. Re-run it after pulling a change to
	plugin/JestRunner.luau -- this copies the file, it does not link it.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local SOURCE = "plugin/JestRunner.luau"
local INSTALLED_NAME = "MedievalGameTests.lua"

local function abort(message: string): never
	stdio.write(`{stdio.color("red")}{message}{stdio.color("reset")}\n`)
	return process.exit(1)
end

--[[
	Standalone plugin scripts must use the .lua extension for Studio to
	auto-load them from the Plugins folder; the repository keeps .luau as its
	one true extension (see scripts/validate-project.luau), so the rename
	happens only in the copy this script writes, never in Git.
]]
local function pluginsFolder(): string
	if process.os == "windows" then
		local localAppData = process.env["LOCALAPPDATA"]
		if localAppData == nil or localAppData == "" then
			abort("LOCALAPPDATA is not set. Could not locate the Roblox Plugins folder.")
		end
		return `{localAppData}/Roblox/Plugins`
	elseif process.os == "macos" then
		local home = process.env["HOME"]
		if home == nil or home == "" then
			abort("HOME is not set. Could not locate the Roblox Plugins folder.")
		end
		return `{home}/Documents/Roblox/Plugins`
	else
		return abort(
			`Roblox Studio does not run on {process.os}. Install the plugin on a machine `
				.. "running Studio -- see plugin/README.md for the manual steps."
		)
	end
end

if not fs.isFile(SOURCE) then
	abort(`{SOURCE} is missing. Run this from the repository root.`)
end

local destinationFolder = pluginsFolder()
if not fs.isDir(destinationFolder) then
	fs.writeDir(destinationFolder)
end

local destination = `{destinationFolder}/{INSTALLED_NAME}`
fs.writeFile(destination, fs.readFile(SOURCE))

stdio.write(
	`{stdio.color("green")}Installed the test plugin to {destination}{stdio.color("reset")}\n`
)
stdio.write("Restart Roblox Studio (or reopen it) to load it.\n")
