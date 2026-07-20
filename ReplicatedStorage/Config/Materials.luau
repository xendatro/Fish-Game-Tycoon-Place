--[[
Material palettes for flooring and ceilings. Each is an ordered list of entries. The
INDEX is the stable id stored in saves, so this list is APPEND-ONLY: never reorder or
remove entries or you'll corrupt existing builds.

Index 1 of Floor is the default ("grass") that every unpainted base cell shows. On
upper floors, grass is stored and rendered like any other selected material. Index 1
of Ceiling is the default ceiling underside.

Each entry carries:
  Material - the Enum.Material name, also used as the display label.
  Color    - the authored default tint, i.e. what an uncoloured cell renders as.
  Palettes - optional presets for that material, mirroring the per-object palettes in
             Config/Items. A floor or ceiling tile has exactly one colourable surface,
             so a palette here is a single colour rather than a slot map.

A cell's colour is stored per-cell in the Grid alongside its material, and only when it
differs from Color - an unrecoloured plot serialises exactly as it did before colours
existed. Editing a palette never touches existing builds, since palettes resolve to
concrete colours the moment they're applied.

(Roblox MaterialVariants could be layered on here later to expand the palette; for now
these are plain built-in materials.)
]]

return {
	Floor = {
		{
			Material = "Grass", -- 1 = implicit on the plot base, explicit on upper floors
			Color = Color3.fromRGB(106, 142, 68),
			Palettes = {
				{ Name = "Meadow", Color = Color3.fromRGB(124, 168, 78) },
				{ Name = "Deep", Color = Color3.fromRGB(70, 104, 54) },
				{ Name = "Dry", Color = Color3.fromRGB(160, 158, 90) },
			},
		},
		{
			Material = "WoodPlanks",
			Color = Color3.fromRGB(154, 112, 72),
			Palettes = {
				{ Name = "Oak", Color = Color3.fromRGB(186, 146, 96) },
				{ Name = "Walnut", Color = Color3.fromRGB(102, 72, 48) },
				{ Name = "Driftwood", Color = Color3.fromRGB(178, 172, 158) },
			},
		},
		{
			Material = "Concrete",
			Color = Color3.fromRGB(150, 150, 146),
			Palettes = {
				{ Name = "Pale", Color = Color3.fromRGB(196, 196, 190) },
				{ Name = "Charcoal", Color = Color3.fromRGB(88, 90, 92) },
			},
		},
		{
			Material = "Marble",
			Color = Color3.fromRGB(226, 224, 218),
			Palettes = {
				{ Name = "Carrara", Color = Color3.fromRGB(238, 238, 234) },
				{ Name = "Rose", Color = Color3.fromRGB(226, 200, 196) },
				{ Name = "Noir", Color = Color3.fromRGB(64, 62, 66) },
			},
		},
		{
			Material = "Pavement",
			Color = Color3.fromRGB(146, 144, 138),
			Palettes = {
				{ Name = "Ash", Color = Color3.fromRGB(178, 176, 170) },
				{ Name = "Basalt", Color = Color3.fromRGB(84, 84, 86) },
			},
		},
		{
			Material = "Slate",
			Color = Color3.fromRGB(96, 104, 112),
			Palettes = {
				{ Name = "Storm", Color = Color3.fromRGB(74, 84, 96) },
				{ Name = "Sea", Color = Color3.fromRGB(84, 116, 118) },
			},
		},
		{
			Material = "Sand",
			Color = Color3.fromRGB(216, 198, 154),
			Palettes = {
				{ Name = "Shore", Color = Color3.fromRGB(232, 218, 184) },
				{ Name = "Dune", Color = Color3.fromRGB(196, 168, 118) },
			},
		},
		{
			Material = "Brick",
			Color = Color3.fromRGB(152, 84, 68),
			Palettes = {
				{ Name = "Terracotta", Color = Color3.fromRGB(184, 102, 74) },
				{ Name = "Umber", Color = Color3.fromRGB(108, 62, 52) },
				{ Name = "Whitewash", Color = Color3.fromRGB(206, 190, 180) },
			},
		},
	},

	Ceiling = {
		{
			Material = "Plaster", -- 1 = default ceiling underside
			Color = Color3.fromRGB(228, 226, 220),
			Palettes = {
				{ Name = "Chalk", Color = Color3.fromRGB(240, 240, 236) },
				{ Name = "Warm", Color = Color3.fromRGB(232, 220, 200) },
				{ Name = "Shadow", Color = Color3.fromRGB(176, 176, 178) },
			},
		},
		{
			Material = "WoodPlanks",
			Color = Color3.fromRGB(154, 112, 72),
			Palettes = {
				{ Name = "Oak", Color = Color3.fromRGB(186, 146, 96) },
				{ Name = "Walnut", Color = Color3.fromRGB(102, 72, 48) },
			},
		},
		{
			Material = "Concrete",
			Color = Color3.fromRGB(150, 150, 146),
			Palettes = {
				{ Name = "Pale", Color = Color3.fromRGB(196, 196, 190) },
				{ Name = "Charcoal", Color = Color3.fromRGB(88, 90, 92) },
			},
		},
		{
			Material = "SmoothPlastic",
			Color = Color3.fromRGB(200, 200, 204),
			Palettes = {
				{ Name = "White", Color = Color3.fromRGB(242, 242, 244) },
				{ Name = "Sky", Color = Color3.fromRGB(168, 200, 226) },
				{ Name = "Ink", Color = Color3.fromRGB(52, 54, 62) },
			},
		},
	},
}
