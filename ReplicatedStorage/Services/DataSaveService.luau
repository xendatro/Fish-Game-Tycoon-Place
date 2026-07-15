local DEBUG = false --this will create a fresh testing profile that resets each time the playtest ends
local VERSION_ID = nil --{"TEST1_275186750", "08DE5803D6413EA5.0000000125.08DE5B487ADEED42.01"} --set this to load a specific data version

--SETTINGS
local ORDERED_DATA_UPDATE_INTERVAL = 60

local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local ReplicationService = require(ReplicatedStorage.Services.ReplicationService)
local DataSaveService = {}

if not RunService:IsStudio() then
	DEBUG = false
end

local Table = require(ReplicatedStorage.Classes.Table)

local IsServer = RunService:IsServer()

--assert(IsServer, "Client side is not currently supported")

if IsServer then
	assert(ServerStorage:FindFirstChild("Services"), "ProfileStore must be a child of ServerStorage.Services")
	assert(ServerStorage.Services:FindFirstChild("ProfileStore"), "ProfileStore must be a child of ServerStorage.Services")
	ProfileService = require(ServerStorage.Services.ProfileStore)
end

local ProfileTemplate: {}? = nil
local ProfileStore: ProfileService.ProfileStore? = nil
local ProfileName = "MAIN_PROFILE"
local ProfileKeyTemplate = "%s"
local Profiles: {[Player]: ProfileService.Profile} = {}
local ProfileTables: {[Player]: ProfileService.Profile} = {}

local leaderboardUpdaters: {[Player]: {() -> ()}} = {}

local localProfile: Profile = nil

script:SetAttribute("ProfileStoreCreated", false)

export type ProfileSignal = {
	Connect: (self: ProfileSignal, (player: Player) -> ()) -> RBXScriptConnection,
	Once: (self: ProfileSignal, (player: Player) -> ()) -> RBXScriptConnection,
	Wait: (self: ProfileSignal, (player: Player) -> ()) -> RBXScriptConnection,
	ConnectParallel: (self: ProfileSignal, (player: Player) -> ()) -> RBXScriptConnection
}

export type ProfileStore = ProfileService.ProfileStore
export type Profile = ProfileService.Profile

--Creates communication folder and remote events
local function startup()
	if not IsServer then return end
	local communication = Instance.new("Folder")
	communication.Name = "Communication"
	communication.Parent = script
	local profileAdded = Instance.new("BindableEvent")
	profileAdded.Name = "ProfileAdded"
	profileAdded.Parent = communication
	local profileRemoving = Instance.new("BindableEvent")
	profileRemoving.Name = "ProfileRemoving"
	profileRemoving.Parent = communication
	local profileRemoved = Instance.new("BindableEvent")
	profileRemoved.Name = "ProfileRemoved"
	profileRemoved.Parent = communication
	local requestProfile = Instance.new("RemoteEvent")
	requestProfile.Name = "SendProfileToClient"
	requestProfile.Parent = communication
end

--[[Waits for a profile to be loaded.
Returns nil if player leaves before the profile is loaded.]]
function DataSaveService:WaitForProfile(player: Player): Profile?
	if IsServer then
		assert("[DataSaveService]: Player parameter is required on the server")
		if not Players:FindFirstChild(player.Name) then
			return
		end
		while not DataSaveService:GetProfile(player) do
			task.wait(0.1) --disgusting but i can't think of another way to do this right now
			if not player.Parent then
				break
			end
		end
		return DataSaveService:GetProfile(player)
	else
		while not DataSaveService:GetProfile() do
			task.wait(0.1)
		end
		return DataSaveService:GetProfile()
	end
end

--[[Returns the profile key for the given userId.]]
function DataSaveService:GetProfileKey(userId: number): string
	assert(IsServer, "[DataSaveService]: can only be called from the server")
	return string.format(ProfileKeyTemplate, userId)
end

--[[Returns the profile store.
Yields until DataSaveService:CreateProfileStore() is called.]]
function DataSaveService:GetProfileStore(): ProfileService.ProfileStore
	assert(IsServer, "[DataSaveService]: GetProfileStore can only be called from the server")
	if script:GetAttribute("ProfileStoreCreated") == false then
		script:GetAttributeChangedSignal("ProfileStoreCreated"):Wait()
	end
	return ProfileStore
