local _CollectionService = game:GetService("CollectionService")

local extender = require(script.Parent.Parent.Modules.extender)
local table = require(script.Parent.Parent.Libraries.table)

local CollectionService = {}
extender(CollectionService, _CollectionService)

function CollectionService:FindFirstAncestorOfTag(instance: Instance, tag: string)
	local current = instance
	repeat current = current.Parent until current == nil or current:HasTag(tag)
	return current
end

function CollectionService:GetTaggedOfPredicate(tag: string, f: (instance: Instance) -> boolean)
	return table.filter(_CollectionService:GetTagged(tag), f)
end

function CollectionService:GetTaggedOfAncestor(ancestor: Instance, tag: string)
	return CollectionService:GetTaggedOfPredicate(tag, function(instance: Instance)
		return instance:IsDescendantOf(ancestor)
	end)
end

local module: typeof(CollectionService) & CollectionService = CollectionService
return module