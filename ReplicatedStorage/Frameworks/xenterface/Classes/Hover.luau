local helpers = require(script.Parent.Parent.Modules.helpers)

local Hover = {}
Hover.__index = Hover

export type Hover = {
	Hover: GuiObject,
	EnterFunction: (GuiObject) -> nil,
	LeaveFunction: (GuiObject) -> nil,
	Destroy: (self: Hover) -> nil
}

local function setUpConnections(self)
	self.Connections = {}
	self.Connections.MouseEnter = self.Hover.MouseEnter:Connect(function()
		helpers.playAnimationsForObjects({self.Hover}, true)
		if self.EnterFunction then
			self.EnterFunction(self.Hover)
		end
	end)
	self.Connections.MouseLeave = self.Hover.MouseLeave:Connect(function()
		helpers.playAnimationsForObjects({self.Hover}, false)
		if self.LeaveFunction then
			self.LeaveFunction(self.Hover)
		end
	end)
end

function Hover.new(guiObject: GuiObject)
	local self = setmetatable({}, Hover)
	
	self.Hover = guiObject
	
	setUpConnections(self)
	
	return self
end

function Hover:Destroy()
	for _, connection in self.Connections do
		connection:Destroy()
	end
end

return Hover
