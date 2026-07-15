local xenimation = {}

local TagService = require(script.Parent.Services.TagService)
local Animation = require(script.Parent.Classes.Animation)
local AttrConfig = require(script.Parent.Config.AttrConfig)

-- Updated TagService listener to handle both GuiObjects and Configurations
TagService:Listen("Animation", function(instance: Instance)
	return Animation.new(instance)
end, function() end, game)

-- Private properties
local activeAnimations = {}

-- Configuration
local DEFAULT_ANIMATION_ID = "default"

-- Load presets from child ModuleScript
local presets = {}
local presetsModule = script.Parent:FindFirstChild("Presets")
if presetsModule then
	presets = require(presetsModule)
end

-- Base colors as pure RGB values (full saturation, full brightness)
local baseColorsRGB = {
	red = Color3.new(1, 0, 0),
	orange = Color3.new(1, 0.5, 0),
	yellow = Color3.new(1, 1, 0),
	green = Color3.new(0, 1, 0),
	blue = Color3.new(0, 0, 1),
	indigo = Color3.new(0.3, 0, 0.5),
	violet = Color3.new(0.5, 0, 1),
	purple = Color3.new(0.5, 0, 0.5),
	pink = Color3.new(1, 0.4, 0.7),
	brown = Color3.new(0.6, 0.3, 0.1),
	tan = Color3.new(0.8, 0.7, 0.5),
	beige = Color3.new(0.96, 0.96, 0.86),
	cyan = Color3.new(0, 1, 1),
	magenta = Color3.new(1, 0, 1),
	lime = Color3.new(0.5, 1, 0),
	teal = Color3.new(0, 0.5, 0.5),
	navy = Color3.new(0, 0, 0.5),
	maroon = Color3.new(0.5, 0, 0),
	olive = Color3.new(0.5, 0.5, 0),
	black = Color3.new(0, 0, 0),
	gray = Color3.new(0.5, 0.5, 0.5),
	white = Color3.new(1, 1, 1)
}

local function getColorWithIntensity(colorName, intensity)
	local baseColor = baseColorsRGB[colorName]
	if not baseColor then return nil end

	-- Clamp intensity to 0-1 range
	intensity = math.max(0, math.min(1, intensity))

	-- Special cases for pure black and white (no intensity scaling)
	if colorName == "black" then
		return Color3.new(0, 0, 0)
	elseif colorName == "white" then
		return Color3.new(1, 1, 1)
	end

	-- Define the "dark end" and "bright end" with margins
	-- Instead of going to pure black/white, stay visibly colored
	local darkMargin = 0.15   -- Darkest will be 15% of base color (still visibly red)
	local brightMargin = 0.85 -- Brightest will be 85% toward white (still visibly red)

	-- Split the intensity range into two parts:
	-- 0.0 to 0.5: lerp from dark margin to base color
	-- 0.5 to 1.0: lerp from base color to bright margin

	if intensity <= 0.5 then
		-- Dark range: interpolate from darkMargin * baseColor to baseColor
		local t = intensity * 2 -- Scale 0-0.5 to 0-1
		local darkColor = Color3.new(
			baseColor.R * darkMargin,
			baseColor.G * darkMargin,
			baseColor.B * darkMargin
		)
		return Color3.new(
			darkColor.R + (baseColor.R - darkColor.R) * t,
			darkColor.G + (baseColor.G - darkColor.G) * t,
			darkColor.B + (baseColor.B - darkColor.B) * t
		)
	else
		-- Bright range: interpolate from base color toward white (but not all the way)
		local t = (intensity - 0.5) * 2 -- Scale 0.5-1 to 0-1
		local brightColor = Color3.new(
			baseColor.R + (1 - baseColor.R) * brightMargin,
			baseColor.G + (1 - baseColor.G) * brightMargin,
			baseColor.B + (1 - baseColor.B) * brightMargin
		)
		return Color3.new(
			baseColor.R + (brightColor.R - baseColor.R) * t,
			baseColor.G + (brightColor.G - baseColor.G) * t,
			baseColor.B + (brightColor.B - baseColor.B) * t
		)
	end
end

local function parseUDimSequence(sequence)
	-- Check for direct Scale-Offset format (cr-0.1-10)
	local scale, offset = string.match(sequence, "^([%d%.%-]+)%-([%d%.%-]+)$")
	if scale and offset then
		return UDim.new(tonumber(scale), tonumber(offset))
	end

	-- Check for single number (treat as offset pixels)
	local singleValue = string.match(sequence, "^([%d%.%-]+)$")
	if singleValue then
		return UDim.new(0, tonumber(singleValue))
	end

	return nil
end

