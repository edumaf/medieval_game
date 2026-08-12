--!strict
--[[
	Repository consistency checks that no other tool performs.

	Run:  lune run scripts/validate-project

	Selene checks code, StyLua checks formatting, luau-lsp checks types, and
	`rojo build` checks that the project compiles. None of them notice a Rojo
	mapping pointing at a folder somebody renamed, or a toolchain entry quietly
	floating to "latest". That is what this covers.

	Exits non-zero on the first set of problems found, and prints every one.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local PROJECT_FILES = { "default.project.json", "build.project.json" }
local SOURCE_DIRECTORIES = { "src", "tests", "scripts" }

local problems: { string } = {}

local function fail(message: string)
	table.insert(problems, message)
end

--[[
	Walks a Rojo project tree and confirms every `$path` resolves. Paths written
	as `{ "optional": "..." }` are allowed to be missing — that is how we mount
	Wally output folders that only exist after `wally install`.
]]
local function checkProjectPaths(node: any, projectFile: string, trail: string)
	if type(node) ~= "table" then
		return
	end

	local path = node["$path"]
	if type(path) == "string" then
		if not fs.isFile(path) and not fs.isDir(path) then
			fail(`{projectFile}: {trail} maps to "{path}", which does not exist`)
		end
	elseif type(path) == "table" then
		if type(path.optional) ~= "string" then
			fail(`{projectFile}: {trail} has a $path table without an "optional" string`)
		end
	elseif path ~= nil then
		fail(`{projectFile}: {trail} has a $path that is neither a string nor an optional table`)
	end

	for key, value in node do
		if type(key) == "string" and string.sub(key, 1, 1) ~= "$" then
			checkProjectPaths(value, projectFile, `{trail}.{key}`)
		end
	end
end

local function checkProjectFiles()
	for _, projectFile in PROJECT_FILES do
		if not fs.isFile(projectFile) then
			fail(`{projectFile} is missing`)
			continue
		end

		local ok, decoded = pcall(serde.decode, "json" :: "json", fs.readFile(projectFile))
		if not ok then
			fail(`{projectFile} is not valid JSON: {decoded}`)
			continue
		end

		checkProjectPaths((decoded :: any).tree, projectFile, "tree")
	end
end

--[[
	Every tool must be pinned to an exact owner/repo@x.y.z. A floating version
	means two developers can silently run different compilers.
]]
local function checkToolchainIsPinned()
	if not fs.isFile("rokit.toml") then
		fail("rokit.toml is missing")
		return
	end

	local manifest = serde.decode("toml", fs.readFile("rokit.toml")) :: any
	local tools = manifest.tools

	if type(tools) ~= "table" or next(tools) == nil then
		fail("rokit.toml declares no tools")
		return
	end

	for name, spec in tools do
		if type(spec) ~= "string" then
			fail(`rokit.toml: tool "{name}" is not a version string`)
		elseif not string.match(spec, "^[%w%-%._]+/[%w%-%._]+@%d+%.%d+%.%d+$") then
			fail(`rokit.toml: tool "{name}" is "{spec}"; expected owner/repo@major.minor.patch`)
		end
	end
end

local function walk(directory: string, visit: (string) -> ())
	for _, entry in fs.readDir(directory) do
		local path = `{directory}/{entry}`
		if fs.isDir(path) then
			walk(path, visit)
		else
			visit(path)
		end
	end
end

--[[
	We standardise on the .luau extension. Mixed extensions break editor
	tooling and make grep results inconsistent.
]]
local function checkFileExtensions()
	for _, directory in SOURCE_DIRECTORIES do
		if not fs.isDir(directory) then
			continue
		end

		walk(directory, function(path)
			if string.match(path, "%.lua$") then
				fail(`{path} uses the .lua extension; rename it to .luau`)
			end
		end)
	end
end

local function checkWallyState()
	if not fs.isFile("wally.toml") then
		fail("wally.toml is missing")
		return
	end

	if not fs.isFile("wally.lock") then
		fail("wally.lock is missing. Run `wally install` and commit the lockfile.")
	end
end

checkProjectFiles()
checkToolchainIsPinned()
checkFileExtensions()
checkWallyState()

if #problems > 0 then
	stdio.write(`{stdio.color("red")}Project validation failed:{stdio.color("reset")}\n`)
	for _, problem in problems do
		stdio.write(`  - {problem}\n`)
	end
	process.exit(1)
end

stdio.write(`{stdio.color("green")}Project validation passed.{stdio.color("reset")}\n`)
