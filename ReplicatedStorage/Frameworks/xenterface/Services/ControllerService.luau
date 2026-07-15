local Players = game:GetService("Players")
local CollectionService = require(script.Parent.Parent.Services.CollectionService)
local Controller = require(script.Parent.Parent.Classes.Controller)
local xenimation = require(script.Parent.Parent.Frameworks.xenimation.xenimation)

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local table = require(script.Parent.Parent.Libraries.table)
local helpers = require(script.Parent.Parent.Modules.helpers)
local Settings = require(script.Parent.Parent.Settings.Settings)

local ControllerService = {}
local Controllers = {}

function ControllerService:Create(group: string): Controller.Controller
	if Controllers[group] then return Controllers[group] end
	local controller = Controller.new(group)
	Controllers[group] = controller
	return controller
end

function ControllerService:Delete(group: string)
	Controllers[group] = nil
end

function ControllerService:Get(group: string)
	return Controllers[group]
end

-- Updated section of ControllerService:Fire method
-- (Only showing the animation-related part that needs to change)



function ControllerService:Fire(group: string, id: any, rawTab: GuiButton)
	local controller = Controllers[group]
	if not controller then return end

	controller._currentPageId = id

	local tabs = CollectionService:GetTaggedOfPredicate(Settings.TabTag, function(v: Instance)
		return v:IsDescendantOf(PlayerGui) and v:GetAttribute(Settings.GroupAttribute) == group
	end)
	local pages = CollectionService:GetTaggedOfPredicate(Settings.PageTag, function(v: Instance)
		return v:IsDescendantOf(PlayerGui) and v:GetAttribute(Settings.GroupAttribute) == group
	end)

	local selectedTabs = table.filter(tabs, function(v: Instance)
		return v:GetAttribute(Settings.IdAttribute) == id
	end)
	local unselectedTabs = table.filter(tabs, function(v: Instance)
		return v:GetAttribute(Settings.IdAttribute) ~= id
	end)

	local filterPages = function(pages)
		for i, page in pages do
			if not page:IsA("GuiObject") then
				pages[i] = page.Parent
			end
		end
	end
	local selectedPages = table.filter(pages, function(v: Instance)
		return v:GetAttribute(Settings.IdAttribute) == id
	end)
	filterPages(selectedPages)
	local unselectedPages = table.filter(pages, function(v: Instance)
		return v:GetAttribute(Settings.IdAttribute) ~= id
	end)
	filterPages(unselectedPages)

	-- Filter out exclusive tabs for animations (same logic as controller callbacks)
	local animationSelectedTabs = table.filter(selectedTabs, function(tab)
		return not (rawTab ~= tab and tab:GetAttribute(Settings.ExclusiveAttribute) == true)
	end)
	local animationUnselectedTabs = table.filter(unselectedTabs, function(tab)
		return not (tab:GetAttribute(Settings.ExclusiveAttribute) == true)
	end)

	-- Play animations for tabs and pages REGARDLESS of whether controller functions exist
	helpers.playAnimationsForObjects(animationSelectedTabs, true)    -- Selected state
	helpers.playAnimationsForObjects(animationUnselectedTabs, false) -- Unselected state
	helpers.playAnimationsForObjects(selectedPages, true)            -- Selected state
	helpers.playAnimationsForObjects(unselectedPages, false)         -- Unselected state

	-- Original controller callback logic (unchanged)
	if controller.SelectedTab then
		for _, tab in selectedTabs do
			if rawTab ~= tab and tab:GetAttribute(Settings.ExclusiveAttribute) == true then continue end
			controller.SelectedTab(tab)
		end
	end
	if controller.UnselectedTab then
		for _, tab in unselectedTabs do
			if tab:GetAttribute(Settings.ExclusiveAttribute) == true then continue end
			controller.UnselectedTab(tab)
		end
	end
	if controller.UnselectedPage then
		for _, page in unselectedPages do
			controller.UnselectedPage(page)
		end
	end
	if controller.SelectedPage then
		for _, page in selectedPages do
			controller.SelectedPage(page)
		end
	end
end

return ControllerService