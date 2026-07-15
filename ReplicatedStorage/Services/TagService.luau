--[[
Service that extends CollectionService functionality with advanced tag management,
providing automatic apply/unapply functions and data tracking for tagged instances.
]]
local CollectionService = game:GetService("CollectionService")

local TagService = {}

local Tagged = {}
local Connections = {}
local Functions = {}

--[[
Sets up tag listening with apply and unapply functions for automatic tag management.
]]
function TagService:Listen(tagName: string, applyFunction: (instance: Instance) -> any, unapplyFunction: (instance: Instance, data: any) -> nil, ancestor: Instance?)
	if Tagged[tagName] then warn("Attempted to apply same tag name.") return end
	
	if not ancestor then
		warn("Ancestor not set for ".. tagName)
	end
	
	local t = {}
	Tagged[tagName] = t

	local c = {}
	Connections[tagName] = c

	Functions[tagName] = {
		ApplyFunction = applyFunction,
		UnapplyFunction = unapplyFunction
	}

	local function apply(instance)
		if t[instance] then return end
		if instance:IsDescendantOf(ancestor) then
			t[instance] = "HOLDER"
			t[instance] = applyFunction(instance)
		end
	end

	local function unapply(instance)
		if t[instance] then
			local class = t[instance]
			t[instance] = nil
			if class == "HOLDER" then
				class = nil
			end
			unapplyFunction(instance, class)
		end
	end

	for _, instance in CollectionService:GetTagged(tagName) do
		apply(instance)
	end

	table.insert(c,
		CollectionService:GetInstanceAddedSignal(tagName):Connect(function(instance: Instance)
			apply(instance)
		end)
	)

	table.insert(c,
		CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance:Instance)
			unapply(instance)
		end)
	)

	if ancestor then
		table.insert(c,
			ancestor.DescendantAdded:Connect(function(instance)
				if instance:HasTag(tagName) then
					task.wait()
					apply(instance)
				end
			end)
		)
		table.insert(c,
			ancestor.DescendantRemoving:Connect(function(instance)
				if instance:HasTag(tagName) then
					task.wait()
					unapply(instance)
				end
			end)
		)
	end
end

--[[
Stops listening to a tag and calls unapplyFunction for all tagged instances.
]]
function TagService:Unlisten(tagName: string)
	if not Tagged[tagName] then return end
	for _, connection in Connections[tagName] do
		connection:Disconnect()
	end
	local unapplyFunction = Functions[tagName].UnapplyFunction
	for instance, data in Tagged[tagName] do
		if unapplyFunction then
			unapplyFunction(instance, data)			
		end
	end
	Tagged[tagName] = nil
	Connections[tagName] = nil
	Functions[tagName] = nil
end

--[[
Returns a copy of all applied instances and their data for a specific tag.
]]
function TagService:GetAllApplied(tagName: string)
	local clone = {}
	for instance, apply in Tagged[tagName] do
		clone[instance] = apply
	end
	return clone
end

--[[
Gets the applied data for a specific instance with a given tag.
]]
function TagService:GetApplied(tagName: string, instance: Instance)
	if not Tagged[tagName] then return end
	return Tagged[tagName][instance]
end

return TagService