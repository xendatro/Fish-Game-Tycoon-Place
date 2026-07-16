--[[
SharedBuildingService - logic used identically by client (preview/prediction) and
server (authority). It owns three things:

  1. The catalog: every entry from every module under Config/Items, merged into one
     flat registry keyed by name. Studio organisation of those files is irrelevant.
  2. Footprint derivation: how many grid cells an asset occupies, measured from its
     model and rounded to whole cells (so imperfect models still resolve cleanly).
  3. Validation + occupancy: given a placement, which cells/edges it occupies and
     whether that placement is legal against a Grid.

It never renders, charges money, or touches the profile - that's the server's job.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Building = require(ReplicatedStorage.Config.Building)
local Grid = require(ReplicatedStorage.Classes.Grid)

local SharedBuildingService = {}

export type CatalogEntry = {
	Name: string,
	Type: "Content" | "Wall" | "Ceiling" | "Hanger",
	Heights: { number }?, -- present on extendables (walls/stairs)
	Extendable: boolean, -- stairs / some walls
	-- Footprint in whole cells, derived by measuring the model.
	Footprint: { Width: number, Depth: number },
	Model: Model?, -- the representative placeable model (nil if not found)
	ModelSize: Vector3?, -- the representative model's extents (for hitbox sizing)
}

local catalog: { [string]: CatalogEntry } = {}

-- Placeable models gathered from Assets.Placeables, keyed by name then by height
-- level. Models without a Height attribute (non-extendables) are stored under
-- DEFAULT_HEIGHT_KEY. See gatherModels / GetModel.
local DEFAULT_HEIGHT_KEY = 0
local modelsByName: { [string]: { [number]: Model } } = {}

-- ===== Catalog ==============================================================

--[[Measures a model's footprint in whole grid cells (min 1x1). Rounding absorbs
modeller imprecision - a ~16-stud door resolves to exactly 4 cells.]]
function SharedBuildingService:DeriveFootprint(model: Model): { Width: number, Depth: number }
	local size = model:GetExtentsSize()
	return {
		Width = math.max(1, math.round(size.X / Building.CELL_SIZE)),
		Depth = math.max(1, math.round(size.Z / Building.CELL_SIZE)),
	}
end

--[[Indexes every top-level placeable model under Assets.Placeables by name and height.
The folder holds category folders of models, so we take Model descendants - but only
top-level ones (a Model nested inside another Model is a sub-part, not a placeable).
Duplicate-named models are height variants, distinguished by their numeric Height
level attribute (1..4); models without one are stored as the default variant.]]
local function gatherModels()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local placeables = assets and assets:FindFirstChild("Placeables")
	if not placeables then
		warn("[SharedBuildingService]: Assets.Placeables not found; models unavailable")
		return
	end

	for _, descendant in placeables:GetDescendants() do
		if descendant:IsA("Model") and not descendant:FindFirstAncestorOfClass("Model") then
			local name = descendant.Name
			local height = descendant:GetAttribute("Height") or DEFAULT_HEIGHT_KEY

			local variants = modelsByName[name]
			if not variants then
				variants = {}
				modelsByName[name] = variants
			end

			if variants[height] then
				warn(`[SharedBuildingService]: duplicate placeable '{name}' at height {height}; keeping first`)
			else
				variants[height] = descendant
			end
		end
	end
end

--[[Returns a representative model for an entry (used for footprint + preview): the
default variant, else the lowest height, else any.]]
local function representativeModel(name: string): Model?
	local variants = modelsByName[name]
	if not variants then
		return nil
	end
	if variants[DEFAULT_HEIGHT_KEY] then
		return variants[DEFAULT_HEIGHT_KEY]
	end
	for level = 1, Building.MAX_HEIGHT_LEVEL do
		if variants[level] then
			return variants[level]
		end
	end
	local _, any = next(variants)
	return any
end

--[[Builds the catalog by merging every module under Config/Items. Each entry gets its
table key injected as Name, its model resolved from Assets.Placeables, and its footprint
measured from that model.]]
local function buildCatalog()
	local itemsFolder = ReplicatedStorage.Config:FindFirstChild("Items")
	if not itemsFolder then
		warn("[SharedBuildingService]: Config.Items folder not found; catalog is empty")
		return
	end

	for _, module in itemsFolder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end
		local entries = require(module)
		for name, entry in entries do
			if catalog[name] then
				warn(`[SharedBuildingService]: duplicate catalog entry '{name}' (in {module:GetFullName()}); keeping first`)
				continue
			end
			entry.Name = name
			entry.Extendable = entry.Heights ~= nil

			local model = representativeModel(name)
			entry.Model = model
			if model then
				entry.ModelSize = model:GetExtentsSize()
				entry.Footprint = entry.Footprint or SharedBuildingService:DeriveFootprint(model)
			else
				warn(`[SharedBuildingService]: no placeable model found for '{name}'; defaulting footprint to 1x1`)
				entry.Footprint = entry.Footprint or { Width = 1, Depth = 1 }
			end

			catalog[name] = entry
		end
	end
end

--[[Returns the catalog entry for a name, or nil.]]
function SharedBuildingService:GetEntry(name: string): CatalogEntry?
	return catalog[name]
end

--[[Returns the exact height variant when requested. A missing variant returns nil
instead of silently rendering a model whose geometry disagrees with grid data.]]
function SharedBuildingService:GetModel(name: string, height: number?): Model?
	local variants = modelsByName[name]
	if not variants then
		return nil
	end
	if height then
		return variants[height]
	end
	return representativeModel(name)
end

--[[Returns the whole merged catalog.]]
function SharedBuildingService:GetCatalog(): { [string]: CatalogEntry }
	return catalog
end

-- ===== Footprint -> occupancy ===============================================

--[[
0-based index of the pivot cell within a run of `dim` cells. Odd runs pivot on the
true centre; even runs have no true centre, so we pick the left (lower-index) cell,
matching how rotation should feel for offset footprints.
]]
local function pivotIndex(dim: number): number
	return math.ceil(dim / 2) - 1
end

--[[Rotates a pivot-relative cell offset by `rotation` * 90 degrees (CCW in the XZ plane).]]
local function rotateOffset(dx: number, dz: number, rotation: number): (number, number)
	if rotation == 1 then
		return -dz, dx
	elseif rotation == 2 then
		return -dx, -dz
	elseif rotation == 3 then
		return dz, -dx
	end
	return dx, dz
end

--[[
Returns the list of {x, z} cell coordinates a content/ceiling footprint occupies,
rotated about its pivot cell (which sits at x, z). Used for both bounds checking and
key generation so the two never disagree.
]]
local function computeCellCoords(entry: CatalogEntry, x: number, z: number, rotation: number): { { number } }
	local w, d = entry.Footprint.Width, entry.Footprint.Depth
	local px, pz = pivotIndex(w), pivotIndex(d)

	local coords = {}
	for i = 0, w - 1 do
		for j = 0, d - 1 do
			local dx, dz = rotateOffset(i - px, j - pz, rotation)
			table.insert(coords, { x + dx, z + dz })
		end
	end
	return coords
end

--[[Returns the cell keys a content/ceiling footprint occupies.]]
local function computeCells(entry: CatalogEntry, x: number, z: number, floor: number, rotation: number): { string }
	local cells = {}
	for _, coord in computeCellCoords(entry, x, z, rotation) do
		table.insert(cells, Grid.cellKey(coord[1], coord[2], floor))
	end
	return cells
end

--[[
Maps a clicked cell + rotation to the perimeter edge a wall sits on. Each of the four
rotations targets a distinct side of the cell, so two walls can share a cell on
different sides (and corner) without colliding:
  0 -> south (H edge at z)      2 -> north (H edge at z+1)
  1 -> east  (V edge at x+1)    3 -> west  (V edge at x)
Returns the edge orientation and the anchor cell of that edge.
]]
local function wallEdgeParams(x: number, z: number, rotation: number): (string, number, number)
	if rotation == 0 then
		return "H", x, z
	elseif rotation == 1 then
		return "V", x + 1, z
	elseif rotation == 2 then
		return "H", x, z + 1
	end
	return "V", x, z
end

--[[Returns the edge keys a wall occupies. A wall of length L (its Width in cells) runs
along its edge, pivoted about its centre (left-of-centre for even lengths).]]
local function computeEdges(entry: CatalogEntry, x: number, z: number, floor: number, rotation: number): { string }
	local length = entry.Footprint.Width
	local pi = pivotIndex(length)
	local orientation, ex, ez = wallEdgeParams(x, z, rotation)

	local edges = {}
	for i = 0, length - 1 do
		local offset = i - pi
		if orientation == "H" then
			table.insert(edges, Grid.edgeKey("H", ex + offset, ez, floor))
		else
			table.insert(edges, Grid.edgeKey("V", ex, ez + offset, floor))
		end
	end
	return edges
end

--[[
Resolves the occupancy (cell keys, edge keys) of a placement. This is the function
handed to Grid.Decompress so it can rebuild occupancy from a bare save. Walls occupy
edges and no cells; everything else occupies cells and no edges.
]]
function SharedBuildingService:ResolveOccupancy(
	name: string,
	x: number,
	z: number,
	floor: number,
	rotation: number,
	_height: number?
): ({ string }, { string })
	local entry = catalog[name]
	if not entry then
		warn(`[SharedBuildingService]: ResolveOccupancy for unknown entry '{name}'`)
		return {}, {}
	end

	if entry.Type == "Wall" then
		return {}, computeEdges(entry, x, z, floor, rotation)
	else
		return computeCells(entry, x, z, floor, rotation), {}
	end
end

--[[Returns the {x, z} cell coordinates a placement's footprint occupies (rotated).
Used by the client to visualise per-cell validity. (For walls this is the line of
cells the wall runs along.)]]
function SharedBuildingService:GetFootprintCoords(name: string, x: number, z: number, rotation: number): { { number } }
	local entry = catalog[name]
	if not entry then
		return {}
	end
	return computeCellCoords(entry, x, z, rotation)
end

--[[Returns the world-space centre (on the floor surface) of a wall's run. Walls sit on
the grid perimeter line of their edge, offset half a cell along the run for even lengths.]]
local function wallRunCentre(grid: Grid.Grid, entry: CatalogEntry, x: number, z: number, rotation: number): Vector3
	local cell = Building.CELL_SIZE
	local length = entry.Footprint.Width
	local runCentre = (length - 1 - 2 * pivotIndex(length)) / 2 -- 0 for odd, 0.5 for even
	local orientation, ex, ez = wallEdgeParams(x, z, rotation)
	local origin = grid.Origin

	if orientation == "H" then
		return Vector3.new(origin.X + (ex + runCentre + 0.5) * cell, origin.Y, origin.Z + ez * cell)
	else
		return Vector3.new(origin.X + ex * cell, origin.Y, origin.Z + (ez + runCentre + 0.5) * cell)
	end
end

--[[
Returns the world CFrame to render/preview a placement at, on the plot's floor surface.
Content sits at its footprint centre (even footprints shift half a cell so the model
stays aligned to the cells it occupies). Walls sit on their perimeter edge line instead.
Callers add their model's vertical rest offset on top.
]]
function SharedBuildingService:GetPlacementCFrame(grid: Grid.Grid, name: string, x: number, z: number, rotation: number): CFrame?
	local entry = catalog[name]
	if not entry then
		return nil
	end

	local rot = CFrame.Angles(0, math.rad(-90 * rotation), 0)

	if entry.Type == "Wall" then
		return CFrame.new(wallRunCentre(grid, entry, x, z, rotation)) * rot
	end

	local cell = Building.CELL_SIZE
	local offsetX = (if entry.Footprint.Width % 2 == 0 then 0.5 else 0) * cell
	local offsetZ = (if entry.Footprint.Depth % 2 == 0 then 0.5 else 0) * cell
	local worldOffset = rot:VectorToWorldSpace(Vector3.new(offsetX, 0, offsetZ))
	return CFrame.new(grid:GetCellCenter(x, z) + worldOffset) * rot
end

-- Cached model extents, keyed by model, so repeated height/size lookups don't recompute.
local modelExtentsCache: { [Model]: Vector3 } = {}
local function modelExtents(model: Model): Vector3
	local size = modelExtentsCache[model]
	if not size then
		size = model:GetExtentsSize()
		modelExtentsCache[model] = size
	end
	return size
end

--[[Returns the vertical offset of the floor supporting a placement. Floor 1 is the
plot surface. Higher floors are ceiling tops; every footprint cell/edge must have a
ceiling beneath it at one consistent height.]]
function SharedBuildingService:GetFloorOffset(
	grid: Grid.Grid,
	name: string,
	x: number,
	z: number,
	floor: number,
	rotation: number
): (number?, string?)
	if floor == 1 then
		return 0
	end

	local entry = catalog[name]
	if not entry then
		return nil, "unknown asset"
	end

	local supportTopOffset: number? = nil
	local function addSupport(topOffset: number?): boolean
		if not topOffset then
			return false
		end
		if supportTopOffset and supportTopOffset ~= topOffset then
			return false
		end
		supportTopOffset = topOffset
		return true
	end

	if entry.Type == "Wall" then
		local length = entry.Footprint.Width
		local pi = pivotIndex(length)
		local orientation, ex, ez = wallEdgeParams(x, z, rotation)
		for i = 0, length - 1 do
			local offset = i - pi
			local first, second, belowEdgeKey
			if orientation == "H" then
				first = grid:GetCeiling(ex + offset, ez, floor - 1)
				second = grid:GetCeiling(ex + offset, ez - 1, floor - 1)
				belowEdgeKey = Grid.edgeKey("H", ex + offset, ez, floor - 1)
			else
				first = grid:GetCeiling(ex, ez + offset, floor - 1)
				second = grid:GetCeiling(ex - 1, ez + offset, floor - 1)
				belowEdgeKey = Grid.edgeKey("V", ex, ez + offset, floor - 1)
			end
			local ceilingTop = math.max(if first then first.TopOffset else 0, if second then second.TopOffset else 0)

			-- A wall directly below on the same edge supports stacking: rest on its top.
			local belowId = grid:GetEdgeOccupant(belowEdgeKey)
			local belowWall = belowId and grid:GetPlacement(belowId)
			local wallTop = (belowWall and self:GetPlacementTopOffset(grid, belowWall)) or 0

			local topOffset = math.max(ceilingTop, wallTop)
			if topOffset == 0 or not addSupport(topOffset) then
				return nil, if topOffset == 0 then "needs floor below" else "floor is uneven"
			end
		end
	else
		for _, coord in computeCellCoords(entry, x, z, rotation) do
			local ceiling = grid:GetCeiling(coord[1], coord[2], floor - 1)
			if not ceiling or not addSupport(ceiling.TopOffset) then
				return nil, if not ceiling then "needs floor below" else "floor is uneven"
			end
		end
	end

	return supportTopOffset
end

--[[Returns a placement's TOP-surface offset above Origin.Y: its own floor offset plus its
measured model height. Used to stack walls and to snap ceilings flush to a wall top.]]
function SharedBuildingService:GetPlacementTopOffset(grid: Grid.Grid, placement: Grid.Placement): number?
	local floorOffset = self:GetFloorOffset(grid, placement.Name, placement.X, placement.Z, placement.Floor, placement.Rotation)
	local model = self:GetModel(placement.Name, placement.Height)
	local height = model and modelExtents(model).Y
	if floorOffset and height then
		return floorOffset + height
	end
	return nil
end

local shortestWallHeight: number? = nil
--[[Returns the measured height of the shortest wall model in the catalog. Used as the
default per-floor surface height for previews (a floor N sits ~(N-1) walls up). Cached.]]
function SharedBuildingService:GetShortestWallHeight(): number
	if shortestWallHeight then
		return shortestWallHeight
	end
	local shortest: number? = nil
	for name, entry in catalog do
		if entry.Type ~= "Wall" then
			continue
		end
		local variants = modelsByName[name]
		if variants then
			for _, model in variants do
				local h = modelExtents(model).Y
				if not shortest or h < shortest then
					shortest = h
				end
			end
		end
	end
	shortestWallHeight = shortest or Building.HEIGHT_STUDS[1]
	return shortestWallHeight
end

--[[Returns the ceiling's TOP surface offset - flush with the highest bordering wall top.
With no bordering wall, an adjacent same-floor ceiling supplies the top offset for spreading.]]
function SharedBuildingService:GetCeilingTopOffset(grid: Grid.Grid, x: number, z: number, floor: number): number?
	local wallTop: number? = nil
	local function considerWall(topOffset: number?)
		if topOffset and (not wallTop or topOffset > wallTop) then
			wallTop = topOffset
		end
	end

	for _, key in {
		Grid.edgeKey("H", x, z, floor),
		Grid.edgeKey("H", x, z + 1, floor),
		Grid.edgeKey("V", x, z, floor),
		Grid.edgeKey("V", x + 1, z, floor),
	} do
		local id = grid:GetEdgeOccupant(key)
		local placement = id and grid:GetPlacement(id)
		if placement then
			-- Snap to the wall's actual (measured) top, so the ceiling top is flush with it.
			considerWall(self:GetPlacementTopOffset(grid, placement))
		end
	end
	if wallTop then
		return wallTop
	end

	local adjacentTop: number? = nil
	for _, offset in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local ceiling = grid:GetCeiling(x + offset[1], z + offset[2], floor)
		if ceiling and (not adjacentTop or ceiling.TopOffset > adjacentTop) then
			adjacentTop = ceiling.TopOffset
		end
	end

	return adjacentTop
end

--[[Returns every distinct ceiling top offset a cell could snap to (each bordering wall's
top, plus adjacent same-floor ceilings), sorted ascending. When a tile borders walls of
different heights this has multiple entries, and the client picks one from where the mouse
is aiming; the server validates the chosen offset against this list.]]
function SharedBuildingService:GetCeilingSupportOffsets(grid: Grid.Grid, x: number, z: number, floor: number): { number }
	local offsets: { number } = {}
	local seen: { [number]: boolean } = {}
	local function add(offset: number?)
		if offset and not seen[offset] then
			seen[offset] = true
			table.insert(offsets, offset)
		end
	end

	for _, key in {
		Grid.edgeKey("H", x, z, floor),
		Grid.edgeKey("H", x, z + 1, floor),
		Grid.edgeKey("V", x, z, floor),
		Grid.edgeKey("V", x + 1, z, floor),
	} do
		local id = grid:GetEdgeOccupant(key)
		local placement = id and grid:GetPlacement(id)
		if placement then
			add(self:GetPlacementTopOffset(grid, placement))
		end
	end
	for _, offset in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local ceiling = grid:GetCeiling(x + offset[1], z + offset[2], floor)
		if ceiling then
			add(ceiling.TopOffset)
		end
	end

	table.sort(offsets)
	return offsets
end

-- One grid-unit of an object's hitbox, sized to the model, for validity display + queries.
-- Key is the occupancy key (cell or edge) the piece maps to, so callers can check the
-- exact same grid state that blocks placement.
export type HitboxPiece = { CFrame: CFrame, Size: Vector3, InBounds: boolean, Key: string }

--[[
Returns the hitbox pieces for a placement: one per occupied cell for content, one per
edge segment for walls. Each is sized to the placement's actual height-variant model
(height = model height; walls use the model's thin dimension as thickness), carries the
occupancy Key it maps to, and flags whether it's inside the plot.
]]
function SharedBuildingService:GetHitboxPieces(
	grid: Grid.Grid,
	name: string,
	x: number,
	z: number,
	floor: number,
	rotation: number,
	height: number?,
	previewFloorOffset: number?
): { HitboxPiece }
	local entry = catalog[name]
	if not entry then
		return {}
	end

	local cell = Building.CELL_SIZE
	local model = self:GetModel(name, height)
	local modelSize = if model then modelExtents(model) else (entry.ModelSize or Vector3.new(cell, cell, cell))
	local h = modelSize.Y
	local origin = grid.Origin
	local floorOffset = self:GetFloorOffset(grid, name, x, z, floor, rotation) or previewFloorOffset or 0
	local yaw = math.rad(-90 * rotation)
	local pieces: { HitboxPiece } = {}

	if entry.Type == "Wall" then
		local length = entry.Footprint.Width
		local pi = pivotIndex(length)
		local orientation, ex, ez = wallEdgeParams(x, z, rotation)
		local thickness = math.max(0.2, math.min(modelSize.X, modelSize.Z))

		for i = 0, length - 1 do
			local offset = i - pi
			local centreX, centreZ, inBounds, key
			if orientation == "H" then
				centreX = origin.X + (ex + offset + 0.5) * cell
				centreZ = origin.Z + ez * cell
				inBounds = grid:IsInBounds(ex + offset, ez) or grid:IsInBounds(ex + offset, ez - 1)
				key = Grid.edgeKey("H", ex + offset, ez, floor)
			else
				centreX = origin.X + ex * cell
				centreZ = origin.Z + (ez + offset + 0.5) * cell
				inBounds = grid:IsInBounds(ex, ez + offset) or grid:IsInBounds(ex - 1, ez + offset)
				key = Grid.edgeKey("V", ex, ez + offset, floor)
			end
			table.insert(pieces, {
				CFrame = CFrame.new(centreX, origin.Y + floorOffset + h / 2, centreZ) * CFrame.Angles(0, yaw, 0),
				Size = Vector3.new(cell, h, thickness),
				InBounds = inBounds,
				Key = key,
			})
		end
	else
		for _, coord in computeCellCoords(entry, x, z, rotation) do
			local centre = grid:GetCellCenter(coord[1], coord[2])
			table.insert(pieces, {
				CFrame = CFrame.new(centre.X, origin.Y + floorOffset + h / 2, centre.Z),
				Size = Vector3.new(cell, h, cell),
				InBounds = grid:IsInBounds(coord[1], coord[2]),
				Key = Grid.cellKey(coord[1], coord[2], floor),
			})
		end
	end

	return pieces
end

-- ===== Validation ===========================================================

--[[
Returns whether a placement is legal, plus a reason string on failure. This is the
shared authority both sides run. The core layer checks (bounds + occupancy) are
implemented; the doc's finer rules are marked TODO and will be filled as we wire
rendering and the real footprints.
]]
function SharedBuildingService:CanPlace(
	grid: Grid.Grid,
	name: string,
	x: number,
	z: number,
	floor: number,
	rotation: number,
	height: number?
): (boolean, string?)
	local entry = catalog[name]
	if not entry then
		return false, "unknown asset"
	end

	if floor < 1 or floor > Building.FLOOR_COUNT then
		return false, "invalid floor"
	end

	if entry.Extendable and (not height or not table.find(entry.Heights :: { number }, height)) then
		return false, "invalid height level"
	end
	if entry.Extendable and not self:GetModel(name, height) then
		return false, "missing height model"
	end
	local cells, edges = self:ResolveOccupancy(name, x, z, floor, rotation, height)

	-- Bounds: every cell of the (rotated) footprint must be inside the plot.
	for _, coord in computeCellCoords(entry, x, z, rotation) do
		if not grid:IsInBounds(coord[1], coord[2]) then
			return false, "out of bounds"
		end
	end
	if floor > 1 then
		local _, reason = self:GetFloorOffset(grid, name, x, z, floor, rotation)
		if reason then
			return false, reason
		end
	end

	if not grid:AreCellsFree(cells) then
		return false, "cells occupied"
	end
	if not grid:AreEdgesFree(edges) then
		return false, "edges occupied"
	end

	-- TODO(doc rules):
	--   * Hangers must attach beneath a ceiling.
	--   * NPC-interactable assets need >= 1 empty clearance cell.
	--   * Walls cannot be penetrated by content (edge-vs-cell adjacency check).
	--   * Money check happens server-side in ServerBuildingService.

	return true
end

gatherModels()
buildCatalog()

return SharedBuildingService
