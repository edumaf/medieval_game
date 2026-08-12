--!nocheck
--[[
	Entry point uploaded to the Open Cloud Luau Execution API by
	scripts/open-cloud-tests.luau.

	This runs INSIDE a Roblox server, not in Lune, so it uses Roblox globals.
	It is kept as a real file rather than an inline string so that StyLua and
	Selene check it like any other source.

	Its return value is what the CI script reads to decide pass or fail.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Jest = require(ReplicatedStorage.DevPackages.Jest)

local root = ServerScriptService.Tests
local status, result = Jest.runCLI(root, { verbose = true, ci = true }, { root }):awaitStatus()

if status ~= "Resolved" then
	error(`Jest itself failed to run: {result}`)
end

return {
	passedTests = result.results.numPassedTests,
	failedTests = result.results.numFailedTests,
	failedSuites = result.results.numFailedTestSuites,
}
