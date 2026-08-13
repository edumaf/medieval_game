--!strict
--[[
	DeveloperAccess — who is allowed to run developer/test commands.

	This module is server-only on purpose and must never move to src/shared.
	The list below is the whole security boundary for the test commands; a
	client that could read it would know exactly who to impersonate, and a
	client that could write it would grant itself the commands.

	It is deliberately not a lifecycle module — it lives beside Services/
	rather than inside it, so Bootstrap does not try to start it.

	Why this exists instead of a plain RunService:IsStudio() check:

	  * Solo Play and Test > Clients and Servers report IsStudio() == true on
	    the server, so those need no configuration.
	  * Team Test runs the place on a real Roblox server. IsStudio() is false
	    there on the server (though true on the clients), which is why the
	    chat commands silently stopped working the moment we started testing
	    together.

	There is no reliable engine-level way to detect a Team Test server — the
	usual PrivateServerId/PrivateServerOwnerId trick also matches reserved
	servers — so we authorise people rather than environments.
]]

local RunService = game:GetService("RunService")

--[[
	Roblox UserIds allowed to run developer commands on a real server.

	ACTION REQUIRED: add your own UserId here before Team Test will accept
	your commands. Find it in your Roblox profile URL:
	roblox.com/users/<UserId>/profile

	Keep this list short and remove people when they leave the project.
]]
local DEVELOPER_USER_IDS: { [number]: true } = {
	[11399930306] = true, -- eduard (edutzu_gagicutzu)
	[7836424153] = true, -- vlad (filipvlad2)
}

local DeveloperAccess = {}

--[[
	Whether a UserId is on the developer list. Takes a plain number rather
	than a Player so it can be unit tested without a live Player instance.
]]
function DeveloperAccess.isDeveloperUserId(userId: number): boolean
	return DEVELOPER_USER_IDS[userId] == true
end

--[[
	Whether `player` may use the in-chat test commands (/damage, /heal).

	SECURITY: on a published live server this returns true for listed
	developers. That is deliberate — being able to reproduce a bug on the
	real game is worth more than the risk, and the commands only affect the
	caller's own character. If that trade stops being acceptable, tighten
	this function rather than its callers.
]]
function DeveloperAccess.canUseTestCommands(player: Player): boolean
	-- Local Studio testing needs no configuration at all.
	if RunService:IsStudio() then
		return true
	end

	return DeveloperAccess.isDeveloperUserId(player.UserId)
end

return DeveloperAccess