local function parseVector2Sequence(sequence)
	-- Check for direct X-Y format (cp-200-150)
	local x, y = string.match(sequence, "^([%d%.%-]+)%-([%d%.%-]+)$")
	if x and y then
		return Vector2.new(tonumber(x), tonumber(y))
	end

	-- Enhanced parsing for negative numbers with better dash handling
	local parts = {}
	local currentPart = ""
	local i = 1

	while i <= #sequence do
		local char = sequence:sub(i, i)

		if char == "-" then
			if sequence:sub(i+1, i+1) == "-" then
				if currentPart ~= "" then
					table.insert(parts, currentPart)
					currentPart = ""
				end
				i = i + 2
				currentPart = "-"
			else
				if currentPart ~= "" then
					table.insert(parts, currentPart)
					currentPart = ""
				end
				i = i + 1
			end
		else
			currentPart = currentPart .. char
			i = i + 1
		end
	end

	if currentPart ~= "" then
		table.insert(parts, currentPart)
	end

	-- Check if first part is a cardinal direction
	local cardinal = parts[1]
	local baseX, baseY = 0, 0
	local isCardinal = false

	if cardinal == "nw" then baseX, baseY, isCardinal = 0, 0, true
	elseif cardinal == "n" then baseX, baseY, isCardinal = 0.5, 0, true
	elseif cardinal == "ne" then baseX, baseY, isCardinal = 1, 0, true
	elseif cardinal == "w" then baseX, baseY, isCardinal = 0, 0.5, true
	elseif cardinal == "c" then baseX, baseY, isCardinal = 0.5, 0.5, true
	elseif cardinal == "e" then baseX, baseY, isCardinal = 1, 0.5, true
	elseif cardinal == "sw" then baseX, baseY, isCardinal = 0, 1, true
	elseif cardinal == "s" then baseX, baseY, isCardinal = 0.5, 1, true
	elseif cardinal == "se" then baseX, baseY, isCardinal = 1, 1, true
	end

	local x, y
	if isCardinal then
		x, y = baseX, baseY
	else
		x, y = 0, 0
	end

	-- Process adjustment parts (using x/y instead of xs/xo/ys/yo)
	local startIndex = isCardinal and 2 or 1
	for i = startIndex, #parts do
		local part = parts[i]

		-- Parse x adjustment (x200, x--50)
		local xValue = string.match(part, "^(%-?[%d%.]+)x$")
		if xValue then
			x = x + tonumber(xValue)
		end

		-- Parse y adjustment (y150, y--100)
		local yValue = string.match(part, "^(%-?[%d%.]+)y$")
		if yValue then
			y = y + tonumber(yValue)
		end
	end

	return Vector2.new(x, y)
end