end

--[[Returns a dictionary of all profiles with <strong>player</strong> being used as the key.]]
function DataSaveService:GetProfiles(): {[Player]: Profile}
	assert(IsServer, "[DataSaveService]: GetProfiles can only be called from the server")
	return Profiles
end

--[[Returns the Profile for <strong>player</strong>
Returns nil if no Profile is found]]
function DataSaveService:GetProfile(player: Player): Profile?
	if IsServer then
		assert(player:IsA("Player"), "[DataSaveService:] Player parameter must be provided on the server")
		return ProfileTables[player]
		--return Profiles[player]
	else
		return localProfile
		--return ReplicationService:RequestData(script.SendProfileToClient)
		--return script.Communication.RequestProfile:InvokeServer()
		--[[script.Communication.RequestProfile.OnClientEvent:Once(function(profile: Profile)
			return profile
		end)]]
	end
end

--[[
Resets a profile to the template.
]]
function DataSaveService:ResetProfile(profile: Profile)
	assert(IsServer, "[DataSaveService]: ResetProfile can only be called from the server")
	profile.Data = DataSaveService:GetTemplate()
end

--[[Sets the template the Profile will use.]]
function DataSaveService:SetTemplate(template: {any})
	assert(IsServer, "[DataSaveService]: SetTemplate can only be called from the server")
	assert(typeof(template) == "table", "Template must be a table.")
	ProfileTemplate = template
end

--[[Returns the template Profiles use.]]
function DataSaveService:GetTemplate(): {any}
	assert(ProfileTemplate, "[DataSaveService]: Profile template has not been created")
	return ProfileTemplate
end

--[[Waits for the template to be loaded.]]
function DataSaveService:WaitForTemplate()
	while not ProfileTemplate do
		task.wait(0.1)
	end
end

--[[Binds an OrderedDataStore to a certain location in the template.
The index should be seperated by periods.
Example: Information.DataStore or Information.Data Store]]
--[[Binds an OrderedDataStore to a certain location in the template.]]
function DataSaveService:BindToOrderedDataStore(index: string, name: string, scope: string?)
	assert(IsServer, "[DataSaveService]: BindToOrderedDataStore must be called from the server")
	assert(ProfileTemplate, "[DataSaveService]: Profile template must be created before calling BindToOrderedDataStore")
	local orderedDataStore = DataStoreService:GetOrderedDataStore(name, scope)

	local function getData(profile: Profile)
		local currentLocation = profile.Data
		if not currentLocation then return end
		for i,v in string.split(index, ".") do
			if currentLocation[v] then
				currentLocation = currentLocation[v]
				continue
			end
		end
		return currentLocation
	end

	local function performUpdate(player: Player)
		if not player.Parent then return end

		local profile = DataSaveService:GetProfile(player)
		if not profile then return end

		local data = getData(profile)
		if not data or data == math.huge then return end

		local success, err
		local tries = 0
		repeat
			success, err = pcall(function()
				return orderedDataStore:SetAsync(tostring(player.UserId), tonumber(data))
			end)
			if not success then
				tries += 1
				task.wait(0.1)
				warn("[DataSaveService]: ".. err)
			end
		until success or tries == 10

		if tries == 10 then
			warn("[DataSaveService]: Failed to update OrderedDataStore ".. name.. " Error: ".. err)
		end
	end

	local function initLoop(player: Player)
		if not leaderboardUpdaters[player] then leaderboardUpdaters[player] = {} end
		table.insert(leaderboardUpdaters[player], function() performUpdate(player) end)

		while player.Parent do
			task.wait(ORDERED_DATA_UPDATE_INTERVAL)
			performUpdate(player)
		end
		leaderboardUpdaters[player] = nil
	end

	for _, player in Players:GetPlayers() do
		if DataSaveService:GetProfile(player) then
			task.defer(initLoop, player)
		end
	end

	DataSaveService.ProfileAdded:Connect(function(player)
		initLoop(player)
	end)
