--[[
Colour slots for plants (tagged on the models in Assets.Placeables):
  Color1 - pot
  Color2 - dirt
  Color3 - foliage (leaves, bamboo stalks, cactus body)
  Color4 - woody parts (tree trunk, cactus spikes)

Palettes are per-object on purpose: an object only lists the presets that actually suit
it, and its slots are addressed by its own numbering. Omitted slots keep the model's
authored colour, so a palette can restyle just the pot and leave the dirt alone. The
authored colours are always available as the implicit "default" - don't list them here.
]]

-- Shared pot/dirt bases, since every plant here sits in one.
local TERRACOTTA = Color3.fromRGB(188, 106, 72)
local SLATE_POT = Color3.fromRGB(96, 102, 108)
local CERAMIC = Color3.fromRGB(232, 228, 218)
local DRY_SOIL = Color3.fromRGB(86, 64, 48)
local RICH_SOIL = Color3.fromRGB(54, 40, 31)

return {
	["Bamboo Plant"] = {
		Type = "Content",
		Palettes = {
			{ Name = "Terracotta", Colors = { TERRACOTTA, DRY_SOIL, Color3.fromRGB(120, 168, 84) } },
			{ Name = "Slate", Colors = { SLATE_POT, RICH_SOIL, Color3.fromRGB(78, 130, 96) } },
			{ Name = "Ceramic", Colors = { CERAMIC, RICH_SOIL, Color3.fromRGB(154, 196, 110) } },
		},
	},

	["Potted Cactus"] = {
		Type = "Content",
		Palettes = {
			-- Color4 here is the spikes.
			{ Name = "Terracotta", Colors = { TERRACOTTA, DRY_SOIL, Color3.fromRGB(106, 152, 92), Color3.fromRGB(226, 214, 178) } },
			{ Name = "Desert", Colors = { Color3.fromRGB(206, 166, 116), Color3.fromRGB(150, 122, 88), Color3.fromRGB(132, 170, 106), Color3.fromRGB(240, 232, 204) } },
			{ Name = "Ceramic", Colors = { CERAMIC, RICH_SOIL, Color3.fromRGB(88, 138, 100), Color3.fromRGB(198, 190, 164) } },
		},
	},

	["Potted Plant"] = {
		Type = "Content",
		Palettes = {
			{ Name = "Terracotta", Colors = { TERRACOTTA, DRY_SOIL, Color3.fromRGB(96, 150, 78) } },
			{ Name = "Slate", Colors = { SLATE_POT, RICH_SOIL, Color3.fromRGB(64, 112, 74) } },
			{ Name = "Ceramic", Colors = { CERAMIC, RICH_SOIL, Color3.fromRGB(138, 184, 96) } },
		},
	},

	["Tree Plant"] = {
		Type = "Content",
		Palettes = {
			-- Color4 here is the trunk.
			{ Name = "Terracotta", Colors = { TERRACOTTA, DRY_SOIL, Color3.fromRGB(88, 142, 76), Color3.fromRGB(112, 82, 58) } },
			{ Name = "Slate", Colors = { SLATE_POT, RICH_SOIL, Color3.fromRGB(62, 106, 72), Color3.fromRGB(82, 64, 50) } },
			{ Name = "Autumn", Colors = { TERRACOTTA, DRY_SOIL, Color3.fromRGB(206, 132, 58), Color3.fromRGB(98, 70, 48) } },
		},
	},
}
