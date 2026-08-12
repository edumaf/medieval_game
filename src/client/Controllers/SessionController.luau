--!strict
--[[
	SessionController — the client half of the boot handshake.

	Its only job is to confirm the client and the server agree on which build
	they are running. It is also the reference example for a controller: no
	authority over anything, just presentation and talking to the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local log = Logger.forScope("SessionController")

local SessionController = {}

-- Net.getFunction yields on the client, and InvokeServer yields, so this must
-- run in Start rather than Init.
function SessionController.Start()
	local handshake = Net.getFunction("Handshake")
	local response = handshake:InvokeServer(Config.GameVersion) :: Types.HandshakeResponse

	if response.gameVersion ~= Config.GameVersion then
		log.warn(
			`build mismatch: client {Config.GameVersion}, server {response.gameVersion}. `
				.. `Rejoin to pick up the current build.`
		)
	else
		log.info(`connected to server build {response.gameVersion}`)
	end
end

return SessionController
