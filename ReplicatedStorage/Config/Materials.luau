--[[
Material palettes for flooring and ceilings. Each is a simple ordered list of
Enum.Material names. The INDEX is the stable id stored in saves, so this list is
APPEND-ONLY: never reorder or remove entries or you'll corrupt existing builds.

Index 1 of Floor is the default ("grass") that every un-painted base cell shows, so
painting a cell to material 1 is the same as reverting it to grass. Index 1 of Ceiling
is the default ceiling underside.

(Roblox MaterialVariants could be layered on here later to expand the palette; for now
these are plain built-in materials.)
]]

return {
	Floor = {
		"Grass", -- 1 = default / revert target
		"WoodPlanks",
		"Concrete",
		"Marble",
		"Pavement",
		"Slate",
		"Sand",
		"Brick",
	},

	Ceiling = {
		"Plaster", -- 1 = default ceiling underside
		"WoodPlanks",
		"Concrete",
		"SmoothPlastic",
	},
}
