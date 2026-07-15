local extender = require(script.Parent.Parent.Modules.extender)

local Signal = {}

function Signal.new()
	local self: BindableEvent & RBXScriptSignal = {}
	self.Event = Instance.new("BindableEvent")
	extender(self, self.Event.Event, self.Event)
	return self
end

return Signal