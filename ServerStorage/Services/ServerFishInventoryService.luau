local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataSaveService = require(ReplicatedStorage.Services.DataSaveService)
local SharedFishInventoryService = require(ReplicatedStorage.Services.SharedFishInventoryService)
local ServerFishInventoryService = setmetatable({}, {__index = SharedFishInventoryService})

function ServerFishInventoryService:GiveFish(player: Player, fishData: SharedFishInventoryService.FishData)
	if fishData.ObjectId then
		error("ObjectId should only be used in the data for assigning a fish to a tank")
	end
	
	local profile = DataSaveService:WaitForProfile(player)
	if not profile then return end
	
	profile.Data.Fish:Insert(fishData)
end

function ServerFishInventoryService:RemoveFish(player: Player, fishData: SharedFishInventoryService.FishData)
	local profile = DataSaveService:WaitForProfile(player)
	if not profile then return end
	
	for index, fish in profile.Data.Fish do
		if SharedFishInventoryService:_fishMatches(fish, fishData) then
			profile.Data.Fish:Remove(index)
			return
		end
	end

	warn(`Fish not found for {player.Name}`, fishData)
end

function ServerFishInventoryService:AssignFishToObject()
	error('not written')
end

return ServerFishInventoryService