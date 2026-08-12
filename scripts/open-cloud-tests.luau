--!strict
--[[
	Runs the Jest suite inside a real Roblox server, headlessly, via the Open
	Cloud Luau Execution API.

	Run:  lune run scripts/open-cloud-tests

	Required environment:
	  ROBLOX_OPEN_CLOUD_KEY   API key with universe-places:write and
	                          universe.place.luau-execution-session:write
	  ROBLOX_UNIVERSE_ID      Universe containing the test place
	  ROBLOX_TEST_PLACE_ID    A place used ONLY for tests, never the live one

	What it does:
	  1. Uploads build/test-place.rbxl as a *saved* (not published) version, so
	     nothing reaches live players.
	  2. Starts a Luau execution task running scripts/roblox/run-tests-entry.luau
	     against that exact version.
	  3. Polls until the task finishes, prints the session log, and exits
	     non-zero if any test failed.

	See docs/testing.md for how to create the key and the test place.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local PLACE_FILE = "build/test-place.rbxl"
local ENTRY_SCRIPT = "scripts/roblox/run-tests-entry.luau"
local POLL_INTERVAL_SECONDS = 5
local POLL_TIMEOUT_SECONDS = 600
local EXECUTION_TIMEOUT = "300s"

local function abort(message: string): never
	stdio.write(`{stdio.color("red")}{message}{stdio.color("reset")}\n`)
	return process.exit(1)
end

local function requireEnv(name: string): string
	local value = process.env[name]
	if value == nil or value == "" then
		abort(`{name} is not set. See docs/testing.md.`)
	end
	return value :: string
end

local apiKey = requireEnv("ROBLOX_OPEN_CLOUD_KEY")
local universeId = requireEnv("ROBLOX_UNIVERSE_ID")
local placeId = requireEnv("ROBLOX_TEST_PLACE_ID")

if not fs.isFile(PLACE_FILE) then
	abort(`{PLACE_FILE} is missing. Run: rojo build default.project.json --output {PLACE_FILE}`)
end

-- 1. Upload the built place as a saved version. ------------------------------

stdio.write(`Uploading {PLACE_FILE} to place {placeId}...\n`)

local uploadResponse = net.request({
	url = `https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Saved`,
	method = "POST",
	headers = {
		["x-api-key"] = apiKey,
		["Content-Type"] = "application/octet-stream",
	},
	body = fs.readFile(PLACE_FILE),
})

if not uploadResponse.ok then
	abort(`Upload failed: HTTP {uploadResponse.statusCode}\n{uploadResponse.body}`)
end

local versionNumber = (serde.decode("json", uploadResponse.body) :: any).versionNumber
stdio.write(`Uploaded as version {versionNumber}.\n`)

-- 2. Start the Luau execution task against that version. ---------------------

local taskResponse = net.request({
	url = `https://apis.roblox.com/cloud/v2/universes/{universeId}/places/{placeId}`
		.. `/versions/{versionNumber}/luau-execution-session-tasks`,
	method = "POST",
	headers = {
		["x-api-key"] = apiKey,
		["Content-Type"] = "application/json",
	},
	body = serde.encode("json", {
		script = fs.readFile(ENTRY_SCRIPT),
		timeout = EXECUTION_TIMEOUT,
	}),
})

if not taskResponse.ok then
	abort(`Could not start the execution task: HTTP {taskResponse.statusCode}\n{taskResponse.body}`)
end

local createdTask = serde.decode("json", taskResponse.body) :: any
local taskUrl = `https://apis.roblox.com/cloud/v2/{createdTask.path}`
stdio.write(`Execution task started. Waiting for results...\n`)

-- 3. Poll until the task settles. --------------------------------------------

local function getTask(): any
	local response = net.request({
		url = taskUrl,
		method = "GET",
		headers = { ["x-api-key"] = apiKey },
	})

	if not response.ok then
		abort(`Polling failed: HTTP {response.statusCode}\n{response.body}`)
	end

	return serde.decode("json", response.body)
end

local waited = 0
local finalTask = getTask()

while finalTask.state == "PROCESSING" do
	if waited >= POLL_TIMEOUT_SECONDS then
		abort(`Timed out after {POLL_TIMEOUT_SECONDS}s waiting for the execution task.`)
	end

	task.wait(POLL_INTERVAL_SECONDS)
	waited += POLL_INTERVAL_SECONDS
	finalTask = getTask()
end

-- 4. Print whatever the session logged, then report. -------------------------

local logsResponse = net.request({
	url = `{taskUrl}/logs?view=FLAT`,
	method = "GET",
	headers = { ["x-api-key"] = apiKey },
})

if logsResponse.ok then
	local logs = serde.decode("json", logsResponse.body) :: any
	stdio.write("\n--- Roblox session output ---\n")
	for _, entry in logs.luauExecutionSessionTaskLogs or {} do
		for _, message in entry.messages or {} do
			stdio.write(`{message}\n`)
		end
	end
	stdio.write("--- end of session output ---\n\n")
end

if finalTask.state ~= "COMPLETE" then
	abort(
		`Execution task ended in state {finalTask.state}: {serde.encode("json", finalTask.error)}`
	)
end

-- Roblox's own reference implementation (Open Cloud execution binary payloads
-- example) reads this array as `output.results`, not `output.returnValues`.
local results = (finalTask.output or {}).results
local summary = if results then results[1] else nil

if summary == nil then
	abort("The entry script returned nothing. Check the session output above.")
end

if summary.failedTests > 0 or summary.failedSuites > 0 then
	abort(`{summary.failedTests} failing test(s) in {summary.failedSuites} suite(s).`)
end

stdio.write(`{stdio.color("green")}{summary.passedTests} test(s) passed.{stdio.color("reset")}\n`)
