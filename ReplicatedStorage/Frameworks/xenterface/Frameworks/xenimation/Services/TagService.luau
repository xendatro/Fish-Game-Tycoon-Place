--[[
Service that provides a higher-level interface for CollectionService tags.
Automatically manages object creation/destruction and connection cleanup for tagged instances.
]]
local CollectionService = game:GetService("CollectionService")

local TagService = {}

-- Storage for tagged instances and their associated data/objects
local Tagged = {}

-- Storage for connections to prevent memory leaks
local Connections = {}

-- Storage for apply/unapply functions for each tag
local Functions = {}

--[[
Example usage:
TagService:Listen("Glorb", function(glorb: BasePart)
	return Glorb.new(glorb)
end, function(instance, glorbObject)
	glorbObject:Destroy()
end, nil)
]]

--[[
Sets up automatic object management for instances with a specific tag.
When an instance is tagged, applyFunction is called and its return value is stored.
When an instance is untagged or removed, unapplyFunction is called with the stored data.
]]
function TagService:Listen(tagName: string, applyFunction: (instance: Instance) -> any, unapplyFunction: (instance: Instance, data: any) -> nil, ancestor: Instance?)
	-- Prevent duplicate listeners for the same tag
	if Tagged[tagName] then 
		warn("Attempted to apply same tag name.") 
		return 
	end

	-- Initialize storage for this tag
	local taggedInstances = {}
	Tagged[tagName] = taggedInstances

	local connections = {}
	Connections[tagName] = connections

	Functions[tagName] = {
		ApplyFunction = applyFunction,
		UnapplyFunction = unapplyFunction
	}

	--[[
	Applies the tag function to an instance if it meets criteria.
	]]
	local function apply(instance)
		-- Prevent duplicate applications
		if taggedInstances[instance] then return end

		-- Check ancestor constraint if one exists
		if ancestor and not instance:IsDescendantOf(ancestor) then return end

		taggedInstances[instance] = applyFunction(instance)
	end

	--[[
	Removes the tag application from an instance and calls cleanup.
	]]
	local function unapply(instance)
		if taggedInstances[instance] then
			unapplyFunction(instance, taggedInstances[instance])
			taggedInstances[instance] = nil
		end
	end

	-- Apply to all existing tagged instances
	for _, instance in CollectionService:GetTagged(tagName) do
		apply(instance)
	end

	-- Listen for new instances being tagged
	table.insert(connections,
		CollectionService:GetInstanceAddedSignal(tagName):Connect(function(instance: Instance)
			apply(instance)
		end)
	)

	-- Listen for instances being untagged
	table.insert(connections,
		CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance: Instance)
			unapply(instance)
		end)
	)

	-- If ancestor is specified, also listen for descendants being added/removed
	if ancestor then
		table.insert(connections,
			ancestor.DescendantAdded:Connect(function(instance)
				if instance:HasTag(tagName) then
					apply(instance)
				end
			end)
		)

		table.insert(connections,
			ancestor.DescendantRemoving:Connect(function(instance)
				if instance:HasTag(tagName) then
					unapply(instance)
				end
			end)
		)
	end
end

--[[
Stops listening for a tag and cleans up all associated instances and connections.
Calls the unapplyFunction for all currently applied instances.
]]
function TagService:Unlisten(tagName: string)
	if not Tagged[tagName] then return end

	-- Disconnect all connections to prevent memory leaks
	for _, connection in Connections[tagName] do
		connection:Disconnect()
	end

	-- Clean up all applied instances
	local unapplyFunction = Functions[tagName].UnapplyFunction
	for instance, data in Tagged[tagName] do
		if unapplyFunction then
			unapplyFunction(instance, data)			
		end
	end

	-- Clear storage
	Tagged[tagName] = nil
	Connections[tagName] = nil
	Functions[tagName] = nil
end

--[[
Returns a copy of all currently applied instances and their associated data for a tag.
]]
function TagService:GetAllApplied(tagName: string): {[Instance]: any}
	if not Tagged[tagName] then return {} end

	local clone = {}
	for instance, data in Tagged[tagName] do
		clone[instance] = data
	end
	return clone
end

--[[
Gets the applied data for a specific instance with a specific tag.
Returns nil if the instance is not currently applied.
]]
function TagService:GetApplied(tagName: string, instance: Instance): any
	if not Tagged[tagName] then return nil end
	return Tagged[tagName][instance]
end

return TagService