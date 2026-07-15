local Controller = {}
Controller.__index = Controller

export type Controller = {
	PageGroup: string,
	_currentPageId: any,
	SelectedTab: (tab: GuiButton) -> nil,
	UnselectedTab: (tab: GuiButton) -> nil,
	SelectedPage: (page: GuiObject) -> nil,
	UnselectedPage: (page: GuiObject) -> nil,
	IsSelected: (Controller, pageId: string) -> boolean,
	Fire: (Controller, pageId: string | number, rawTab: GuiButton?) -> (),
}

function Controller.new(pageGroup: string)
	local self: Controller = setmetatable({}, Controller)
	
	self.PageGroup = pageGroup
	self._currentPageId = nil
	
	return self
end

function Controller:IsSelected(pageId: any)
	return self._currentPageId == pageId
end

function Controller:Fire(pageId: string | number, rawTab: GuiButton?)
	local ControllerService = require(script.Parent.Parent.Services.ControllerService)
	ControllerService:Fire(self.PageGroup, pageId, rawTab)
end



return Controller