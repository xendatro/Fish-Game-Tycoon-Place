local ControllerService = require(script.Parent.Parent.Services.ControllerService)

local Settings = require(script.Parent.Parent.Settings.Settings)

local Tab = {}
Tab.__index = Tab

local function setUpConnections(self)
	self.Connections = {}
	self.Connections.MouseButton1Click = self.Button.MouseButton1Click:Connect(function()
		local group = self.Tab:GetAttribute(Settings.GroupAttribute)
		local id = self.Tab:GetAttribute(Settings.IdAttribute)

		if self.Tab:GetAttribute(Settings.ToggleAttribute) == true then
			local controller = ControllerService:Get(group)
			if controller and controller._currentPageId ~= nil and controller:IsSelected(id) then
				id = ""
			end
		end

		ControllerService:Fire(
			group,
			id,
			self.Button
		)
	end)
end

function Tab.new(tab: GuiButton | Configuration)
	local self = setmetatable({}, Tab)

	self.Tab = tab
	self.Button = if not tab:IsA("GuiButton") then tab.Parent else tab

	setUpConnections(self)

	return self
end


function Tab:Destroy()
	for _, connection in self.Connections do
		connection:Disconnect()
	end
end

return Tab