end

--[[Forces all bound OrderedDataStores to update immediately for the specific player.]]
function DataSaveService:ForceLeaderboardUpdate(player: Player)
	assert(IsServer, "[DataSaveService]: ForceLeaderboardUpdate can only be called from the server")

	local updaters = leaderboardUpdaters[player]
	if updaters then
		for i, updateFunc in updaters do
			task.defer(updateFunc)
		end
	end
end

--[[Adds a dictionary into the ProfileTemplate.
The location should be seperated using peroids.
If only the index name is provided in <strong>location</strong> the value with be placed directly into Template.
More information can be found on the documentation.]]
function DataSaveService:AddToTemplate(location: string, value: any)
	assert(IsServer, "[DataSaveService]: AddToTemplate can only be called from the server")
	while not ProfileTemplate do
		task.wait(0.1)
	end
	--assert(ProfileTemplate, "Default Profile template must first be created.")
	local currentLocation = ProfileTemplate
	for i,v in string.split(location, ".") do
		if currentLocation[v] then
			currentLocation = currentLocation[v]
			continue
		else
			currentLocation[v] = value
			for i, profile in DataSaveService:GetProfiles() do
				profile:Reconcile()
			end
			return
		end
	end
	error("Attempted to replace existing location.")
end

--[[Sets the name of the ProfileStore.
Must be called before DataSaveService:CreateProfileStore.
Defaults to <strong>MAIN_PROFILE</strong>.]]
function DataSaveService:SetProfileStoreName(storeName: string)
	assert(IsServer, "[DataSaveService]: SetProfileStoreName can only be called from the server")
	assert(typeof(storeName) == "string", "[DataSaveService]: storeName must be a string.")
	assert(not ProfileStore, "[DataSaveService]: SetProfileStoreName must be called before CreateProfileStore")
	ProfileName = storeName
end

