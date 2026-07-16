--[[
Grid - the runtime spatial occupancy structure for a single plot's build area.

There are two occupancy layers:
  * Cell layer  - content assets, ceilings, flooring. Keyed per 3D cell (x, z, floor).
  * Edge layer  - walls only. Keyed per perimeter edge between cells.

The Grid is deliberately a "dumb" structure: it stores what occupies where and
answers free/occupied queries in O(1) via reverse indexes. It does NOT know about
the catalog, footprints, money, or rendering - callers (the building services)
compute a placement's occupied cells/edges and hand them in. This keeps the Grid
free of dependencies (only the Building config) and usable on both client and server.

Compress()/Decompress() convert to and from the compact save blob that lives in the
player's profile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Building = require(ReplicatedStorage.Config.Building)

local Grid = {}
Grid.__index = Grid

-- A single placed thing. Cells/Edges are the runtime-derived occupancy and are NOT
-- saved (Decompress rebuilds them via the caller's resolver).
export type Placement = {
	Id: number,
	Name: string, -- catalog entry name
	X: number,
	Z: number,
	Floor: number, -- unbounded 1-based build level
	Rotation: number, -- 0..3
	Cells: { string }, -- occupied cell keys (empty for pure-wall placements)
	Edges: { string }, -- occupied edge keys (empty for non-wall placements)
}

-- The compact per-placement tuple actually written to the save (see Compress).
export type SavedPlacement = { number } -- {paletteIndex, x, z, floor, rot}
-- Painted floor material (index into Config.Materials.Floor), per floor + cell. Grass
-- is implicit on the plot base but stored when explicitly painted on an upper floor.
export type FloorEntry = { Floor: number, X: number, Z: number, Material: number }
-- A ceiling capping one build floor at a cell. TopOffset is its top surface's height
-- above Origin.Y; each ceiling can become the surface for the next build level.
export type CeilingEntry = { Floor: number, X: number, Z: number, TopOffset: number, Material: number }

export type SaveBlob = {
	Palette: { string },
	Placements: { SavedPlacement },
	Floors: { { number } }, -- {floor, x, z, materialIndex}
	Ceilings: { { number } }, -- {floor, x, z, topOffsetStuds, materialIndex}
}

export type Grid = typeof(setmetatable(
	{} :: {
		Origin: Vector3,
		Width: number, -- cells along +X
		Depth: number, -- cells along +Z
		_placements: { [number]: Placement },
		_cellIndex: { [string]: number }, -- cell key -> placement id
		_edgeIndex: { [string]: number }, -- edge key -> placement id
		_floors: { [string]: FloorEntry }, -- cell key -> painted floor material
		_ceilings: { [string]: CeilingEntry }, -- "floor:x,z" -> ceiling
		_nextId: number,
	},
	Grid
))

-- ===== Key helpers (static) =================================================

--[[Canonical key for a 3D cell.]]
function Grid.cellKey(x: number, z: number, floor: number): string
	return `{floor}:{x},{z}`
end

--[[
Canonical key for a wall edge. An edge is a perimeter line of a cell:
  * "H" edges run along X and separate the row at z from the row at z-1.
  * "V" edges run along Z and separate the column at x from the column at x-1.
Because a given line is shared by two neighbouring cells, we always key it by the
higher-coordinate cell so the wall between two cells is one entry, not two.
]]
function Grid.edgeKey(orientation: "H" | "V", x: number, z: number, floor: number): string
	return `{floor}:{orientation}:{x},{z}`
end

-- ===== Construction =========================================================

--[[
Creates an empty Grid sized from a base part (the plot's "Plot" part). Dimensions
are derived by rounding the part's size to whole cells, so slightly-imperfect
models still resolve to a clean cell count.
]]
function Grid.new(basePart: BasePart): Grid
	local self = setmetatable({}, Grid)

	local size = basePart.Size
	self.Width = math.max(1, math.round(size.X / Building.CELL_SIZE))
	self.Depth = math.max(1, math.round(size.Z / Building.CELL_SIZE))

	-- Minimum-XZ corner of the top surface = grid origin (see Building doc comment).
	self.Origin = basePart.Position
		- Vector3.new(size.X / 2, -size.Y / 2, size.Z / 2)

	self._placements = {}
	self._cellIndex = {}
	self._edgeIndex = {}
	self._floors = {}
	self._ceilings = {}
	self._nextId = 1

	return self
end

-- ===== World-space helpers ==================================================

--[[Returns the world-space center of a cell on the plot base. The render layer adds
the selected build level's fixed vertical offset.]]
function Grid:GetCellCenter(x: number, z: number): Vector3
	local cell = Building.CELL_SIZE
	return self.Origin + Vector3.new((x + 0.5) * cell, 0, (z + 0.5) * cell)
end

--[[Converts a world position to the cell (x, z) it falls in. Does not clamp.]]
function Grid:WorldToCell(position: Vector3): (number, number)
	local cell = Building.CELL_SIZE
	local local_ = position - self.Origin
	return math.floor(local_.X / cell), math.floor(local_.Z / cell)
end

--[[Returns whether a cell is inside the grid bounds.]]
function Grid:IsInBounds(x: number, z: number): boolean
	return x >= 0 and z >= 0 and x < self.Width and z < self.Depth
end

-- ===== Occupancy queries ====================================================

--[[Returns the placement id occupying a cell, or nil.]]
function Grid:GetCellOccupant(x: number, z: number, floor: number): number?
	return self._cellIndex[Grid.cellKey(x, z, floor)]
end

--[[Returns whether every cell key in the list is free.]]
function Grid:AreCellsFree(cellKeys: { string }): boolean
	for _, key in cellKeys do
		if self._cellIndex[key] then
			return false
		end
	end
	return true
end

--[[Returns whether every edge key in the list is free.]]
function Grid:AreEdgesFree(edgeKeys: { string }): boolean
	for _, key in edgeKeys do
		if self._edgeIndex[key] then
			return false
		end
	end
	return true
end

--[[Returns whether a single occupancy key (cell or edge) is currently occupied. Cell and
edge keys have distinct formats so one lookup can safely check both indexes.]]
function Grid:IsOccupied(key: string): boolean
	return self._cellIndex[key] ~= nil or self._edgeIndex[key] ~= nil
end

--[[Returns the placement id occupying an edge key, or nil.]]
function Grid:GetEdgeOccupant(edgeKey: string): number?
	return self._edgeIndex[edgeKey]
end

--[[Returns the Placement record for an id, or nil.]]
function Grid:GetPlacement(id: number): Placement?
	return self._placements[id]
end

-- ===== Floor material layer =================================================

--[[Sets a cell's painted floor material. Material 0 removes the overlay; base-floor
grass remains implicit, while upper-floor grass must be stored so it can render.]]
function Grid:SetFloorMaterial(x: number, z: number, floor: number, material: number)
	local key = Grid.cellKey(x, z, floor)
	if material < 1 or (floor == 1 and material == 1) then
		self._floors[key] = nil
	else
		self._floors[key] = { Floor = floor, X = x, Z = z, Material = material }
	end
end

--[[Returns the explicitly stored floor entry, or nil.]]
function Grid:GetFloorEntry(x: number, z: number, floor: number): FloorEntry?
	return self._floors[Grid.cellKey(x, z, floor)]
end

-- ===== Ceiling layer ========================================================

--[[Canonical key for the ceiling capping a cell on one build floor.]]
function Grid.ceilingKey(x: number, z: number, floor: number): string
	return `{floor}:{x},{z}`
end

--[[Adds/updates the ceiling capping a cell.]]
function Grid:SetCeiling(x: number, z: number, floor: number, topOffset: number, material: number)
	self._ceilings[Grid.ceilingKey(x, z, floor)] = {
		Floor = floor,
		X = x,
		Z = z,
		TopOffset = topOffset,
		Material = material,
	}
end

--[[Returns the ceiling capping a cell, or nil.]]
function Grid:GetCeiling(x: number, z: number, floor: number): CeilingEntry?
	return self._ceilings[Grid.ceilingKey(x, z, floor)]
end

--[[Removes the ceiling capping a cell. Returns whether one was present.]]
function Grid:RemoveCeiling(x: number, z: number, floor: number): boolean
	local key = Grid.ceilingKey(x, z, floor)
	if self._ceilings[key] then
		self._ceilings[key] = nil
		return true
	end
	return false
end

-- ===== Mutation =============================================================

--[[
Registers a placement. Cells and Edges are the pre-computed occupancy the caller
derived from the catalog footprint. Assigns and returns a fresh id. Does NOT
validate - call the service's validation first.
]]
function Grid:AddPlacement(data: {
	Name: string,
	X: number,
	Z: number,
	Floor: number,
	Rotation: number,
	Cells: { string },
	Edges: { string },
}): number
	local id = self._nextId
	self._nextId += 1

	local placement: Placement = {
		Id = id,
		Name = data.Name,
		X = data.X,
		Z = data.Z,
		Floor = data.Floor,
		Rotation = data.Rotation,
		Cells = data.Cells,
		Edges = data.Edges,
	}
	self._placements[id] = placement

	for _, key in placement.Cells do
		self._cellIndex[key] = id
	end
	for _, key in placement.Edges do
		self._edgeIndex[key] = id
	end

	return id
end

--[[Removes a placement and frees its cells/edges. Returns the removed record, or nil.]]
function Grid:RemovePlacement(id: number): Placement?
	local placement = self._placements[id]
	if not placement then
		return nil
	end

	for _, key in placement.Cells do
		if self._cellIndex[key] == id then
			self._cellIndex[key] = nil
		end
	end
	for _, key in placement.Edges do
		if self._edgeIndex[key] == id then
			self._edgeIndex[key] = nil
		end
	end

	self._placements[id] = nil
	return placement
end

--[[Iterates all placements. (Order is not guaranteed.)]]
function Grid:GetPlacements(): { [number]: Placement }
	return self._placements
end

-- ===== Serialization ========================================================

--[[
Compresses the grid to the save blob. Strategy:
  * A per-plot Palette dedupes the catalog names actually used, so each placement
    references a small integer instead of repeating a string.
  * Each placement becomes a flat integer tuple {paletteIndex, x, z, floor, rot}.
  * Derived occupancy (Cells/Edges) is NOT saved - Decompress rebuilds it.
Anything left at defaults (empty cells and base-floor grass) is simply absent.
]]
function Grid:Compress(): SaveBlob
	local palette: { string } = {}
	local paletteIndex: { [string]: number } = {}
	local placements: { SavedPlacement } = {}

	for _, placement in self._placements do
		local index = paletteIndex[placement.Name]
		if not index then
			table.insert(palette, placement.Name)
			index = #palette
			paletteIndex[placement.Name] = index
		end

		local tuple: SavedPlacement = { index, placement.X, placement.Z, placement.Floor, placement.Rotation }
		table.insert(placements, tuple)
	end

	local floors: { { number } } = {}
	for _, entry in self._floors do
		table.insert(floors, { entry.Floor, entry.X, entry.Z, entry.Material })
	end

	local ceilings: { { number } } = {}
	for _, entry in self._ceilings do
		table.insert(ceilings, { entry.Floor, entry.X, entry.Z, entry.TopOffset, entry.Material })
	end

	return { Palette = palette, Placements = placements, Floors = floors, Ceilings = ceilings }
end

--[[
Rebuilds a Grid from a save blob.

`basePart` sizes the grid. `resolveFootprint` is supplied by the caller (it wraps
the catalog) and, given a placement's name/coords/rotation, returns the
occupied cell keys and edge keys. This keeps the Grid decoupled from the catalog.
]]
function Grid.Decompress(
	blob: SaveBlob,
	basePart: BasePart,
	resolveFootprint: (name: string, x: number, z: number, floor: number, rotation: number) -> ({ string }, { string })
): Grid
	local self = Grid.new(basePart)
	if not blob then
		return self
	end

	for _, tuple in blob.Placements do
		local name = blob.Palette[tuple[1]]
		if not name then
			warn(`[Grid]: save referenced palette index {tuple[1]} with no entry; skipped`)
			continue
		end
		local x, z, floor, rotation = tuple[2], tuple[3], tuple[4], tuple[5]
		local cells, edges = resolveFootprint(name, x, z, floor, rotation)
		self:AddPlacement({
			Name = name,
			X = x,
			Z = z,
			Floor = floor,
			Rotation = rotation,
			Cells = cells,
			Edges = edges,
		})
	end

	for _, tuple in blob.Floors or {} do
		self:SetFloorMaterial(tuple[2], tuple[3], tuple[1], tuple[4])
	end

	for _, tuple in blob.Ceilings or {} do
		if #tuple >= 5 then
			self:SetCeiling(tuple[2], tuple[3], tuple[1], tuple[1] * Building.WALL_HEIGHT, tuple[5])
		else
			-- Legacy ceiling tuple: {x, z, heightLevel, materialIndex}.
			self:SetCeiling(tuple[1], tuple[2], 1, Building.WALL_HEIGHT, tuple[4])
		end
	end

	return self
end

return Grid
