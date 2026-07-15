return function(t: {}, ...: {} | Instance)
	local extensions = table.pack(...)
	local function findTarget(index: string)
		for _, extension in ipairs(extensions) do
			local success, extensionType = pcall(function() 
				if extension[index] == nil then
					error()
				end
				return type(extension)
			end)
			if success then
				return extension, extensionType
			end
		end
	end
	local mt = {
		__index = function(_, index: string)
			local targetExtension, extensionType = findTarget(index)
			if targetExtension == nil then
				return nil
			elseif type(targetExtension[index]) == "function" then
				return function(t, ...)
					return targetExtension[index](if extensionType == "table" then t else targetExtension, ...)
				end
			else
				return targetExtension[index]
			end
		end,
		__newindex = function(_, index: string, value: any)
			local targetExtension = findTarget(index)
			if targetExtension == nil then
				rawset(t, index, value)
			else
				targetExtension[index] = value
			end
		end,
	}
	return setmetatable(t, mt)
end
