--!strict
--[[
	Net — the only place remotes are created and looked up.

	Why this exists rather than `Instance.new("RemoteEvent")` scattered around:

	  * Every remote is declared in one file (Remotes.luau), so the whole
	    client/server surface is reviewable at a glance.
	  * The server creates them all before any service runs, so there is no race
	    where a client invokes a remote that does not exist yet.
	  * Misspelling a remote name is a type error instead of a nil index.

	Server:  Net.build() once at boot, then Net.getFunction("Handshake").
	Client:  Net.getFunction("Handshake") — waits for replication.

	SECURITY: this module only resolves instances. It does not validate
	anything. Every server-side handler must validate its own arguments; see
	src/server/Services/SessionService.luau for the pattern.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(script.Remotes)

export type RemoteName = Remotes.RemoteName
export type RemoteClass = Remotes.RemoteClass

local FOLDER_NAME = "Remotes"
local REPLICATION_TIMEOUT_SECONDS = 15

local Net = {}

local function serverFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function remotesFolder(): Folder
	if RunService:IsServer() then
		return serverFolder()
	end

	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, REPLICATION_TIMEOUT_SECONDS)
	assert(
		folder and folder:IsA("Folder"),
		`Net: ReplicatedStorage.{FOLDER_NAME} did not replicate within {REPLICATION_TIMEOUT_SECONDS}s. `
			.. `The server either failed to boot or never called Net.build().`
	)
	return folder
end

local function resolve(name: string, expected: RemoteClass): Instance
	local declared = Remotes.Definitions[name]
	assert(declared ~= nil, `Net: "{name}" is not declared in Shared/Net/Remotes.luau`)
	assert(
		declared == expected,
		`Net: "{name}" is declared as a {declared}, but was asked for as a {expected}`
	)

	local folder = remotesFolder()
	local remote = if RunService:IsServer()
		then folder:FindFirstChild(name)
		else folder:WaitForChild(name, REPLICATION_TIMEOUT_SECONDS)

	assert(remote, `Net: remote "{name}" does not exist. Did the server call Net.build()?`)
	return remote
end

--[[
	Creates every declared remote. Server only, once, before services start.
	Safe to call twice; existing remotes are left alone.
]]
function Net.build()
	assert(RunService:IsServer(), "Net.build() may only be called from the server")

	local folder = serverFolder()
	for name, className in Remotes.Definitions do
		if folder:FindFirstChild(name) == nil then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = folder
		end
	end
end

--[[
	Returns a declared RemoteEvent. On the client this yields until the remote
	replicates, and throws if it never does.
]]
function Net.getEvent(name: RemoteName): RemoteEvent
	return resolve(name, "RemoteEvent") :: RemoteEvent
end

--[[
	Returns a declared RemoteFunction. On the client this yields until the
	remote replicates, and throws if it never does.
]]
function Net.getFunction(name: RemoteName): RemoteFunction
	return resolve(name, "RemoteFunction") :: RemoteFunction
end

return Net
