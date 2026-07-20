--[[
Colour slots for lights (tagged on the models in Assets.Placeables):
  Color1 - the light itself
  Color2 - the metal fitting holding it

Slot numbers are per-object: Color1 on a light is the bulb, not a plant pot. See the
header of Plants.luau for how Palettes entries are read.
]]

return {
	["Test Light"] = {
		Type = "Hanger",
		Palettes = {
			{ Name = "Warm Brass", Colors = { Color3.fromRGB(255, 232, 190), Color3.fromRGB(178, 138, 74) } },
			{ Name = "Cool Steel", Colors = { Color3.fromRGB(222, 238, 255), Color3.fromRGB(148, 154, 160) } },
			{ Name = "Matte Black", Colors = { Color3.fromRGB(255, 244, 222), Color3.fromRGB(38, 38, 40) } },
		},
	},
}
