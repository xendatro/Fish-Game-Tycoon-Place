local Animation = {}
Animation.__index = Animation

local AttrConfig = require(script.Parent.Parent.Config.AttrConfig)

function Animation.new(taggedInstance: Instance)
	local self = setmetatable({}, Animation)

	-- The tagged instance IS the animation source
	self.configSource = taggedInstance

	-- Determine the target GuiObject
	if taggedInstance:IsA("GuiObject") then
		self.guiObject = taggedInstance
	else
		-- Configuration case - parent is the GuiObject
		self.guiObject = taggedInstance.Parent
	end

	-- Create only ONE animation from this specific tagged source
	self:createSingleAnimation()

	return self
end

function Animation:createSingleAnimation()
	local animationId = self.configSource:GetAttribute("AnimationId") or 
		(self.configSource == self.guiObject and "default" or self.configSource.Name)

	-- Create animation configuration
	local animationData = {
		configSource = self.configSource,
		initialProperties = {}
	}

	-- Check if this animation uses "initial" keyword (including presets)
	local needsInitial = true --self:checkForInitialKeyword()

	-- Capture initial properties if needed
	if needsInitial then
		self:captureInitialProperties(animationData.initialProperties)
	end

	-- Store the single animation
	self.animationId = animationId
	self.animationData = animationData
end

function Animation:checkForInitialKeyword()
	-- Check direct attributes
	local activeClasses = self.configSource:GetAttribute("Active") or ""
	local inactiveClasses = self.configSource:GetAttribute("Inactive") or ""

	if string.find(activeClasses, "initial") or string.find(inactiveClasses, "initial") then
		return true
	end

	-- Check presets
	local presetAttribute = self.configSource:GetAttribute("Preset")
	if presetAttribute then
		-- Get presets module (same way xenimation does it)
		local xenimationModule = script.Parent.Parent -- Navigate to xenimation module
		local presetsModule = xenimationModule:FindFirstChild("Presets")

		if presetsModule then
			local presets = require(presetsModule)

			-- Check each preset name in the attribute
			for presetName in string.gmatch(presetAttribute, "%S+") do
				local preset = presets[presetName]
				if preset then
					local presetActive = preset.Active or ""
					local presetInactive = preset.Inactive or ""

					if string.find(presetActive, "initial") or string.find(presetInactive, "initial") then
						return true
					end
				end
			end
		end
	end

	return false
end

function Animation:captureInitialProperties(initialProps)
	-- Capture all GUI properties from config
	for prefix, config in pairs(AttrConfig) do
		if config.target == "gui" then
			local success, value = pcall(function() 
				return self.guiObject[config.property] 
			end)
			if success then
				initialProps[prefix] = value
			end
		end
	end

	-- Capture modifier properties only if they exist
	local uiScale = self.guiObject:FindFirstChildOfClass("UIScale")
	if uiScale then
		initialProps.scale = uiScale.Scale
	end

	local uiStroke = self.guiObject:FindFirstChildOfClass("UIStroke")
	if uiStroke then
		initialProps.sth = uiStroke.Thickness
		initialProps.sbo = uiStroke.BorderOffset
		initialProps.str = uiStroke.Transparency
		initialProps.sc = uiStroke.Color
	end

	local uiCorner = self.guiObject:FindFirstChildOfClass("UICorner")
	if uiCorner then
		initialProps.cr = uiCorner.CornerRadius
	end

	local uiAspectRatio = self.guiObject:FindFirstChildOfClass("UIAspectRatioConstraint")
	if uiAspectRatio then
		initialProps.ar = uiAspectRatio.AspectRatio
	end

	local uiSizeConstraint = self.guiObject:FindFirstChildOfClass("UISizeConstraint")
	if uiSizeConstraint then
		initialProps.maxs = uiSizeConstraint.MaxSize
		initialProps.mins = uiSizeConstraint.MinSize
	end

	local uiTextSizeConstraint = self.guiObject:FindFirstChildOfClass("UITextSizeConstraint")
	if uiTextSizeConstraint then
		initialProps.maxts = uiTextSizeConstraint.MaxTextSize
		initialProps.mints = uiTextSizeConstraint.MinTextSize
	end
end

function Animation:getAnimationConfig()
	return {
		animationId = self.animationId,
		active = self.configSource:GetAttribute("Active"),
		inactive = self.configSource:GetAttribute("Inactive"),
		preset = self.configSource:GetAttribute("Preset")
	}
end

function Animation:getInitialProperty(propertyName: string)
	return self.animationData.initialProperties[propertyName]
end

function Animation:hasInitialProperties()
	return next(self.animationData.initialProperties) ~= nil
end

-- Get the animation ID for this Animation object
function Animation:getAnimationId()
	return self.animationId
end

-- Check if this is the specified animation
function Animation:hasAnimation(animationId: string)
	return self.animationId == animationId
end

return Animation