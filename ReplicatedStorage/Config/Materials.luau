--[[
Material palettes for flooring and ceilings. Each is an ordered list of entries. The
INDEX is the stable id stored in saves, so this list is APPEND-ONLY: never reorder or
remove entries or you'll corrupt existing builds.

Index 1 of Floor is the default ("grass") that every unpainted base cell shows. Upper
floors inherit the material and colour of their supporting ceiling until painted. Each
ceiling entry points at the matching floor material so both faces start out identical.

Each entry carries the Enum.Material name (also its display label) and Color, the
authored default tint an uncoloured cell renders as. A cell's tint is stored per-cell in
the Grid alongside its material and only when it differs from Color, so an unrecoloured
plot serialises exactly as it did before colours existed.

Floor entries also carry Weight: how strongly guests prefer to walk on them. Pathing cost
to enter a cell is its step length divided by this, so a Weight of 4 makes a cell feel a
quarter as far as bare grass and guests naturally follow laid paths instead of cutting
across the lawn. It never makes a cell impassable - a guest with no other option still
crosses grass. Omitting it falls back to Config.Npc's Nav.DefaultWeight (see
SharedNpcService).

(Roblox MaterialVariants could be layered on here later to expand the palette; for now
these are plain built-in materials.)
]]

return {
	Floor = {
		{ Material = "Grass", Color = Color3.fromRGB(106, 142, 68), Weight = 1 },
		{ Material = "WoodPlanks", Color = Color3.fromRGB(154, 112, 72), Weight = 4 },
		{ Material = "Concrete", Color = Color3.fromRGB(150, 150, 146), Weight = 4 },
		{ Material = "Marble", Color = Color3.fromRGB(226, 224, 218), Weight = 5 },
		{ Material = "Pavement", Color = Color3.fromRGB(146, 144, 138), Weight = 5 },
		{ Material = "Slate", Color = Color3.fromRGB(96, 104, 112), Weight = 4 },
		{ Material = "Sand", Color = Color3.fromRGB(216, 198, 154), Weight = 1.5 },
		{ Material = "Brick", Color = Color3.fromRGB(152, 84, 68), Weight = 4 },
		{ Material = "Plaster", Color = Color3.fromRGB(228, 226, 220), Hidden = true, Weight = 3 },
		{ Material = "SmoothPlastic", Color = Color3.fromRGB(200, 200, 204), Hidden = true, Weight = 3 },
	},

	Ceiling = {
		{ Material = "Plaster", Color = Color3.fromRGB(228, 226, 220), FloorMaterial = 9 },
		{ Material = "WoodPlanks", Color = Color3.fromRGB(154, 112, 72), FloorMaterial = 2 },
		{ Material = "Concrete", Color = Color3.fromRGB(150, 150, 146), FloorMaterial = 3 },
		{ Material = "SmoothPlastic", Color = Color3.fromRGB(200, 200, 204), FloorMaterial = 10 },
	},
}
