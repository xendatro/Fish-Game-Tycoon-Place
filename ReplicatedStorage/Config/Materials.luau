--[[
Material palettes for flooring and ceilings. Each is a simple ordered list of
Enum.Material names. The INDEX is the stable id stored in saves, so this list is
APPEND-ONLY: never reorder or remove entries or you'll corrupt existing builds.

Index 1 of Floor is the default ("grass") that every unpainted base cell shows. On
upper floors, grass is stored and rendered like any other selected material. Index 1
of Ceiling is the default ceiling underside.

(Roblox MaterialVariants could be layered on here later to expand the palette; for now
these are plain built-in materials.)
]]

return {
	Floor = {
		"Grass", -- 1 = implicit on the plot base, explicit on upper floors
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
