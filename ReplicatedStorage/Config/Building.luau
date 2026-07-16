--[[
Central constants for the building system. This is the single place to tweak the
grid scale, height options, and ceiling offset - all of it is "set once, rarely
touched again" tuning. Numbers here are the final values from the design doc unless
marked PLACEHOLDER.
]]

local Building = {}

-- Horizontal placement uses CELL_SIZE x CELL_SIZE cells. Vertical build segments use
-- WALL_HEIGHT independently.
Building.CELL_SIZE = 4

-- Every vertical build segment is one fixed-height wall. Build levels are unbounded:
-- level N occupies [(N - 1) * WALL_HEIGHT, N * WALL_HEIGHT] above the plot.
-- A wall's bounding-box bottom rests on the first value and its top reaches the second;
-- a ceiling slab's top surface is placed on the second value.
Building.WALL_HEIGHT = 8

-- Ceiling/floor slab thickness. The slab's TOP is flush with the supporting wall top
-- (which becomes the next build floor's surface); its thickness hangs below that line.
Building.CEILING_THICKNESS = 1

-- Temporary computer controls for the orbiting build camera.
Building.Camera = {
	PanSpeed = 32,
	VerticalSpeed = 16,
	RotateSensitivity = 0.004,
	DefaultYaw = 45,
	DefaultPitch = 45,
	MinPitch = 10,
	MaxPitch = 85,
	DefaultDistance = 40,
	MinDistance = 12,
	MaxDistance = 80,
	ZoomStep = 4,
}

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
