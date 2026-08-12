--!strict
--[[
	SessionService — the server's authoritative record of who is in this server.

	This is deliberately small. It exists to establish the shape every future
	service follows:

	  * State lives in module-local variables, never in _G or shared.
	  * Init() registers handlers; Start() connects to events and catches up.
	  * Every value that arrives from a client is checked before it is used.
	  * Everything allocated per player is released in closeSession().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local log = Logger.forScope("SessionService")

local sessions: { [Player]: Types.PlayerSession } = {}

local SessionService = {}

local function openSession(player: Player)
	sessions[player] = {
		userId = player.UserId,
		joinedAtUnix = os.time(),
	}
	log.info(`session opened for {player.Name} ({player.UserId})`)
end

local function closeSession(player: Player)
	-- Clearing this entry is what stops `sessions` growing for the lifetime of
	-- the server. Any future per-player state must be released here too.
	sessions[player] = nil
	log.debug(`session closed for {player.Name}`)
end

--[[
	Returns the session for a player, or nil if they have already left.

	Callers must handle nil: a player can disconnect between any two lines of
	your code.
]]
function SessionService.getSession(player: Player): Types.PlayerSession?
	return sessions[player]
end

function SessionService.Init()
	local handshake = Net.getFunction("Handshake")

	handshake.OnServerInvoke = function(player: Player, clientVersion: any)
		-- Anything a client sends is untrusted, including its type. Check the
		-- shape before touching the value.
		if type(clientVersion) ~= "string" then
			log.warn(`{player.Name} sent a malformed handshake; ignoring the payload`)
		elseif clientVersion ~= Config.GameVersion then
			log.warn(
				`{player.Name} is on client build {clientVersion}, server is {Config.GameVersion}`
			)
		end

		local response: Types.HandshakeResponse = {
			gameVersion = Config.GameVersion,
			serverTimeNow = Workspace:GetServerTimeNow(),
		}
		return response
	end
end

function SessionService.Start()
	Players.PlayerAdded:Connect(openSession)
	Players.PlayerRemoving:Connect(closeSession)

	-- A player can join before this service starts. Catch anyone already here.
	for _, player in Players:GetPlayers() do
		if sessions[player] == nil then
			openSession(player)
		end
	end
end

return SessionService