--[[Sets the template for Profile keys to use.
Must include <strong>%s</strong>.
<strong>%s</strong> will be replaced by the player's UserId.]]
function DataSaveService:SetProfileKeyTemplate(keyTemplate: string)
	assert(IsServer, "[DataSaveService] SetProfileKeyTemplate can only be called from the server")
	assert(not ProfileStore, "[DataSaveService]: ProfileKeyTemplate must be set before CreateProfileStore is called")
	assert(typeof(keyTemplate) == "string", "[DataSaveService]: keyTemplate must be a string")
	if not string.find(keyTemplate, "%%s") then
		error("[DataSaveService]: keyTemplate must contain '%s'")
	end
	ProfileKeyTemplate = keyTemplate
end

local connection

--[[Starts the module and automatically loads profiles.]]
function DataSaveService:CreateProfileStore(): ProfileService.ProfileStore
	assert(IsServer, "[DataSaveService] CreateProfileStore can only be called from the server")
	assert(ProfileTemplate, "[DataSaveService]: Profile template has not be set using SetTemplate")
	assert(not ProfileStore, "[DataSaveService]: ProfileStore has already been created")
	ProfileStore = ProfileService.New(ProfileName, ProfileTemplate)
	local function loadProfile(player: Player)
		local key = if DEBUG then DataSaveService:GetProfileKey(player.UserId.. 1) else DataSaveService:GetProfileKey(player.UserId)

		local profile
		if VERSION_ID and #VERSION_ID > 0 then
			profile = ProfileStore:GetAsync(VERSION_ID[1], VERSION_ID[2])
		else
			profile = ProfileStore:StartSessionAsync(key, {
				Cancel = function()
					return player.Parent ~= Players
				end,
			})
		end

		if profile then
			profile:AddUserId(player.UserId)
			profile:Reconcile()

			local tableProfile = Table.new(table.clone(profile))
			--tableProfile.Data = Table.new(profile.Data)
			profile.Data = table.clone(tableProfile.Data:Serialize())
			connection = tableProfile.Data.Changed:Connect(function()
				--profile.Data = table.clone(tableProfile.Data:Serialize())
				--profile = table.clone(tableProfile:Serialize()) <- old working
				profile.Data = tableProfile.Data:Serialize()
				--profile.Data = table.clone(tableProfile.Data.Raw)
			end)

			profile.OnSessionEnd:Connect(function()
				if DataSaveService:GetProfile(player) then
					script.Communication.ProfileRemoving:Fire(player)
					task.wait()
					if DEBUG then
						warn('Wiping profile data')
						profile.Data = DataSaveService:GetTemplate()
					end
					ProfileTables[player].Data:Destroy()
					Profiles[player]:EndSession()
					--ProfileTables[player]:EndSession()
					ProfileTables[player]:Destroy()
					Profiles[player] = nil
					ProfileTables[player] = nil
					script.Communication.ProfileRemoved:Fire(player)
					print("Profile session ended for ".. player.DisplayName.. ".")
					player:Kick("Profile session ended - Please rejoin.")
				end
			end)

			if Players:FindFirstChild(player.Name) then
				Profiles[player] = profile
				ProfileTables[player] = tableProfile
				print("Profile loaded for ".. player.DisplayName.. ".")
				ReplicationService:Create(tableProfile, script:WaitForChild("Communication").SendProfileToClient, player)

				script.Communication.ProfileAdded:Fire(player)
			else
				--Player left before Profile loaded
				profile:EndSession()
			end
		else
			--Profile failed to load (probably server shutdown)
			player:Kick("Profile failed to load - Please rejoin.")
		end
	end
	local function removeProfile(player: Player)
		--local profile = DataSaveService:GetProfile(player)
		local profile = Profiles[player]
		if profile then
			ReplicationService:Clear(script:WaitForChild("Communication").SendProfileToClient, player)

			DataSaveService:GetProfile(player).Data:ClearConnections()
			profile:EndSession() --i believe as long as not a crash .OnSessionEnd runs

			--[[print(Profiles, ProfileTables)
			ProfileTables[player].Data:Destroy()
			print(profile)
			profile:EndSession()
			print(connection)
			--[[Profiles[player] = nil
			ProfileTables[player].Data:Destroy()
			ProfileTables[player] = nil]
			script.Communication.ProfileRemoving:Fire(player)
			print("Profile session ended for ".. player.DisplayName.. ".")
			script.Communication.ProfileRemoved:Fire(player)
			print(profile)
			print(player.UserId)]]
		end
	end

	for i, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end
	Players.PlayerAdded:Connect(function(player)
		loadProfile(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		removeProfile(player)
	end)

	script:SetAttribute("ProfileStoreCreated", true)
end

--[[If the player's most recent save falls within the times given their Profile will revert to closest save to <strong>revertTime</strong> that falls before the time given in <strong>revertTime</strong>.]]
--[[function DataSaveService:RevertProfile(startTime: number, endTime: number, revertTime: number)
	--will just do this whenever i feel its needed
end]]

startup()

if IsServer then
	--[[script.Communication.RequestProfile.OnServerInvoke = function(player: Player)
		return DataSaveService:GetProfile(player)
	end]]
else
	ReplicationService:Listen(script:WaitForChild("Communication").SendProfileToClient, function(profile: Profile)
		local function update(data: {}, profileIndex)
			if not profileIndex then return end

			for i,v in data do
				if i == "Changed" or i == "IsFrozen" or i == "Parent" then
					continue
				elseif typeof(data[i]) == "table" then
					if profileIndex[i] ~= nil then
						update(data[i], profileIndex[i])
					else
						data[i] = nil
					end
				else
					data[i] = profileIndex[i]
				end
			end

			for i, v in profileIndex do
				if data[i] == nil then
					data[i] = v
				end
			end
		end

		if localProfile then
			update(localProfile, profile)
		else
			localProfile = profile
		end
	end)
end

DataSaveService.ProfileAdded = script.Communication.ProfileAdded.Event:: ProfileSignal
DataSaveService.ProfileRemoving = script.Communication.ProfileRemoving.Event:: ProfileSignal
DataSaveService.ProfileRemoved = script.Communication.ProfileRemoved.Event:: ProfileSignal

return DataSaveService