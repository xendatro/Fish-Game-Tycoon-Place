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

-- Ceiling/floor slab thickness. The slab's top is flush with the selected level top
-- (which becomes the next build floor's surface); its thickness hangs below that line.
Building.CEILING_THICKNESS = 1

-- Floor surfaces overlap their supporting plot or ceiling by half their thickness, so
-- only this small offset shows above it. This prevents z-fighting without raising builds.
Building.FLOOR_THICKNESS = 0.02
Building.FLOOR_SURFACE_OFFSET = 0.01
Building.SHOW_GRID_DURING_DELETE_DRAG = false

-- Parts above the active build-camera floor remain visible but do not block build
-- raycasts. Roblox transparency uses 0 = opaque and 1 = invisible.
Building.HIDDEN_FLOOR_TRANSPARENCY = 0.75

-- Undo history is server-authoritative but session-only. Each entry stores only the
-- cells or placements changed by one click/drag, rather than a full plot snapshot.
Building.UNDO_HISTORY_LIMIT = 50

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

-- Colour customisation. A placeable declares its recolourable groups by tagging parts
-- `Color1` .. `Color{COLOR_SLOTS}`; the authored colour of those parts is that slot's
-- default. What each slot MEANS is per-object (on a plant Color1 is the pot, on a light
-- it's the bulb), so preset palettes live in each item's Config/Items entry rather than
-- in a global list. See SharedColorService.
-- Raising COLOR_SLOTS is safe; lowering it orphans colours already saved on dropped slots.
Building.COLOR_SLOTS = 5
Building.COLOR_TAG_PREFIX = "Color"

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
