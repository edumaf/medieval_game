--!strict
--[[
	Studio plugin: runs the real Jest suite from a toolbar button.

	Why this exists: Jest's per-test module isolation calls debug.loadmodule,
	which reads a ModuleScript's Source property. Roblox's Script Capabilities
	model gates that behind the PluginOrOpenCloud capability, which an ordinary
	Play-mode script never has -- see docs/testing.md. A Studio plugin does have
	it, which is why this exists instead of a script under ServerScriptService.

	This is not a second test system: it requires the same
	ServerScriptService.Tests and ReplicatedStorage.DevPackages.Jest that Rojo
	already syncs, and runs Jest.runCLI the same way the (removed) Play-mode
	runner did. It only runs the real, currently-synced project.

	This file is not part of default.project.json or build.project.json -- it
	is never synced into the game. Install it with
	`lune run scripts/install-test-plugin`, or see plugin/README.md to do it by
	hand. Re-run the installer after pulling a change to this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local function loadLogger(): { forScope: (string) -> any }?
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if shared == nil then
		return nil
	end

	local util = shared:FindFirstChild("Util")
	if util == nil then
		return nil
	end

	local loggerModule = util:FindFirstChild("Logger")
	if loggerModule == nil then
		return nil
	end

	local ok, Logger = pcall(require, loggerModule)
	if not ok then
		return nil
	end

	return Logger :: any
end

-- Falls back to plain print/warn if Shared has not replicated yet (Rojo not
-- connected), so the plugin can still explain what is wrong.
local Logger = loadLogger()
local log = if Logger then Logger.forScope("JestPlugin") else nil

local function report(message: string)
	if log then
		log.info(message)
	else
		print(`[JestPlugin] {message}`)
	end
end

local function reportProblem(message: string)
	if log then
		log.warn(message)
	else
		warn(`[JestPlugin] {message}`)
	end
end

local toolbar = plugin:CreateToolbar("Medieval Game Tests")
local button =
	toolbar:CreateButton("Run Tests", "Run the Jest unit test suite against the synced project", "")
button.ClickableWhenViewportHidden = true

local running = false

local function runTests()
	if running then
		return
	end
	running = true
	button:SetActive(true)

	-- Every path through this closure ends in an explicit `return nil` so its
	-- return arity is consistent -- pcall's success case mirrors the wrapped
	-- function's returns, and a bare `return` (0 values) alongside a value
	-- fails --!strict's tuple-arity check on `local ok, err = pcall(...)`.
	local ok, err = pcall(function(): nil
		if RunService:IsRunning() then
			reportProblem(
				"Stop Play mode before running tests. This plugin tests the Edit-mode"
					.. " project, not the live Play session, so results while playing would"
					.. " be misleading."
			)
			return nil
		end

		local devPackages = ReplicatedStorage:FindFirstChild("DevPackages")
		if devPackages == nil then
			reportProblem(
				"ReplicatedStorage.DevPackages is missing. Run `wally install`, then reconnect Rojo."
			)
			return nil
		end

		local jestModule = devPackages:FindFirstChild("Jest")
		if jestModule == nil then
			reportProblem("DevPackages.Jest is missing. Run `wally install`, then reconnect Rojo.")
			return nil
		end

		local testsRoot = ServerScriptService:FindFirstChild("Tests")
		if testsRoot == nil then
			reportProblem("ServerScriptService.Tests is missing. Is `rojo serve` connected?")
			return nil
		end

		local Jest = require(jestModule) :: any

		report("Running Jest...")
		local status, result = Jest.runCLI(
			testsRoot,
			{ verbose = false, ci = false },
			{ testsRoot }
		)
			:awaitStatus()

		if status ~= "Resolved" then
			reportProblem(`Jest itself failed to run: {result}`)
			return nil
		end

		local results = result.results
		local suiteLine =
			`Test Suites: {results.numPassedTestSuites} passed, {results.numTotalTestSuites} total`
		local testLine = `Tests: {results.numPassedTests} passed, {results.numTotalTests} total`

		if results.numFailedTests > 0 or results.numFailedTestSuites > 0 then
			reportProblem(suiteLine)
			reportProblem(testLine)
		else
			report(suiteLine)
			report(testLine)
		end

		return nil
	end)

	if not ok then
		reportProblem(`Test run crashed: {err}`)
	end

	button:SetActive(false)
	running = false
end

button.Click:Connect(runTests)
