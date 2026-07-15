local ReplicatedStorage = game:GetService("ReplicatedStorage")
local extend = require(ReplicatedStorage.Modules.extend)

local Signal = {}
Signal.__index = Signal

type Signal = {
	Fire: (self: Signal, ...any) -> (),
	Destroy: (self: Signal) -> ()
} & RBXScriptSignal

function Signal.new(): Signal
	local self = setmetatable({}, Signal)
	self.Event = Instance.new("BindableEvent")
	extend(self, self.Event.Event, self.Event)
	return self
end

function Signal:Destroy()
	self.Event:Destory()
end

return Signal