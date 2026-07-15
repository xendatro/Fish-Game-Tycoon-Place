--written by hythe55
local ReplicationService = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Signal = require(ReplicatedStorage.Classes.Signal)
local Table = require(ReplicatedStorage.Classes.Table)

local Replicators = {
	_ALL = {}
}:: {[RemoteEvent]: {}}

ReplicationService.ReplicationCreated = Signal.new()

local function checkRunContext(isServer: boolean)
	assert(RunService:IsServer() == isServer, "Method cannot be called from this RunContext")
end

local Replicator = {}
Replicator.__index = Replicator

--[[
Create an internal Replication object
]]
function Replicator.new(remoteEvent: RemoteEvent, callback: (data: Table.Table) -> ())
	local self = setmetatable({}, Replicator)

	self._connection = nil
	self._callback = callback
	self._remoteEvent = remoteEvent
	self._complete = false
	self._destroyed = false

	self._connection = remoteEvent.OnClientEvent:Connect(function(data)
		while not self._complete and not self._destroyed do
			task.wait(0.05)
		end
		if self._destroyed then return end
		data = Table.new(data)
		self._callback(data)
	end)

	task.defer(function()
		local data = ReplicationService:RequestData(remoteEvent)
		if self._destroyed then return end
		data = Table.new(data)
		self._callback(data)
		self._complete = true
	end)

	return self
end

--[[
Unlistens and cleans up a listener.
]]
function Replicator:Unlisten()
	if self._destroyed then return end
	self._destroyed = true
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

--[[
Creates a new Replication and fires the RemoteEvent whenever changes to <strong>data</strong> are detected.

If player is not povided the Replication will be sent to all Players.
]]
function ReplicationService:Create(data: Table.Table, remoteEvent: RemoteEvent, player: Player?)
	checkRunContext(true)
	assert(remoteEvent:IsA("RemoteEvent"), "Argument 1 must be a RemoteEvent")
	local _p = player

	local player = player or "_ALL"
	if not Replicators[player] then
		Replicators[player] = {}
	end

	if _p then
		assert(not Replicators[player][remoteEvent], "ReplicationService is already using ".. remoteEvent.Name.. " for ".. player.Name)
	else
		assert(not Replicators[player][remoteEvent], "ReplicationService is already using ".. remoteEvent.Name.. " for all players")
	end

	Replicators[player][remoteEvent] = {}
	local replicator = Replicators[player][remoteEvent]
	replicator.Data = data:Serialize()
	replicator.Player = player
	replicator.ChangedConnection = data.Changed:Connect(function()
		replicator.Data = data:Serialize()
		if player == "_ALL" then
			remoteEvent:FireAllClients(replicator.Data)
			return
		end
		remoteEvent:FireClient(player, replicator.Data)
	end)

	ReplicationService.ReplicationCreated:Fire(remoteEvent)
end

--[[
Removes the Replication tied to the RemoteEvent and player.
If no player is provided the Replication will be removed for all players.
]]
function ReplicationService:Clear(remoteEvent: RemoteEvent, player: Player?)
	checkRunContext(true)
	assert(remoteEvent:IsA("RemoteEvent"), "Argument 1 must be a RemoteEvent")

	player = player or "_ALL"
	if Replicators[player] then
		if Replicators[player].ChangedConnection then
			Replicators[player].ChangedConnection:Disconnect()
		end
		Replicators[player] = nil
	end
end

--[[
Creates a new listener for a Replication based on the given RemoteEvent.
Calls the provided function when initally called and for updates to <strong>data</strong>.
data.Changed will not fire on data recived from this method.
The f arguemnt takes a function with the data parameter.
]]
function ReplicationService:Listen(remoteEvent: RemoteEvent, callback: (data: Table.Table) -> ())
	--Remote events wipe metatables
	checkRunContext(false)
	assert(remoteEvent:IsA("RemoteEvent"), "Argument 1 must be a RemoteEvent")
	assert(typeof(callback) == "function", "Argument 2 must be a function")

	return Replicator.new(remoteEvent, callback)

	--[[local complete = false

	remoteEvent.OnClientEvent:Connect(function(data)
		while not complete do
			task.wait(0.05)
		end
		data = Table.new(data)
		f(data)
	end)
	task.defer(function()
		local data = ReplicationService:RequestData(remoteEvent)
		data = Table.new(data)
		f(data)
		complete = true
	end)]]
end

--[[
Requests the data associated with the RemoteEvent.
This method yields.
]]
function ReplicationService:RequestData(remoteEvent: RemoteEvent)
	checkRunContext(false)
	return Table.new(script.RequestData:InvokeServer(remoteEvent))
end

--Server only code
if RunService:IsServer() then
	local function requestData(player, remoteEvent: RemoteEvent)
		assert(typeof(remoteEvent == "Instance") or remoteEvent:IsA("RemoteEvent"))

		while true do
			if Replicators[player] and Replicators[player][remoteEvent] then
				return Replicators[player][remoteEvent].Data
			elseif Replicators._ALL[remoteEvent] then
				return Replicators._ALL[remoteEvent].Data
			end
			ReplicationService.ReplicationCreated:Wait()
		end
	end

	script.RequestData.OnServerInvoke = function(player, remoteEvent: RemoteEvent)
		local data = requestData(player, remoteEvent)
		return data
	end

	Players.PlayerRemoving:Connect(function(player)
		if Replicators[player] then
			if Replicators[player].ChangedConnection then
				Replicators[player].ChangedConnection:Disconnect()
			end
			Replicators[player] = nil
		end
	end)
end

return ReplicationService