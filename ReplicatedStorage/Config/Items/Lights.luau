--[[
Slot numbers are per-object: Color1 on a light is the bulb, not a plant pot. See the
header of Plants.luau for how ColorNames and Palettes are read.
]]

return {
	["Test Light"] = {
		Type = "Hanger",
		ColorNames = { "Light", "Fitting" },
		Palettes = {
			{ Name = "Warm Brass", Colors = { Color3.fromRGB(255, 232, 190), Color3.fromRGB(178, 138, 74) } },
			{ Name = "Cool Steel", Colors = { Color3.fromRGB(222, 238, 255), Color3.fromRGB(148, 154, 160) } },
			{ Name = "Matte Black", Colors = { Color3.fromRGB(255, 244, 222), Color3.fromRGB(38, 38, 40) } },
		},
	},
}
