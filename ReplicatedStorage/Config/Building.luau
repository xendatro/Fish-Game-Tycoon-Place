--[[
Central constants for the building system. This is the single place to tweak the
grid scale, height options, and ceiling offset - all of it is "set once, rarely
touched again" tuning. Numbers here are the final values from the design doc unless
marked PLACEHOLDER.
]]

local Building = {}

-- One grid cell is CELL_SIZE x CELL_SIZE x CELL_SIZE studs. (Design doc: 4x4x4.)
Building.CELL_SIZE = 4

-- Extendable assets (walls, stairs) come in 4 discrete height levels. A level of n
-- is n cells tall. Stored explicitly (rather than n * CELL_SIZE) so it can be made
-- non-linear later without touching callers.
Building.HEIGHT_STUDS = {
	[1] = 4,
	[2] = 8,
	[3] = 12,
	[4] = 16,
}
Building.MAX_HEIGHT_LEVEL = 4

-- Ceiling/floor slab thickness. The slab's TOP is flush with the supporting wall top
-- (which becomes the next build floor's surface); its thickness hangs below that line.
Building.CEILING_THICKNESS = 1

-- Number of buildable floors. Floor 2 lives at variable heights (determined by the
-- walls/stairs beneath it), but it is still a single logical floor index.
Building.FLOOR_COUNT = 2

-- Rotation is in 90-degree increments, stored as 0..3.
Building.ROTATION_STEPS = 4

-- The base grid defaults to grass; cells are only stored in the save when they
-- differ from this, keeping empty plots nearly free to serialize.
Building.DEFAULT_FLOOR_MATERIAL = "Grass"

--[[
Grid origin convention (defined here so it's predictable and in one place):
  - The grid is anchored at the minimum-XZ corner of the plot's base "Plot" part.
  - Cell (x, z) uses 0-based integer coordinates increasing along +X and +Z.
  - A cell's CENTER (the rotation pivot) is at:
        origin + Vector3.new((x + 0.5) * CELL_SIZE, y, (z + 0.5) * CELL_SIZE)
  - Walls sit on cell EDGES (perimeter lines), not centers - see Grid's edge layer.
]]

return Building
