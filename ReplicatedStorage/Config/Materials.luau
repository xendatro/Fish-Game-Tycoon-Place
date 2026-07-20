--[[
Material palettes for flooring and ceilings. Each is an ordered list of entries. The
INDEX is the stable id stored in saves, so this list is APPEND-ONLY: never reorder or
remove entries or you'll corrupt existing builds.

Index 1 of Floor is the default ("grass") that every unpainted base cell shows. On
upper floors, grass is stored and rendered like any other selected material. Index 1
of Ceiling is the default ceiling underside.

Each entry carries the Enum.Material name (also its display label) and Color, the
authored default tint an uncoloured cell renders as. A cell's tint is stored per-cell in
the Grid alongside its material and only when it differs from Color, so an unrecoloured
plot serialises exactly as it did before colours existed.

(Roblox MaterialVariants could be layered on here later to expand the palette; for now
these are plain built-in materials.)
]]

return {
	Floor = {
		{ Material = "Grass", Color = Color3.fromRGB(106, 142, 68) },
		{ Material = "WoodPlanks", Color = Color3.fromRGB(154, 112, 72) },
		{ Material = "Concrete", Color = Color3.fromRGB(150, 150, 146) },
		{ Material = "Marble", Color = Color3.fromRGB(226, 224, 218) },
		{ Material = "Pavement", Color = Color3.fromRGB(146, 144, 138) },
		{ Material = "Slate", Color = Color3.fromRGB(96, 104, 112) },
		{ Material = "Sand", Color = Color3.fromRGB(216, 198, 154) },
		{ Material = "Brick", Color = Color3.fromRGB(152, 84, 68) },
	},

	Ceiling = {
		{ Material = "Plaster", Color = Color3.fromRGB(228, 226, 220) },
		{ Material = "WoodPlanks", Color = Color3.fromRGB(154, 112, 72) },
		{ Material = "Concrete", Color = Color3.fromRGB(150, 150, 146) },
		{ Material = "SmoothPlastic", Color = Color3.fromRGB(200, 200, 204) },
	},
}