local function parsePositionSequence(sequence, isVector2)
	local xScale, xOffset, yScale, yOffset = string.match(sequence, "^(%-?[%d.]+)%-(%-?[%d.]+)%-(%-?[%d.]+)%-(%-?[%d.]+)$")
	if xScale and xOffset and yScale and yOffset then
		if isVector2 then
			return Vector2.new(tonumber(xScale), tonumber(yScale))
		else
			return UDim2.new(tonumber(xScale), tonumber(xOffset), tonumber(yScale), tonumber(yOffset))
		end
	end

	-- Corrected splitting logic to handle all negative cases
	local parts = {}
	local currentPart = ""
	local i = 1

	-- Handle a potential leading negative sign FIRST, which was the primary bug.
	if sequence:sub(1, 1) == "-" then
		currentPart = "-"
		i = 2
	end

	-- Now loop through the rest of the string.
	while i <= #sequence do
		local char = sequence:sub(i, i)
		if char == '-' then
			-- This character is a dash. We must decide if it's a separator or part of a '--' negative.
			if #currentPart > 0 then table.insert(parts, currentPart) end

			-- Check if the NEXT character is also a dash (the '--' case)
			if sequence:sub(i + 1, i + 1) == '-' then
				currentPart = "-" -- Start the next part as negative
				i = i + 2       -- Skip both dashes
			else
				currentPart = ""  -- It's a simple separator, start a blank part
				i = i + 1
			end
		else
			currentPart = currentPart .. char -- Append non-dash characters
			i = i + 1
		end
	end
	if #currentPart > 0 then
		table.insert(parts, currentPart)
	end

	local cardinal = parts[1]
	local baseX, baseY = 0, 0
	local isCardinal = false
	if cardinal == "nw" then baseX, baseY, isCardinal = 0, 0, true
	elseif cardinal == "n" then baseX, baseY, isCardinal = 0.5, 0, true
	elseif cardinal == "ne" then baseX, baseY, isCardinal = 1, 0, true
	elseif cardinal == "w" then baseX, baseY, isCardinal = 0, 0.5, true
	elseif cardinal == "c" then baseX, baseY, isCardinal = 0.5, 0.5, true
	elseif cardinal == "e" then baseX, baseY, isCardinal = 1, 0.5, true
	elseif cardinal == "sw" then baseX, baseY, isCardinal = 0, 1, true
	elseif cardinal == "s" then baseX, baseY, isCardinal = 0.5, 1, true
	elseif cardinal == "se" then baseX, baseY, isCardinal = 1, 1, true
	end

	-- Initialize final values
	if isCardinal then
		xScale, xOffset, yScale, yOffset = baseX, 0, baseY, 0
	else
		xScale, xOffset, yScale, yOffset = 0, 0, 0, 0
	end

	-- Process each part to find and apply modifiers (xs, xo, ys, yo)
	local startIndex = isCardinal and 2 or 1
	for i = startIndex, #parts do
		local part = parts[i]
		-- =========================================================================
		-- [DEBUG 3] What part are we processing now?
		-- SHOULD BE (first loop):  Processing part: '-0.5xs'
		-- SHOULD BE (second loop): Processing part: '0.5ys'
		-- =========================================================================

		local xsValue = string.match(part, "^(%-?[%d%.]+)xs$")
		if xsValue then
			-- =====================================================================
			-- [DEBUG 4] Did we extract the correct value?
			print("  [DEBUG 4] Matched xsValue: '" .. xsValue .. "'")
			-- SHOULD BE (first loop): Matched xsValue: '-0.5'
			-- =====================================================================
			xScale = xScale + tonumber(xsValue)
		end

		local xoValue = string.match(part, "^(%-?[%d%.]+)xo$")
		if xoValue then xOffset = xOffset + tonumber(xoValue) end

		local ysValue = string.match(part, "^(%-?[%d%.]+)ys$")
		if ysValue then
			-- =====================================================================
			-- [DEBUG 4] Did we extract the correct value?
			-- SHOULD BE (second loop): Matched ysValue: '0.5'
			-- =====================================================================
			yScale = yScale + tonumber(ysValue)
		end

		local yoValue = string.match(part, "^(%-?[%d%.]+)yo$")
		if yoValue then yOffset = yOffset + tonumber(yoValue) end
	end

	-- =========================================================================
	-- [DEBUG 5] What are the final values before creating the UDim2?
	-- SHOULD BE: Final computed values (xS, xO, yS, yO): -0.5  0  0.5  0
	-- =========================================================================

	if isVector2 then
		return Vector2.new(xScale, yScale)
	else
		return UDim2.new(xScale, xOffset, yScale, yOffset)
	end
end

-- ============================================
-- RELATIVE OPERATIONS IMPLEMENTATION
-- ============================================

-- Check if a utility class is a relative operation
local function isRelativeOperation(class)
	for prefix, config in pairs(AttrConfig) do
		if config.target == "gui" or config.target:match("^UI") then
			if string.match(class, "^" .. prefix .. "%-add%-") or
				string.match(class, "^" .. prefix .. "%-sub%-") or
				string.match(class, "^" .. prefix .. "%-mult%-") or
				string.match(class, "^" .. prefix .. "%-div%-") then
				return true
			end
		end
	end
	return false
end

-- Parse a relative operation to get its components
local function parseRelativeOperation(class)
	for prefix, config in pairs(AttrConfig) do
		if config.target == "gui" or config.target:match("^UI") then
			local addMatch = string.match(class, "^" .. prefix .. "%-add%-(.+)$")
			if addMatch then
				return prefix, "add", addMatch
			end

			local subMatch = string.match(class, "^" .. prefix .. "%-sub%-(.+)$")
			if subMatch then
				return prefix, "sub", subMatch
			end

			local multMatch = string.match(class, "^" .. prefix .. "%-mult%-(.+)$")
			if multMatch then
				return prefix, "mult", multMatch
			end

			local divMatch = string.match(class, "^" .. prefix .. "%-div%-(.+)$")
			if divMatch then
				return prefix, "div", divMatch
			end
		end
	end
	return nil, nil, nil
end

