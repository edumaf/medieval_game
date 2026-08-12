--!strict
--[[
	Downloads the Roblox API type definitions that luau-lsp needs.

	Run:  lune run scripts/fetch-global-types

	The version is read from rokit.toml so the definitions always match the
	pinned luau-lsp, rather than drifting against whatever is on main. The file
	is written to .tooling/ and gitignored: it is generated, ~800 KB, and would
	bury every review in noise if committed.

	Re-run this after bumping luau-lsp, and whenever your editor starts
	complaining about a Roblox API that definitely exists.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local OUTPUT_DIRECTORY = ".tooling"
local OUTPUT_PATH = `{OUTPUT_DIRECTORY}/globalTypes.d.luau`

local manifest = serde.decode("toml", fs.readFile("rokit.toml")) :: any
local spec = manifest.tools["luau-lsp"]

if type(spec) ~= "string" then
	stdio.write("rokit.toml does not declare luau-lsp\n")
	process.exit(1)
end

local version = string.match(spec, "@(.+)$")
if version == nil then
	stdio.write(`could not read a version out of "{spec}"\n`)
	process.exit(1)
end

local url =
	`https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/{version}/scripts/globalTypes.d.luau`
stdio.write(`Fetching Roblox API definitions for luau-lsp {version}...\n`)

local response = net.request(url)
if not response.ok then
	stdio.write(`Download failed: HTTP {response.statusCode} from {url}\n`)
	process.exit(1)
end

if not fs.isDir(OUTPUT_DIRECTORY) then
	fs.writeDir(OUTPUT_DIRECTORY)
end
fs.writeFile(OUTPUT_PATH, response.body)

stdio.write(`{stdio.color("green")}Wrote {OUTPUT_PATH}{stdio.color("reset")}\n`)
