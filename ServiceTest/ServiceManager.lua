require "ICCommLib"
require "ICComm"
require "GuildLib"
local MAJOR, MINOR = "Module:ServiceManager-Test", 1
local APkg = Apollo.GetPackage(MAJOR)
if APkg and (APkg.nVersion or 0) >= MINOR then
  return -- no upgrade needed
end
local ServiceManager = APkg and APkg.tPackage or {}
local _ENV = nil -- blocking globals in Lua 5.2
ServiceManager.null = setmetatable ({}, {
  __toinn = function () return "null" end
})

local kTimeout = 5
local kReservedChar = string.char(31) -- used to prevent trimming

local function pack(...)
	return arg
end

local function GetGuild(name)
	for _, guild in pairs(GuildLib.GetGuilds()) do
		if guild:GetName() == name then return guild end
	end

	return nil
end

function ServiceManager:OnLoad()
	self.owner = nil
	self.services = {}
end

function ServiceManager:RegisterService(callingAddon, serviceName, service)
	if self.owner == nil then
		self.owner = callingAddon
		callingAddon.ServiceManager_HandleRequest = function(owner, iccomm, strMessage, strSender)
			self:HandleRequest(iccomm, strMessage, strSender)
		end
		callingAddon.ServiceManager_HandleResponse = function(owner, iccomm, strMessage, strSender)
			self:HandleResponse(iccomm, strMessage, strSender)
		end
	elseif self.owner ~= callingAddon
		error("service package name must be unique per addon")
	end
	
	if self.services[serviceName] ~= nil then
		Print(serviceName .. " has already been registered!")
		return
	end
	
	self.services[serviceName] = service
	for rpcName, rpc in pairs(service.rpcs) do
		local requestChannelName = serviceName .. "_" .. rpcName .. "_Request"
		local responseChannelName = serviceName .. "_" .. rpcName .. "_Response"

		rpc.ConnectRequest = function(rpc)
			if not rpc.requestComm then
				rpc.requestComm = ICCommLib.JoinChannel(requestChannelName, service.channelType, GetGuild(service.guildName))
				if rpc.requestComm then
					rpc.requestComm:SetReceivedMessageFunction("ServiceManager_HandleRequest", callingAddon)
				end
			else
				rpc.requestConnectTimer:Stop()
			end
		end

		rpc.ConnectResponse = function(rpc)
			if not rpc.responseComm then
				rpc.responseComm = ICCommLib.JoinChannel(responseChannelName, service.channelType, GetGuild(service.guildName))
				if rpc.responseComm then
					rpc.responseComm:SetReceivedMessageFunction("ServiceManager_HandleResponse", callingAddon)
				end
			else
				rpc.responseConnectTimer:Stop()
			end
		end

		rpc.HandleTimeout = function(rpc)
			rpc.pendingCallFailer("Call timed out")
			rpc.pendingCallFailer = nil
			rpc.pendingCallHandler = nil
			rpc.pendingCallHost = nil
		end
		
		rpc.requestConnectTimer = ApolloTimer.Create(1, true, "ConnectRequest", rpc)
		if rpc.returns ~= nil then
			rpc.responseConnectTimer = ApolloTimer.Create(1, true, "ConnectResponse", rpc)
		end
	end
end

function ServiceManager:HandleRequest(iccomm, strMessage, strSender)
	local channel = iccomm:GetName()
	local firstSeparator = string.find(channel, "_")
	local secondSeparator = string.find(channel, "_", firstSeparator + 1)
	local serviceName = string.sub(channel, 1, firstSeparator - 1)
	local rpcName = string.sub(channel, firstSeparator + 1, secondSeparator - 1)
	local rpc = self.services[serviceName].rpcs[rpcName]
	if rpc.requestHandler == nil then return end
	
	if string.sub(strMessage, -1) == kReservedChar then
		strMessage = string.sub(strMessage, 1, -2)
	end

	local args = {}
	for i = 1, #rpc.args do
		args[i], strMessage = rpc.args[i]:Decode(strMessage, i == #rpc.args)
	end
	table.insert(args, 1, strSender)
	local results = pack(rpc.requestHandler(unpack(args)))

	if rpc.returns ~= nil then
		local resultstring = ""
		for i = 1, #rpc.returns do
			resultstring = rpc.returns[i]:Encode(results[i], resultstring, i==#rpc.returns)
		end
		if resultstring == "" or
		string.sub(resultstring, -1) == " " or
		string.sub(resultstring, -1) == kReservedChar then
			resultstring = resultstring .. kReservedChar
		end
		rpc.responseComm:SendPrivateMessage(strSender, resultstring)
	end
end

function ServiceManager:HandleResponse(iccomm, strMessage, strSender)
	local channel = iccomm:GetName()
	local firstSeparator = string.find(channel, "_")
	local secondSeparator = string.find(channel, "_", firstSeparator + 1)
	local serviceName = string.sub(channel, 1, firstSeparator - 1)
	local rpcName = string.sub(channel, firstSeparator + 1, secondSeparator - 1)
	local rpc = self.services[serviceName].rpcs[rpcName]
	if rpc.pendingCallHost and strSender ~= rpc.pendingCallHost then return end

	if string.sub(strMessage, -1) == kReservedChar then
		strMessage = string.sub(strMessage, 1, -2)
	end
	if rpc.pendingCallHandler == nil then return end
	local returns = {}
	for i = 1, #rpc.returns do
		returns[i], strMessage = rpc.returns[i]:Decode(strMessage, i == #rpc.returns)
	end
	rpc.pendingCallHandler(unpack(returns))
	rpc.pendingTimeoutTimer:Stop()
	rpc.pendingCallHandler = nil
	rpc.pendingCallFailer = nil
	rpc.pendingCallHost = nil
end

function ServiceManager:Implement(serviceName, rpcName, handler)
	local rpc = self.services[serviceName].rpcs[rpcName]
	rpc.requestHandler = handler
end

-- leave destination nil to broadcast
function ServiceManager:RemoteCall(destination, serviceName, rpcName, responseHandler, responseFailer, ...)
	local service = self.services[serviceName]
	local rpc = service.rpcs[rpcName]
	if rpc.pendingCallHandler ~= nil then
		responseFailer("Blocked by pending previous call")
		return
	end
	if rpc.returns ~= nil then
		rpc.pendingCallHandler = responseHandler
		rpc.pendingCallFailer = responseFailer
		rpc.pendingCallHost = destination
	end
	local argstring = ""
	for i = 1, #rpc.args do
		argstring = rpc.args[i]:Encode(arg[i], argstring, i==#rpc.args)
	end

	if argstring == "" or
	string.sub(argstring, -1) == " " or
	string.sub(argstring, -1) == kReservedChar then
		argstring = argstring .. kReservedChar
	end

	if destination then
		rpc.requestComm:SendPrivateMessage(destination, argstring)
	else
		rpc.requestComm:SendMessage(argstring)
	end
	
	if rpc.returns ~= nil then
		rpc.pendingTimeoutTimer = ApolloTimer.Create(kTimeout, false, "HandleTimeout", rpc)
	end
end

Apollo.RegisterPackage(ServiceManager, MAJOR, MINOR, {})