-- Convert a value back to utility class format
local function convertValueToUtilityClass(prefix, value)
	local config = AttrConfig[prefix]
	if not config then return nil end

	if config.parser == "position" then
		-- UDim2 to utility class
		return string.format("%s-%g-%g-%g-%g", prefix, value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
	elseif config.parser == "vector2" then
		-- Vector2 to utility class
		return string.format("%s-%g-%g", prefix, value.X, value.Y)
	elseif config.parser == "udim" then
		-- UDim to utility class
		return string.format("%s-%g-%g", prefix, value.Scale, value.Offset)
	elseif config.parser == "number" or config.parser == "rotation" then
		-- Number to utility class
		return string.format("%s-%g", prefix, value)
	end

	return nil
end

-- Perform mathematical operation on values
local function performOperation(baseValue, operandStr, operation, config)
	local operandValue

	-- Parse the operand based on the property type
	if config.parser == "position" then
		if operation == "add" or operation == "sub" then
			operandValue = parsePositionSequence(operandStr, false)
			if not operandValue then
				warn("xenimation: Could not parse operand for position operation: " .. operandStr)
				return nil
			end

			if operation == "add" then
				return UDim2.new(
					baseValue.X.Scale + operandValue.X.Scale,
					baseValue.X.Offset + operandValue.X.Offset,
					baseValue.Y.Scale + operandValue.Y.Scale,
					baseValue.Y.Offset + operandValue.Y.Offset
				)
			else -- sub
				return UDim2.new(
					baseValue.X.Scale - operandValue.X.Scale,
					baseValue.X.Offset - operandValue.X.Offset,
					baseValue.Y.Scale - operandValue.Y.Scale,
					baseValue.Y.Offset - operandValue.Y.Offset
				)
			end
		else -- mult or div
			local multiplier = tonumber(operandStr)
			if not multiplier then
				warn("xenimation: mult/div operations require a number operand")
				return nil
			end
			if operation == "div" and multiplier == 0 then
				warn("xenimation: Division by zero")
				return nil
			end
			local factor = operation == "mult" and multiplier or (1 / multiplier)
			return UDim2.new(
				baseValue.X.Scale * factor,
				baseValue.X.Offset * factor,
				baseValue.Y.Scale * factor,
				baseValue.Y.Offset * factor
			)
		end

	elseif config.parser == "vector2" then
		if operation == "add" or operation == "sub" then
			operandValue = parseVector2Sequence(operandStr)
			if not operandValue then
				warn("xenimation: Could not parse operand for vector2 operation: " .. operandStr)
				return nil
			end

			if operation == "add" then
				return Vector2.new(baseValue.X + operandValue.X, baseValue.Y + operandValue.Y)
			else -- sub
				return Vector2.new(baseValue.X - operandValue.X, baseValue.Y - operandValue.Y)
			end
		else -- mult or div
			local multiplier = tonumber(operandStr)
			if not multiplier then
				warn("xenimation: mult/div operations require a number operand")
				return nil
			end
			if operation == "div" and multiplier == 0 then
				warn("xenimation: Division by zero")
				return nil
			end
			local factor = operation == "mult" and multiplier or (1 / multiplier)
			return Vector2.new(baseValue.X * factor, baseValue.Y * factor)
		end

	elseif config.parser == "udim" then
		if operation == "add" or operation == "sub" then
			operandValue = parseUDimSequence(operandStr)
			if not operandValue then
				warn("xenimation: Could not parse operand for udim operation: " .. operandStr)
				return nil
			end

			if operation == "add" then
				return UDim.new(baseValue.Scale + operandValue.Scale, baseValue.Offset + operandValue.Offset)
			else -- sub
				return UDim.new(baseValue.Scale - operandValue.Scale, baseValue.Offset - operandValue.Offset)
			end
		else -- mult or div
			local multiplier = tonumber(operandStr)
			if not multiplier then
				warn("xenimation: mult/div operations require a number operand")
				return nil
			end
			if operation == "div" and multiplier == 0 then
				warn("xenimation: Division by zero")
				return nil
			end
			local factor = operation == "mult" and multiplier or (1 / multiplier)
			return UDim.new(baseValue.Scale * factor, baseValue.Offset * factor)
		end

	elseif config.parser == "number" or config.parser == "rotation" then
		operandValue = tonumber(operandStr)
		if not operandValue then
			warn("xenimation: Could not parse number operand: " .. operandStr)
			return nil
		end

		if operation == "add" then
			return baseValue + operandValue
		elseif operation == "sub" then
			return baseValue - operandValue
		elseif operation == "mult" then
			return baseValue * operandValue
		elseif operation == "div" then
			if operandValue == 0 then
				warn("xenimation: Division by zero")
				return nil
			end
			return baseValue / operandValue
		end
	end

	return nil
end

-- Get base value from opposite state or fallback
local function getBaseValueForProperty(prefix, oppositeClasses, animationObject)
	local config = AttrConfig[prefix]
	if not config then return nil end

	-- Find last occurrence of this property in opposite state
	local lastValue = nil
	for class in string.gmatch(oppositeClasses, "%S+") do
		-- Skip relative operations
		if not isRelativeOperation(class) then
			-- Check for explicit value
			if config.parser == "position" then
				local sequence = string.match(class, "^" .. prefix .. "%-(.+)$")
				if sequence then
					local parsed = parsePositionSequence(sequence, false)
					if parsed then lastValue = parsed end
				end
			elseif config.parser == "vector2" then
				local sequence = string.match(class, "^" .. prefix .. "%-(.+)$")
				if sequence then
					local parsed = parseVector2Sequence(sequence)
					if parsed then lastValue = parsed end
				end
			elseif config.parser == "udim" then
				local sequence = string.match(class, "^" .. prefix .. "%-(.+)$")
				if sequence then
					local parsed = parseUDimSequence(sequence)
					if parsed then lastValue = parsed end
				end
			elseif config.parser == "number" or config.parser == "rotation" then
				local value = string.match(class, "^" .. prefix .. "%-([%d%.%-]+)$")
				if value then
					lastValue = tonumber(value)
				end
			end
		end
	end

	-- If found explicit value, return it
	if lastValue then
		return lastValue
	end

	-- Check for "initial" keyword
	if string.find(oppositeClasses, "initial") then
		local initialValue = animationObject:getInitialProperty(prefix)
		if initialValue then
			return initialValue
		end
	end

	-- Fallback to current GUI property
	local guiObject = animationObject.guiObject
	if config.target == "gui" then
		local success, currentValue = pcall(function()
			return guiObject[config.property]
		end)
		if success then
			return currentValue
		end
	elseif config.target:match("^UI") then
		local modifier = guiObject:FindFirstChildOfClass(config.target)
		if modifier then
			local success, currentValue = pcall(function()
				return modifier[config.property]
			end)
			if success then
				return currentValue
			end
		else
			warn("xenimation: No " .. config.target .. " found for relative operation on " .. guiObject.Name)
		end
	end

	return nil
end

-- Check for circular dependencies
local function hasCircularDependency(activeClasses, inactiveClasses)
	local activeRelativeProps = {}
	local inactiveRelativeProps = {}

	-- Collect relative operation properties in each state
	for class in string.gmatch(activeClasses, "%S+") do
		if isRelativeOperation(class) then
			local prefix = parseRelativeOperation(class)
			if prefix then
				activeRelativeProps[prefix] = true
			end
		end
	end

	for class in string.gmatch(inactiveClasses, "%S+") do
		if isRelativeOperation(class) then
			local prefix = parseRelativeOperation(class)
			if prefix then
				inactiveRelativeProps[prefix] = true
			end
		end
	end

	-- Check for overlap (circular dependency)
	for prop in pairs(activeRelativeProps) do
		if inactiveRelativeProps[prop] then
			return true, prop
		end
	end

	return false, nil
end

-- Main function to resolve relative operations
local function resolveRelativeOperations(activeClasses, inactiveClasses, animationObject)
	-- Check for circular dependencies
	local hasCircular, circularProp = hasCircularDependency(activeClasses, inactiveClasses)
	if hasCircular then
		warn("xenimation: Circular dependency detected for property '" .. circularProp .. "' - both states use relative operations")
		return activeClasses, inactiveClasses
	end

	-- Process active state relative operations
	local newActiveClasses = ""
	for class in string.gmatch(activeClasses, "%S+") do
		if isRelativeOperation(class) then
			local prefix, operation, operandStr = parseRelativeOperation(class)
			if prefix then
				local config = AttrConfig[prefix]
				if config and config.parser ~= "color" then -- Skip color operations
					-- Get base value from inactive state
					local baseValue = getBaseValueForProperty(prefix, inactiveClasses, animationObject)
					if baseValue then
						local result = performOperation(baseValue, operandStr, operation, config)
						if result then
							local utilityClass = convertValueToUtilityClass(prefix, result)
							if utilityClass then
								newActiveClasses = newActiveClasses .. " " .. utilityClass
							else
								newActiveClasses = newActiveClasses .. " " .. class
							end
						else
							newActiveClasses = newActiveClasses .. " " .. class
						end
					else
						newActiveClasses = newActiveClasses .. " " .. class
					end
				else
					newActiveClasses = newActiveClasses .. " " .. class
				end
			else
				newActiveClasses = newActiveClasses .. " " .. class
			end
		else
			newActiveClasses = newActiveClasses .. " " .. class
		end
	end

	-- Process inactive state relative operations
	local newInactiveClasses = ""
	for class in string.gmatch(inactiveClasses, "%S+") do
		if isRelativeOperation(class) then
			local prefix, operation, operandStr = parseRelativeOperation(class)
			if prefix then
				local config = AttrConfig[prefix]
				if config and config.parser ~= "color" then -- Skip color operations
					-- Get base value from active state
					local baseValue = getBaseValueForProperty(prefix, activeClasses, animationObject)
					if baseValue then
						local result = performOperation(baseValue, operandStr, operation, config)
						if result then
							local utilityClass = convertValueToUtilityClass(prefix, result)
							if utilityClass then
								newInactiveClasses = newInactiveClasses .. " " .. utilityClass
							else
								newInactiveClasses = newInactiveClasses .. " " .. class
							end
						else
							newInactiveClasses = newInactiveClasses .. " " .. class
						end
					else
						newInactiveClasses = newInactiveClasses .. " " .. class
					end
				else
					newInactiveClasses = newInactiveClasses .. " " .. class
				end
			else
				newInactiveClasses = newInactiveClasses .. " " .. class
			end
		else
			newInactiveClasses = newInactiveClasses .. " " .. class
		end
	end

	return newActiveClasses:match("^%s*(.-)%s*$"), newInactiveClasses:match("^%s*(.-)%s*$")
end

-- Cache for parsed utility classes (excluding "initial")
local utilityClassCache = {}
local cacheStats = {hits = 0, misses = 0, initialSkips = 0}

-- Separate function to handle "initial" properties (can't be cached)
local function applyInitialProperties(properties, animationObject)
	if animationObject and animationObject:hasInitialProperties() then
		for propertyName, value in pairs(animationObject.animationData.initialProperties) do
			properties[propertyName] = value
		end
	else
		warn("xenimation: 'initial' used but no initial properties captured for animation '" .. animationObject:getAnimationId() .. "' on " .. animationObject.guiObject.Name)
	end
end

-- Core parsing logic (extracted for cleaner caching)
local function parseUtilityString(utilityString: string)
	local properties = {}

	for class in string.gmatch(utilityString, "%S+") do
		-- Skip "initial" - it's handled separately
		if class == "initial" then
			continue
		end

		-- Parse using config
		for prefix, config in pairs(AttrConfig) do
			if config.target == "special" then
				-- Skip special cases
			elseif config.parser == "position" then
				local sequence = string.match(class, "^" .. prefix .. "%-(.+)$")
				if sequence then
					local result = parsePositionSequence(sequence, config.isVector2 or false)
					if result then
						properties[prefix] = result
					end
				end
			elseif config.parser == "vector2" then
				local sequence = string.match(class, "^" .. prefix .. "%-(.+)$")
				if sequence then
					local result = parseVector2Sequence(sequence)
					if result then
						properties[prefix] = result
					end
				end
			elseif config.parser == "udim" then
				local sequence = string.match(class, "^" .. prefix .. "%-(.+)$")
				if sequence then
					local result = parseUDimSequence(sequence)
					if result then
						properties[prefix] = result
					end
				end
			elseif config.parser == "rotation" then
				-- Direct rotation (rot-45, rot--45)
				local directRotation = string.match(class, "^" .. prefix .. "%-%-?(%d+)$")
				if directRotation then
					local rotation = tonumber(directRotation)
					if string.match(class, "^" .. prefix .. "%-%-") then
						rotation = -rotation
					end
					properties[prefix] = rotation
				else
					-- Directional rotation (rot-cw-90, rot-ccw-45)
					local direction, degrees = string.match(class, "^" .. prefix .. "%-([a-z]+)%-(%d+)$")
					if direction and degrees then
						local rotation = tonumber(degrees)
						if direction == "ccw" then
							rotation = -rotation
						end
						properties[prefix] = rotation
					end
				end
			elseif config.parser == "color" then
				local colorName, intensity = string.match(class, "^" .. prefix .. "%-([a-z]+)%-([%d%.]+)$")
				if colorName and intensity then
					local color = getColorWithIntensity(colorName, tonumber(intensity))
					if color then
						properties[prefix] = color
					end
				end
			elseif config.parser == "number" then
				local value = string.match(class, "^" .. prefix .. "%-([%d%.]+)$")
				if value then
					properties[prefix] = tonumber(value)
				end
			elseif config.parser == "duration" then
				local value = string.match(class, "^" .. prefix .. "%-([%d%.]+)$")
				if value then
					properties[config.property] = tonumber(value)
				elseif class == prefix .. "-xs" then
					properties[config.property] = 0.1
				elseif class == prefix .. "-sm" then
					properties[config.property] = 0.2
				elseif class == prefix .. "-md" then
					properties[config.property] = 0.3
				elseif class == prefix .. "-lg" then
					properties[config.property] = 0.5
				elseif class == prefix .. "-xl" then
					properties[config.property] = 0.8
				end
			elseif config.value and class == prefix then
				-- Handle exact matches for easing styles/directions
				properties[config.property] = config.value
			end
		end
	end

	return properties
end

local function parseUtilityClasses(utilityString: string, animationObject: any)
	if not utilityString or utilityString == "" then
		return {}
	end

	local hasInitial = string.find(utilityString, "initial")

	-- If no "initial", we can use pure caching
	if not hasInitial then
		local cached = utilityClassCache[utilityString]
		if cached then
			cacheStats.hits += 1
			return table.clone(cached) -- Clone to prevent external mutation
		end

		-- Cache miss - parse and cache
		cacheStats.misses += 1
		local properties = parseUtilityString(utilityString)
		utilityClassCache[utilityString] = table.clone(properties) -- Cache a clean copy
		return properties
	end

	-- Has "initial" - need special handling
	cacheStats.initialSkips += 1

	-- Try to cache the non-initial parts
	local cleanString = string.gsub(utilityString, "%s*initial%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")

	local baseProperties
	if cleanString ~= "" then
		local cached = utilityClassCache[cleanString]
		if cached then
			baseProperties = table.clone(cached)
		else
			baseProperties = parseUtilityString(cleanString)
			utilityClassCache[cleanString] = table.clone(baseProperties)
		end
	else
		baseProperties = {}
	end

	-- Apply initial properties
	applyInitialProperties(baseProperties, animationObject)

	return baseProperties
end

-- Optional: Function to get cache statistics for debugging
local function getCacheStats()
	local total = cacheStats.hits + cacheStats.misses + cacheStats.initialSkips
	if total == 0 then return "No cache usage yet" end

	local hitRate = math.floor((cacheStats.hits / total) * 100)
	return string.format(
		"Cache: %d%% hit rate (%d hits, %d misses, %d initial skips, %d total)",
		hitRate, cacheStats.hits, cacheStats.misses, cacheStats.initialSkips, total
	)
end

-- Optional: Function to clear cache (useful for memory management)
local function clearUtilityCache()
	local count = 0
	for _ in pairs(utilityClassCache) do count += 1 end
	utilityClassCache = {}
	cacheStats = {hits = 0, misses = 0, initialSkips = 0}
	print("Cleared utility cache (" .. count .. " entries)")
end

local function buildAnimationProperties(config, animationObject)
	local activeClasses = ""
	local inactiveClasses = ""

	-- Build class strings with presets first (so explicit values override)
	if config.preset then
		for presetName in string.gmatch(config.preset, "%S+") do
			local preset = presets[presetName]
			if preset then
				activeClasses = activeClasses .. " " .. (preset.Active or "")
				inactiveClasses = inactiveClasses .. " " .. (preset.Inactive or "")
			end
		end
	end

	-- Add explicit values after presets (so they override)
	activeClasses = activeClasses .. " " .. (config.active or "")
	inactiveClasses = inactiveClasses .. " " .. (config.inactive or "")

	-- Resolve relative operations BEFORE parsing
	activeClasses, inactiveClasses = resolveRelativeOperations(
		activeClasses,
		inactiveClasses,
		animationObject
	)

	return {
		active = parseUtilityClasses(activeClasses, animationObject),
		inactive = parseUtilityClasses(inactiveClasses, animationObject)
	}
end

-- Helper function to find Animation object for a specific animationId on a GuiObject
--[[
If gui object is a gui object, first check to see if that guiObject has the animationId
If it does not have that animationid, check configurations until it has one

If guiobject is a configuration, first check to see if that configuration has th
]]
local function findAnimationObjectForId(object: GuiObject | Configuration, animationId: string)
	--Can be a tab, page, hover, or animation
	if (animationId == "default" and TagService:GetApplied("Animation", object)) or object:GetAttribute("AnimationId") == animationId then
		return TagService:GetApplied("Animation", object)
	end
	
	local host = object
	if object:IsA("Configuration") then
		host = object.Parent
	end 
	
	if host:GetAttribute("AnimationId") == animationId then
		return TagService:GetApplied("Animation", object)
	end
	
	for _, instance in host:GetChildren() do
		if instance:IsA("Configuration") and instance:HasTag("Animation") and instance:GetAttribute("AnimationId") == animationId then
			return TagService:GetApplied("Animation", instance)
		end
	end
	--[[
	-- Get all Animation objects associated with this GuiObject
	local allAnimations = TagService:GetAllApplied("Animation")

	for instance, animationObject in pairs(allAnimations) do
		-- Check if this Animation object targets our GuiObject and has the right ID
		if animationObject.guiObject == guiObject and animationObject:hasAnimation(animationId) then
			return animationObject
		end
	end

	return nil]]
end

function xenimation:Play(object: GuiObject | Configuration, animationId: string, active: boolean)
	
	-- Use default animation if no animationId specified
	animationId = animationId or DEFAULT_ANIMATION_ID
	-- Find the specific Animation object for this animationId
	local animationObject = findAnimationObjectForId(object, animationId)
	
	if not animationObject then
		return
	end

	local guiObject = animationObject.guiObject

	-- Get animation configuration
	local config = animationObject:getAnimationConfig()
	if not config then
		warn("xenimation: Could not get config for animation '" .. animationId .. "' on " .. object.Name)
		return
	end

	local animationProperties = buildAnimationProperties(config, animationObject)
	local targetState = active and animationProperties.active or animationProperties.inactive

	local animationKey = tostring(guiObject) .. "_" .. animationId

	local tweenableProperties = {}

	for property, value in pairs(targetState) do
		if property == "duration" or property == "easingStyle" or property == "easingDirection" then
			-- Skip tween configuration properties
		else
			tweenableProperties[property] = value
		end
	end

	if next(tweenableProperties) then
		local tweenInfo = TweenInfo.new(
			targetState.duration or 0.3,
			targetState.easingStyle or Enum.EasingStyle.Quad,
			targetState.easingDirection or Enum.EasingDirection.Out
		)

		local robloxProperties = {}
		local modifierTweens = {}

		for property, value in pairs(tweenableProperties) do
			local config = AttrConfig[property]
			if config then
				if config.target == "gui" then
					local success = pcall(function()
						local _ = guiObject[config.property]
					end)

					if success then
						robloxProperties[config.property] = value
					else
						warn("xenimation: " .. config.property .. " not applicable to " .. guiObject.ClassName)
					end
				elseif config.target == "UIScale" then
					local uiScale = guiObject:FindFirstChildOfClass("UIScale")
					if uiScale then
						if not modifierTweens[uiScale] then
							modifierTweens[uiScale] = {}
						end
						modifierTweens[uiScale][config.property] = value
					else
						warn("xenimation: " .. property .. " ignored - no UIScale found on " .. guiObject.Name)
					end
				elseif config.target == "UIStroke" then
					local uiStroke = guiObject:FindFirstChildOfClass("UIStroke")
					if uiStroke then
						if not modifierTweens[uiStroke] then
							modifierTweens[uiStroke] = {}
						end
						modifierTweens[uiStroke][config.property] = value
					else
						warn("xenimation: " .. property .. " ignored - no UIStroke found on " .. guiObject.Name)
					end
				elseif config.target == "UICorner" then
					local uiCorner = guiObject:FindFirstChildOfClass("UICorner")
					if uiCorner then
						if not modifierTweens[uiCorner] then
							modifierTweens[uiCorner] = {}
						end
						modifierTweens[uiCorner][config.property] = value
					else
						warn("xenimation: " .. property .. " ignored - no UICorner found on " .. guiObject.Name)
					end
				elseif config.target == "UIAspectRatioConstraint" then
					local uiAspectRatio = guiObject:FindFirstChildOfClass("UIAspectRatioConstraint")
					if uiAspectRatio then
						if not modifierTweens[uiAspectRatio] then
							modifierTweens[uiAspectRatio] = {}
						end
						modifierTweens[uiAspectRatio][config.property] = value
					else
						warn("xenimation: " .. property .. " ignored - no UIAspectRatioConstraint found on " .. guiObject.Name)
					end
				elseif config.target == "UISizeConstraint" then
					local uiSizeConstraint = guiObject:FindFirstChildOfClass("UISizeConstraint")
					if uiSizeConstraint then
						if not modifierTweens[uiSizeConstraint] then
							modifierTweens[uiSizeConstraint] = {}
						end
						modifierTweens[uiSizeConstraint][config.property] = value
					else
						warn("xenimation: " .. property .. " ignored - no UISizeConstraint found on " .. guiObject.Name)
					end
				elseif config.target == "UITextSizeConstraint" then
					local uiTextSizeConstraint = guiObject:FindFirstChildOfClass("UITextSizeConstraint")
					if uiTextSizeConstraint then
						if not modifierTweens[uiTextSizeConstraint] then
							modifierTweens[uiTextSizeConstraint] = {}
						end
						modifierTweens[uiTextSizeConstraint][config.property] = value
					else
						warn("xenimation: " .. property .. " ignored - no UITextSizeConstraint found on " .. guiObject.Name)
					end
				end
			end
		end

		local tweens = {}

		if next(robloxProperties) then
			local tween = game:GetService("TweenService"):Create(guiObject, tweenInfo, robloxProperties)
			table.insert(tweens, {tween = tween, key = animationKey})
		end

		for modifierObject, modifierProperties in pairs(modifierTweens) do
			local modifierTween = game:GetService("TweenService"):Create(modifierObject, tweenInfo, modifierProperties)
			local modifierKey = animationKey .. "_" .. tostring(modifierObject)
			table.insert(tweens, {tween = modifierTween, key = modifierKey})
		end

		for _, tweenData in pairs(tweens) do
			local tween = tweenData.tween
			local key = tweenData.key

			activeAnimations[key] = tween

			tween.Completed:Connect(function()
				if activeAnimations[key] == tween then
					activeAnimations[key] = nil
				end
			end)

			tween:Play()
		end
	end
end

-- Helper function to get all available animations for a GuiObject
function xenimation:GetAnimations(guiObject: GuiObject)
	local animations = {}
	local allAnimations = TagService:GetAllApplied("Animation")

	for instance, animationObject in pairs(allAnimations) do
		if animationObject.guiObject == guiObject then
			table.insert(animations, animationObject:getAnimationId())
		end
	end

	return animations
end

-- Helper function to check if a specific animation exists
function xenimation:HasAnimation(object: GuiObject | Configuration, animationId: string)
	return findAnimationObjectForId(object, animationId) ~= nil
end

return xenimation
