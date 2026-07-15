const ReplicatedStorage = game:GetService("ReplicatedStorage")

const DataSaveService = require(ReplicatedStorage.Services.DataSaveService)
local SharedFishInventoryService = {}

export type FishData = {
	ObjectId: string?,
	Name: string,
	Size: "Tiny"|"Small"|"Medium"|"Large"|"Huge",
	Modifier: string?
}

--[[
Returns whether ownedFish satisfies every field present in query. Fields omitted
from query are ignored, so a partial query (eg only Name) matches on that field alone.
]]
function SharedFishInventoryService:_fishMatches(ownedFish: FishData, query: FishData): boolean
	for key, value in query do
		if ownedFish[key] ~= value then
			return false
		end
	end
	return true
end

--[[
Returns all fish a player owns. IncludeUsed defaults to false, if true returns fish in tanks.
]]
function SharedFishInventoryService:GetFish(player: Player, includeUsed: boolean?)
	local profile = DataSaveService:WaitForProfile(player)
	if not profile then return end
	
	if includeUsed then
		return profile.Data.Fish:Serialize()
	else
		local fishToReturn = {}
		for _, fishData in profile.Data.Fish do
			if fishData.ObjectId then continue end
			table.insert(fishToReturn, fishData)
		end
		return fishToReturn
	end
end

--[[
Returns whether a player owns the given fish. Includes fish already placed in a tank. Use IsFishInInventory for strictly inventory searches.
]]
function SharedFishInventoryService:PlayerOwnsFish(player: Player, fishData: FishData)
	local profile = DataSaveService:WaitForProfile(player)
	if not profile then return end

	for _, ownedFish in profile.Data.Fish do
		if SharedFishInventoryService:_fishMatches(ownedFish, fishData) then
			return true
		end
	end
	return false
end

--[[
Returns whether the given player has the given fish in their inventory.
]]
function SharedFishInventoryService:IsFishInInventory(player: Player, fishData: FishData)
	local profile = DataSaveService:WaitForProfile(player)
	if not profile then return end

	local query = table.clone(fishData)
	query.ObjectId = nil
	for _, ownedFish in profile.Data.Fish do
		if ownedFish.ObjectId then continue end
		if SharedFishInventoryService:_fishMatches(ownedFish, query) then
			return true
		end
	end
	return false
end

return SharedFishInventoryService