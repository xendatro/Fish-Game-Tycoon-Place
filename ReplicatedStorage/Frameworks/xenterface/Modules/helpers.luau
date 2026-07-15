local xenimation = require(script.Parent.Parent.Frameworks.xenimation.xenimation)

local helpers = {}

function helpers.playAnimationsForObjects(objects, isSelected)
	for _, object in objects do
		local animations = object:GetAttribute("Animations")
		if animations and animations ~= "" then
			-- Parse space-separated animation IDs
			for animationId in string.gmatch(animations, "%S+") do
				-- Check if this specific animation exists before playing
				if xenimation:HasAnimation(object, animationId) then
					xenimation:Play(object, animationId, isSelected)
				else
					-- Optionally warn if animation doesn't exist
					warn("ControllerService: Animation '" .. animationId .. "' not found for " .. object.Name)
				end
			end
		end
		if object:GetAttribute("AnimationId") == nil or object:GetAttribute("AnimationId") == "" then
			xenimation:Play(object, "default", isSelected)
		end
	end
end

return helpers
