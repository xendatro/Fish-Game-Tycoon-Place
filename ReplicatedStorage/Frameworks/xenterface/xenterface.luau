--[[
xenterface + xenimation framework
Created by xendatro
]]

local ControllerService = require(script.Parent.Services.ControllerService)
local CollectionService = require(script.Parent.Services.CollectionService)
local Players = game:GetService("Players")
local TagService = require(script.Parent.Frameworks.xenimation.Services.TagService)
local xenimation = require(script.Parent.Frameworks.xenimation.xenimation)
local Settings = require(script.Parent.Settings.Settings)
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Hover = require(script.Parent.Classes.Hover)
local Tab = require(script.Parent.Classes.Tab)
local Controller = require(script.Parent.Classes.Controller)

local xenterface = {}
local groups = {}

-- Internal function to create controllers and manage groups
local function createController(pageGroup: string)
	-- Check if controller already exists
	local existing = ControllerService:Get(pageGroup)
	if existing then
		return existing
	end

	-- Create new controller
	local newController = ControllerService:Create(pageGroup)

	-- Add to groups tracking if not already present
	if not table.find(groups, pageGroup) then
		table.insert(groups, pageGroup)
		print("Created controller for group: " .. pageGroup)
	end

	return newController
end

-- Internal function to delete controllers and manage groups
local function deleteController(pageGroup: string)
	ControllerService:Delete(pageGroup)

	-- Remove from groups tracking
	local index = table.find(groups, pageGroup)
	if index then
		table.remove(groups, index)
		print("Deleted controller for group: " .. pageGroup)
	end
end

function xenterface:FireController(pageGroup: string, pageId: string | number, rawTab: GuiButton?)
	ControllerService:Fire(pageGroup, pageId, rawTab)
end

function xenterface:GetElementById(elementId: string)
	local elements = CollectionService:GetTaggedOfPredicate(Settings.ElementTag, function(v: Instance)
		return v:IsDescendantOf(PlayerGui) and v:GetAttribute(Settings.ElementIdAttribute) == elementId
	end)
	return elements[1]
end

function xenterface:GetElementsByClass(elementClass: string)
	return CollectionService:GetTaggedOfPredicate(Settings.ElementTag, function(v: Instance)
		return v:IsDescendantOf(PlayerGui) and v:GetAttribute(Settings.ElementClassAttribute) == elementClass
	end)
end

xenterface.xenimation = xenimation

-- Automatic controller creation when Pages/Tabs are detected
TagService:Listen("Page", function(page)
	local group = page:GetAttribute("PageGroup")
	if not group then return end

	createController(group) -- Handles duplicate checking and group tracking
end, function() end, PlayerGui)

TagService:Listen("Tab", function(tab)
	local group = tab:GetAttribute("PageGroup")
	if not group then return end

	local tabInstance = Tab.new(tab)
	createController(group) -- Handles duplicate checking and group tracking
	
	return tabInstance
end, function(tab: Instance, data: any)
	if data and data.Destroy then
		data:Destroy()
	end
end, PlayerGui)

TagService:Listen("Hover", function(hover)
	return Hover.new(hover)
end, function(hover: Instance, data: Hover.Hover)
	data:Destroy()
end, PlayerGui)

function xenterface:GetController(pageGroup: string): Controller.Controller
	return createController(pageGroup) -- Lazy creation with proper group tracking
end

function xenterface:GetHover(hover: GuiObject): Hover.Hover
	return TagService:GetApplied("Hover", hover)
end

function xenterface:HasGroup(pageGroup: string)
	return table.find(groups, pageGroup) ~= nil
end

function xenterface:GetGroups()
	return table.clone(groups)
end

return xenterface
