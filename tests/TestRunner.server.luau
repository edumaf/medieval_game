--!nocheck
--[[
	Runs the Jest suite when you press Play in Studio.

	Guarded on IsStudio so tests never execute in a live server, and so the
	Open Cloud CI workflow (which supplies its own entry script) does not run
	them twice.

	If you see "DevPackages is missing", run `wally install` and reconnect Rojo.

	NOTE: Jest needs the `FFlagEnableLoadModule` Studio flag. Setting it is a
	one-time per-machine step — see "Testing" in README.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local devPackages = ReplicatedStorage:FindFirstChild("DevPackages")
if devPackages == nil then
	warn("[Tests] DevPackages is missing. Run `wally install`, then reconnect Rojo.")
	return
end

local Jest = require(devPackages.Jest)

local root = script.Parent
local status, result = Jest.runCLI(root, { verbose = false, ci = false }, { root }):awaitStatus()

if status ~= "Resolved" then
	error(`[Tests] the Jest run itself failed: {result}`)
end

if result.results.numFailedTests > 0 or result.results.numFailedTestSuites > 0 then
	error(
		`[Tests] {result.results.numFailedTests} failing test(s) in `
			.. `{result.results.numFailedTestSuites} suite(s)`
	)
end

print(`[Tests] {result.results.numPassedTests} passed`)
