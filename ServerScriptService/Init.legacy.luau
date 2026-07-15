for _, service in game:GetService("ReplicatedStorage").Services:GetChildren() do
	if service.Name:find("Shared") then
		task.defer(function()
			require(service)
		end)
	end
end
for _, service in game:GetService("ServerStorage").Services:GetChildren() do
	task.defer(function()
		require(service)
	end)
end