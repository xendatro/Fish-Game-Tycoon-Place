--[[
ServerBuildingService - the authority for building. It:
  * receives place/remove requests from clients,
  * validates them with SharedBuildingService (the same rules the client predicted),
  * mutates the owning plot's Grid,
  * renders the result on the server (so it replicates to everyone),
  * charges money and persists the compressed grid into the profile.

Money is still stubbed; placement, rendering, history, and profile persistence are
server-authoritative.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local SharedBuildingService = require(ReplicatedStorage.Services.SharedBuildingService)
local SharedColorService = require(ReplicatedStorage.Services.SharedColorService)
local DataSaveService = require(ReplicatedStorage.Services.DataSaveService)
local ServerPlotService = require(ServerStorage.Services.ServerPlotService)
local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local Grid = require(ReplicatedStorage.Classes.Grid)

local ServerBuildingService = {}

type PlacementRequest = { X: number, Z: number, Floor: number, Rotation: number }
type CellRequest = { X: number, Z: number }
type PlacementChange = { Placement: Grid.Placement, BeforePresent: boolean, AfterPresent: boolean }
type ColorChange = {
	Id: number,
	BeforeColors: SharedColorService.SlotMap?,
	AfterColors: SharedColorService.SlotMap?,
	BeforeLinked: boolean?,
	AfterLinked: boolean?,
}
-- Floor state is the (material, tint) pair; material 0 means "no explicit tile".
type FloorState = { Material: number, Color: number? }
type FloorChange = { X: number, Z: number, Floor: number, Before: FloorState, After: FloorState }
type CeilingState = { TopOffset: number, Material: number, Color: number? }
type CeilingChange = {
	X: number,
	Z: number,
	Floor: number,
	BeforeCeiling: CeilingState?,
	AfterCeiling: CeilingState?,
	BeforeFloor: FloorState,
	AfterFloor: FloorState,
}
type HistoryEntry =
	{ Kind: "Placement", Changes: { PlacementChange } }
	| { Kind: "Floor", Changes: { FloorChange } }
	| { Kind: "Ceiling", Changes: { CeilingChange } }
	| { Kind: "Color", Changes: { ColorChange } }
type HistoryState = { Undo: { HistoryEntry }, Redo: { HistoryEntry } }

local Histories: { [Player]: HistoryState } = {}
local AssignedPlots = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isGridInteger(value: any): boolean
	return isFiniteNumber(value) and value % 1 == 0
end

local function isPlacementRequest(value: any): boolean
	return type(value) == "table"
		and isGridInteger(value.X)
		and isGridInteger(value.Z)
		and isGridInteger(value.Floor)
		and isGridInteger(value.Rotation)
end

local function isCellRequest(value: any): boolean
	return type(value) == "table" and isGridInteger(value.X) and isGridInteger(value.Z)
end

local function isRequestList(value: any, validator: (any) -> boolean): boolean
	if type(value) ~= "table" then
		return false
	end
	for _, request in value do
		if not validator(request) then
			return false
		end
	end
	return true
end

-- Remotes are authored in Studio under ReplicatedStorage.Communication.Building
-- (never created programmatically). See the list at the bottom of this file.
local Communication = ReplicatedStorage:WaitForChild("Communication")
local BuildingRemotes = Communication:WaitForChild("Building")
local placeRemote = BuildingRemotes:WaitForChild("Place") :: RemoteFunction
local removeRemote = BuildingRemotes:WaitForChild("Remove") :: RemoteFunction
local paintRemote = BuildingRemotes:WaitForChild("Paint") :: RemoteFunction
local ceilingRemote = BuildingRemotes:WaitForChild("Ceiling") :: RemoteFunction
local historyRemote = BuildingRemotes:WaitForChild("History") :: RemoteFunction
local resetRemote = BuildingRemotes:WaitForChild("Reset") :: RemoteFunction
local recolorRemote = BuildingRemotes:WaitForChild("Recolor") :: RemoteFunction
local paletteRemote = BuildingRemotes:WaitForChild("Palette") :: RemoteFunction

local function pushHistory(player: Player, entry: HistoryEntry)
	local history = Histories[player]
	if not history then
		history = { Undo = {}, Redo = {} }
		Histories[player] = history
	end
	table.insert(history.Undo, entry)
	if #history.Undo > Building.UNDO_HISTORY_LIMIT then
		table.remove(history.Undo, 1)
	end
	table.clear(history.Redo)
end

-- ===== Saved palettes =======================================================
--[[
Each player may save one palette per placeable, stored on the profile in the flat
{slot, colour, ...} form (see ProfileTemplate). Placements can LINK to their asset's
palette instead of carrying picked colours, which is what lets a palette edit propagate.
]]

local function paletteStore(player: Player): { [string]: { Name: string, Colors: { number } } }
	local profile = DataSaveService:GetProfile(player)
	local stored = profile and profile.Data.CustomPalettes
	if not stored then
		return {}
	end
	return if stored.Serialize then stored:Serialize() else stored
end

--[[Returns a player's saved palette for one asset as a slot map, or nil.]]
local function getPalette(player: Player, name: string): SharedColorService.SlotMap?
	local saved = paletteStore(player)[name]
	if not saved then
		return nil
	end
	return SharedColorService:Sanitize(name, SharedColorService.ExpandSlots(saved.Colors))
end

--[[
Writes (or clears) a player's saved palette.

Rebuilding the table rather than mutating it matters: the reactive Table detects changes
with a SHALLOW clone, so assigning back a table we edited in place compares it against
itself, finds no difference, and replicates nothing. Only the very first write escapes
that, by replacing the wrapper left over from load - which is why creating a palette
worked and every edit afterwards silently didn't.
]]
local function setPalette(
	player: Player,
	name: string,
	colors: SharedColorService.SlotMap?,
	paletteName: string?
)
	local profile = DataSaveService:GetProfile(player)
	if not profile then
		return
	end

	local store = {}
	for key, saved in paletteStore(player) do
		if key ~= name then
			store[key] = { Name = saved.Name, Colors = table.clone(saved.Colors) }
		end
	end
	if colors then
		store[name] = { Name = paletteName or "Custom", Colors = SharedColorService.FlattenSlots(colors) }
	end
	profile.Data.CustomPalettes = store
end

--[[Writes the authoritative grid into the reactive profile. ProfileStore controls the
actual datastore save cadence and performs a final save when the session ends.]]
local function persist(plot, owner: Player?)
	owner = owner or plot:GetOwner()
	local profile = owner and DataSaveService:GetProfile(owner)
	if profile then
		profile.Data.Build = plot:Serialize()
	end
end

--[[Returns (creating if needed) the folder holding a plot's rendered build instances.]]
local function getBuildContainer(plot): Folder
	local container = plot.Model:FindFirstChild("Built")
	if not container then
		container = Instance.new("Folder")
		container.Name = "Built"
		container.Parent = plot.Model
	end
	return container
end

--[[
Renders a committed placement on the server (so it replicates to everyone). Clones the
asset model, rotates it, and aligns it to its floor or ceiling surface at its pivot cell.

This is the basic content path. Each level has a deterministic configured offset;
ceilings and flooring use their own render paths below.
]]
local function render(plot, placement)
	local model = SharedBuildingService:GetModel(placement.Name)
	if not model then
		return
	end

	local grid = plot:GetGrid()
	local clone = model:Clone()
	-- Stamp the placement data so clients can rebuild the authoritative grid for previews.
	clone:SetAttribute("PlacementId", placement.Id)
	clone:SetAttribute("AssetName", placement.Name)
	clone:SetAttribute("GridX", placement.X)
	clone:SetAttribute("GridZ", placement.Z)
	clone:SetAttribute("Floor", placement.Floor)
	clone:SetAttribute("Rotation", placement.Rotation)

	-- First place it on the correct X/Z edge or cell, then align its actual bounds to the
	-- supporting surface. Model pivots are not required to be centred.
	local groundCF = SharedBuildingService:GetPlacementCFrame(grid, placement.Name, placement.X, placement.Z, placement.Rotation)
	if groundCF then
		local entry = SharedBuildingService:GetEntry(placement.Name)
		SharedBuildingService:PivotModelToLevel(
			clone,
			groundCF,
			grid.Origin.Y,
			placement.Floor,
			entry and entry.Type
		)
	end

	-- Stamped so the client can tell which objects a palette edit would affect.
	clone:SetAttribute("PaletteLinked", placement.Linked or nil)
	SharedColorService:ApplyColors(clone, placement.Name, placement.Colors)
	clone.Parent = getBuildContainer(plot)
end

--[[Returns the rendered instance for a placement id, or nil.]]
local function findRendered(plot, placementId): Model?
	for _, child in getBuildContainer(plot):GetChildren() do
		if child:GetAttribute("PlacementId") == placementId then
			return child :: Model
		end
	end
	return nil
end

--[[Repaints an already-rendered placement in place. Colour is presentation only, so
there's no need to rebuild the clone or touch the grid's occupancy.]]
local function rerender(plot, placement: Grid.Placement)
	local rendered = findRendered(plot, placement.Id)
	if rendered then
		rendered:SetAttribute("PaletteLinked", placement.Linked or nil)
		SharedColorService:ApplyColors(rendered, placement.Name, placement.Colors)
	end
end

--[[Removes the rendered instance for a placement id.]]
local function derender(plot, placementId)
	local rendered = findRendered(plot, placementId)
	if rendered then
		rendered:Destroy()
	end
end

--[[Returns (creating if needed) the folder holding a plot's painted floor tiles.]]
local function getFloorContainer(plot): Folder
	local container = plot.Model:FindFirstChild("Floor")
	if not container then
		container = Instance.new("Folder")
		container.Name = "Floor"
		container.Parent = plot.Model
	end
	return container
end

--[[
Returns a painted floor cell's tile descriptor for meshing - its material index and the
world Y of its supporting surface - or nil if the cell has no explicit tile. Elevated
grass is an explicit tile; base-floor grass remains the plot's implicit default.
]]
local function floorTileAt(
	grid,
	x: number,
	z: number,
	floor: number
): ({ Material: number, Color: number?, SurfaceY: number }?)
	local entry = grid:GetFloorEntry(x, z, floor)
	if not entry then
		return nil
	end
	if floor == 1 then
		return { Material = entry.Material, Color = entry.Color, SurfaceY = grid.Origin.Y }
	end
	local ceiling = grid:GetCeiling(x, z, floor - 1)
	if not ceiling then
		return nil
	end
	return {
		Material = entry.Material,
		Color = entry.Color,
		SurfaceY = grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(floor),
	}
end

--[[
Re-meshes an entire floor: destroys its existing tiles and rebuilds them as merged
rectangles via greedy meshing, so a run of same-material cells becomes one part instead
of many. Cells only merge if they share material, tint, and top-Y. (TODO(perf): re-mesh
only the dirty region rather than the whole floor.)
]]
local function remeshFloor(plot, floor: number)
	local grid = plot:GetGrid()
	local container = getFloorContainer(plot)

	for _, child in container:GetChildren() do
		if child:GetAttribute("FloorLevel") == floor then
			child:Destroy()
		end
	end

	local cell = Building.CELL_SIZE
	local visited = {}
	local function seen(x, z)
		return visited[`{x},{z}`]
	end
	local function mark(x, z)
		visited[`{x},{z}`] = true
	end

	for z = 0, grid.Depth - 1 do
		for x = 0, grid.Width - 1 do
			local tile = floorTileAt(grid, x, z, floor)
			if not tile or seen(x, z) then
				continue
			end

			-- Extend width along +X, then height along +Z, over identical tiles.
			local function matches(cx, cz)
				if seen(cx, cz) then
					return false
				end
				local other = floorTileAt(grid, cx, cz, floor)
				return other ~= nil
					and other.Material == tile.Material
					and other.Color == tile.Color
					and other.SurfaceY == tile.SurfaceY
			end

			local w = 1
			while x + w < grid.Width and matches(x + w, z) do
				w += 1
			end
			local h = 1
			while z + h < grid.Depth do
				local rowOk = true
				for xi = x, x + w - 1 do
					if not matches(xi, z + h) then
						rowOk = false
						break
					end
				end
				if not rowOk then
					break
				end
				h += 1
			end
			for zi = z, z + h - 1 do
				for xi = x, x + w - 1 do
					mark(xi, zi)
				end
			end

			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.Size = Vector3.new(w * cell, Building.FLOOR_THICKNESS, h * cell)
			part.Material = (Enum.Material :: any)[Materials.Floor[tile.Material].Material]
			part.Color = SharedColorService:MaterialColor("Floor", tile.Material, tile.Color)
			-- The overlay's bottom rests directly on its supporting surface.
			part.CFrame = CFrame.new(
				grid.Origin.X + (x + w / 2) * cell,
				tile.SurfaceY + Building.FLOOR_THICKNESS / 2,
				grid.Origin.Z + (z + h / 2) * cell
			)
			part:SetAttribute("FloorLevel", floor)
			part:SetAttribute("MaterialIndex", tile.Material)
			-- Stamped so the client's recolour tool can read a tile's current tint.
			part:SetAttribute("TintColor", tile.Color)
			part.Parent = container
		end
	end
end

--[[Returns (creating if needed) the folder holding a plot's ceiling slabs.]]
local function getCeilingContainer(plot): Folder
	local container = plot.Model:FindFirstChild("Ceilings")
	if not container then
		container = Instance.new("Folder")
		container.Name = "Ceilings"
		container.Parent = plot.Model
	end
	return container
end

--[[Renders a cell-sized ceiling slab from its stored top-surface offset. Its top is flush
with the selected level top (the next floor surface) and its thickness hangs below it.]]
local function renderCeiling(
	plot,
	x: number,
	z: number,
	floor: number,
	topOffset: number,
	materialIndex: number,
	color: number?
)
	local container = getCeilingContainer(plot)
	local key = Grid.ceilingKey(x, z, floor)
	local slab = container:FindFirstChild(key)

	local grid = plot:GetGrid()
	local centre = grid:GetCellCenter(x, z)
	local topY = grid.Origin.Y + topOffset

	if not slab then
		slab = Instance.new("Part")
		slab.Name = key
		slab.Anchored = true
		slab.Size = Vector3.new(Building.CELL_SIZE, Building.CEILING_THICKNESS, Building.CELL_SIZE)
	end
	slab:SetAttribute("GridX", x)
	slab:SetAttribute("GridZ", z)
	slab:SetAttribute("Floor", floor)
	slab:SetAttribute("TopOffset", topOffset)
	slab:SetAttribute("MaterialIndex", materialIndex)
	slab:SetAttribute("TintColor", color)
	slab.Material = (Enum.Material :: any)[Materials.Ceiling[materialIndex].Material]
	slab.Color = SharedColorService:MaterialColor("Ceiling", materialIndex, color)
	slab.CFrame = CFrame.new(centre.X, topY - Building.CEILING_THICKNESS / 2, centre.Z)
	slab.Parent = container
end

--[[Removes a ceiling slab.]]
local function derenderCeiling(plot, x: number, z: number, floor: number)
	local slab = getCeilingContainer(plot):FindFirstChild(Grid.ceilingKey(x, z, floor))
	if slab then
		slab:Destroy()
	end
end

local function clearRendered(plot)
	for _, name in { "Built", "Ceilings", "Floor" } do
		local container = plot.Model:FindFirstChild(name)
		if container then
			container:Destroy()
		end
	end
end

local function emptyPlot(plot)
	local base = plot.Model:FindFirstChild("Plot") :: BasePart
	clearRendered(plot)
	plot:SetGrid(Grid.new(base))
end

local function renderGrid(plot)
	local grid = plot:GetGrid()
	for _, placement in grid:GetPlacements() do
		render(plot, placement)
	end
	for _, ceiling in grid:GetCeilings() do
		renderCeiling(plot, ceiling.X, ceiling.Z, ceiling.Floor, ceiling.TopOffset, ceiling.Material, ceiling.Color)
	end
	local floors = {}
	for _, floorEntry in grid:GetFloorEntries() do
		floors[floorEntry.Floor] = true
	end
	for floor in floors do
		remeshFloor(plot, floor)
	end
end

local function loadPlot(player: Player, plot)
	AssignedPlots[player] = plot
	task.spawn(function()
		local profile = DataSaveService:WaitForProfile(player)
		if not profile or AssignedPlots[player] ~= plot or plot:GetOwner() ~= player then
			return
		end
		local base = plot.Model:FindFirstChild("Plot") :: BasePart
		local build = profile.Data.Build
		local blob = if build.Serialize then build:Serialize() else build
		local grid = Grid.Decompress(blob, base, function(name, x, z, floor, rotation)
			return SharedBuildingService:ResolveOccupancy(name, x, z, floor, rotation)
		end)
		-- Linked placements save no colours; they wear whatever the palette says NOW.
		-- A palette that no longer exists simply unlinks back to authored defaults.
		for _, placement in grid:GetPlacements() do
			if placement.Linked then
				local palette = getPalette(player, placement.Name)
				placement.Colors = palette
				placement.Linked = palette ~= nil
			end
		end
		clearRendered(plot)
		plot:SetGrid(grid)
		renderGrid(plot)
		Histories[player] = nil
	end)
end

--[[Snapshots a cell's explicit floor tile. Material 0 means "no tile here".]]
local function copyFloor(grid: Grid.Grid, x: number, z: number, floor: number): FloorState
	local entry = grid:GetFloorEntry(x, z, floor)
	return if entry then { Material = entry.Material, Color = entry.Color } else { Material = 0 }
end

local function copyCeiling(entry: Grid.CeilingEntry?): CeilingState?
	return if entry
		then { TopOffset = entry.TopOffset, Material = entry.Material, Color = entry.Color }
		else nil
end

-- Applies one compact transaction side directly to the authoritative grid. History is
-- linear and LIFO, so these states were already validated when originally committed.
local function applyHistory(plot, entry: HistoryEntry, after: boolean)
	local grid = plot:GetGrid()
	if entry.Kind == "Placement" then
		for _, change in entry.Changes do
			local shouldExist = if after then change.AfterPresent else change.BeforePresent
			local id = change.Placement.Id
			if shouldExist and not grid:GetPlacement(id) then
				grid:AddPlacement(change.Placement)
				render(plot, grid:GetPlacement(id))
			elseif not shouldExist and grid:RemovePlacement(id) then
				derender(plot, id)
			end
		end
	elseif entry.Kind == "Color" then
		for _, change in entry.Changes do
			local colors = if after then change.AfterColors else change.BeforeColors
			local linked = if after then change.AfterLinked else change.BeforeLinked
			if grid:SetPlacementColors(change.Id, colors, linked) then
				rerender(plot, grid:GetPlacement(change.Id))
			end
		end
	elseif entry.Kind == "Floor" then
		local dirtyFloors = {}
		for _, change in entry.Changes do
			local state = if after then change.After else change.Before
			grid:SetFloorMaterial(change.X, change.Z, change.Floor, state.Material, state.Color)
			dirtyFloors[change.Floor] = true
		end
		for floor in dirtyFloors do
			remeshFloor(plot, floor)
		end
	else
		local dirtyFloors = {}
		for _, change in entry.Changes do
			local ceiling = if after then change.AfterCeiling else change.BeforeCeiling
			if ceiling then
				grid:SetCeiling(change.X, change.Z, change.Floor, ceiling.TopOffset, ceiling.Material, ceiling.Color)
				renderCeiling(
					plot,
					change.X,
					change.Z,
					change.Floor,
					ceiling.TopOffset,
					ceiling.Material,
					ceiling.Color
				)
			else
				grid:RemoveCeiling(change.X, change.Z, change.Floor)
				derenderCeiling(plot, change.X, change.Z, change.Floor)
			end
			local floorState = if after then change.AfterFloor else change.BeforeFloor
			grid:SetFloorMaterial(change.X, change.Z, change.Floor + 1, floorState.Material, floorState.Color)
			dirtyFloors[change.Floor + 1] = true
		end
		for floor in dirtyFloors do
			remeshFloor(plot, floor)
		end
	end
	persist(plot)
end

local function stepHistory(player: Player, redo: boolean): (boolean, string?)
	local history = Histories[player]
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not history or not plot then
		return false, if redo then "nothing to redo" else "nothing to undo"
	end
	local source = if redo then history.Redo else history.Undo
	local target = if redo then history.Undo else history.Redo
	local entry = table.remove(source)
	if not entry then
		return false, if redo then "nothing to redo" else "nothing to undo"
	end
	applyHistory(plot, entry, redo)
	table.insert(target, entry)
	return true
end

function ServerBuildingService:ResetBase(player: Player): boolean
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return false
	end
	emptyPlot(plot)
	Histories[player] = nil
	persist(plot)
	return true
end

-- Validates and commits one placement without persisting, so clicks and drags share
-- exactly one authoritative path.
local function placeOne(
	plot,
	name: string,
	x: number,
	z: number,
	floor: number,
	rotation: number,
	colors: SharedColorService.SlotMap?,
	linked: boolean?
): (number?, string?)
	local grid = plot:GetGrid()
	local ok, reason = SharedBuildingService:CanPlace(grid, name, x, z, floor, rotation)
	if not ok then
		return nil, reason
	end
	-- TODO: verify the player can afford this asset and deduct the cost here, before commit.
	local cells, edges = SharedBuildingService:ResolveOccupancy(name, x, z, floor, rotation)
	local id = grid:AddPlacement({
		Name = name,
		X = x,
		Z = z,
		Floor = floor,
		Rotation = rotation,
		Cells = cells,
		Edges = edges,
		Colors = colors,
		Linked = linked,
	})
	render(plot, grid:GetPlacement(id))
	return id
end

--[[Places every valid request. An ordinary click is simply a one-entry request list.
One colour map applies to the whole batch - a drag paints every copy the same.]]
function ServerBuildingService:Place(
	player: Player,
	name: string,
	requests: { PlacementRequest },
	colors: any,
	usePalette: boolean?
): (number, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, "no plot"
	end
	local grid = plot:GetGrid()
	local entry = SharedBuildingService:GetEntry(name)
	if not entry or (#requests > 1 and not entry.Draggable) then
		return 0, "asset is not draggable"
	end
	if #requests < 1 or #requests > grid.Width * grid.Depth then
		return 0, "invalid drag"
	end

	-- Client-supplied colours are never trusted: unknown slots and out-of-range values
	-- are dropped, and anything matching the authored default is stripped so it costs
	-- nothing to save. When the client asks for its saved palette we resolve that here
	-- rather than believing the colours it sent, so a link can't misrepresent itself.
	local palette = if usePalette then getPalette(player, name) else nil
	local linked = palette ~= nil
	local cleanColors = if linked then palette else SharedColorService:Sanitize(name, colors)

	local placed = 0
	local firstReason: string? = nil
	local changes: { PlacementChange } = {}
	for _, request in requests do
		local id, reason =
			placeOne(plot, name, request.X, request.Z, request.Floor, request.Rotation, cleanColors, linked)
		if not id then
			firstReason = firstReason or reason
			continue
		end
		placed += 1
		local placement = grid:GetPlacement(id)
		if placement then
			table.insert(changes, { Placement = placement, BeforePresent = false, AfterPresent = true })
		end
	end
	if placed > 0 then
		pushHistory(player, { Kind = "Placement", Changes = changes })
		persist(plot)
	end
	return placed, firstReason
end

--[[
Removes placements by id. Each id comes from the PlacementId attribute on a rendered
instance (which the client can read), so this works for any type - content or walls
(which live on edges and can't be found by a cell lookup). Only ids in the player's own
plot grid exist there, so a client can only remove its own builds. Returns success.
]]
function ServerBuildingService:Remove(player: Player, placementIds: { number }): number
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0
	end
	local grid = plot:GetGrid()
	if #placementIds < 1 or #placementIds > grid.Width * grid.Depth then
		return 0
	end
	local removed, seen = 0, {}
	local changes: { PlacementChange } = {}
	for _, placementId in placementIds do
		if not seen[placementId] then
			local placement = grid:RemovePlacement(placementId)
			seen[placementId] = true
			if not placement then
				continue
			end
			derender(plot, placementId)
			table.insert(changes, { Placement = placement, BeforePresent = true, AfterPresent = false })
			removed += 1
		end
	end
	if removed > 0 then
		pushHistory(player, { Kind = "Placement", Changes = changes })
		persist(plot)
	end
	return removed
end

--[[
Recolours existing placements by id, the same id source as :Remove (so a client can only
recolour builds in its own plot grid). Colours are sanitised per placement, since each id
may be a different asset with different slots. Placements already showing the requested
colours are skipped so a no-op click doesn't push a dead undo entry. Returns the count.
]]
function ServerBuildingService:Recolor(
	player: Player,
	placementIds: { number },
	colors: any,
	usePalette: boolean?
): (number, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, "no plot"
	end
	local grid = plot:GetGrid()
	if #placementIds < 1 or #placementIds > grid.Width * grid.Depth then
		return 0, "invalid request"
	end

	local recolored, seen = 0, {}
	local changes: { ColorChange } = {}
	for _, placementId in placementIds do
		if seen[placementId] then
			continue
		end
		seen[placementId] = true

		local placement = grid:GetPlacement(placementId)
		if not placement then
			continue
		end
		local before, wasLinked = placement.Colors, placement.Linked
		-- Picking colours directly means the object is no longer wearing the palette, so
		-- it unlinks and stops following future palette edits.
		local palette = if usePalette then getPalette(player, placement.Name) else nil
		local linked = palette ~= nil
		local after = if linked then palette else SharedColorService:Sanitize(placement.Name, colors)
		if SharedColorService:Equal(before, after) and wasLinked == linked then
			continue
		end

		grid:SetPlacementColors(placementId, after, linked)
		rerender(plot, placement)
		table.insert(changes, {
			Id = placementId,
			BeforeColors = before,
			AfterColors = after,
			BeforeLinked = wasLinked,
			AfterLinked = linked,
		})
		recolored += 1
	end

	if recolored > 0 then
		pushHistory(player, { Kind = "Color", Changes = changes })
		persist(plot)
	end
	-- No reason on 0: the request was fine, the objects already looked like this. Only
	-- genuine failures above return one, so callers can tell the two apart.
	return recolored, nil
end

-- ===== Saved palette operations =============================================
--[[
These sit OUTSIDE undo by design: they can rewrite the colours of an entire plot at once,
and the undo stack records concrete before/after colour states that a palette sweep would
silently invalidate. Rather than leave stale entries that could restore colours onto
objects that have since moved to a palette, a sweep clears the history.
]]

--[[Links every placement of one asset that passes `predicate` to `colors`.]]
local function sweepPalette(
	plot,
	name: string,
	predicate: (Grid.Placement) -> boolean,
	colors: SharedColorService.SlotMap
): number
	local changed = 0
	for _, placement in plot:GetGrid():GetPlacements() do
		if placement.Name == name and predicate(placement) then
			placement.Colors = colors
			placement.Linked = true
			rerender(plot, placement)
			changed += 1
		end
	end
	return changed
end

local function isLinked(placement: Grid.Placement): boolean
	return placement.Linked == true
end

--[[
Saves (or replaces) the player's palette for one asset.

`propagate` only matters when a palette already existed and objects are linked to it:
  true  - linked objects move to the new colours and stay linked.
  false - linked objects keep the colours they're wearing and unlink, becoming ordinary
          custom colours that happen to match the palette's previous state.
Either way the palette itself is updated, and `placementId` - the object the palette was
just defined from - ends up wearing and linked to it. Doing that here rather than in a
follow-up Recolor call keeps it in one transaction: a second call would find the object
already correct whenever the sweep had reached it, and report that as a failure.
]]
function ServerBuildingService:SavePalette(
	player: Player,
	name: string,
	colors: any,
	propagate: boolean?,
	paletteName: any,
	placementId: any
): (boolean, string?, number)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return false, "no plot", 0
	end
	if not SharedColorService:IsColorable(name) then
		return false, "asset has no colour slots", 0
	end
	local clean = SharedColorService:Sanitize(name, colors)
	if not clean then
		return false, "palette is identical to the item's default colours", 0
	end

	local label = if type(paletteName) == "string" and #paletteName > 0
		then string.sub(paletteName, 1, 32)
		else "Custom"
	local existing = getPalette(player, name)
	setPalette(player, name, clean, label)

	local touched = 0
	if existing and not SharedColorService:Equal(existing, clean) then
		if propagate then
			touched = sweepPalette(plot, name, isLinked, clean)
		else
			-- A linked object is already wearing the palette's previous colours, so
			-- unlinking is just dropping the flag - nothing to repaint.
			for _, placement in plot:GetGrid():GetPlacements() do
				if placement.Name == name and placement.Linked then
					placement.Linked = nil
					rerender(plot, placement)
					touched += 1
				end
			end
		end
	end

	-- The object the palette was defined from always adopts it, whichever way the
	-- propagate question was answered.
	local source = if isGridInteger(placementId) then plot:GetGrid():GetPlacement(placementId) else nil
	if source and source.Name == name then
		source.Colors = clean
		source.Linked = true
		rerender(plot, source)
		touched += 1
	end

	if touched > 0 then
		Histories[player] = nil
	end
	persist(plot)
	return true, nil, touched
end

--[[
Returns how many placements of an asset exist and how many are linked to the saved
palette. The client asks before opening a confirmation, because counting from the
PaletteLinked attributes locally races replication - right after a save those attributes
are still in flight, and a stale count made "update all" sweep nothing.
]]
function ServerBuildingService:PaletteInfo(player: Player, name: string): (number, number)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, 0
	end
	local total, linked = 0, 0
	for _, placement in plot:GetGrid():GetPlacements() do
		if placement.Name == name then
			total += 1
			if placement.Linked then
				linked += 1
			end
		end
	end
	return total, linked
end

--[[Links every placement of an asset to the saved palette and recolours them.]]
function ServerBuildingService:ApplyPalette(player: Player, name: string): (number, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, "no plot"
	end
	local palette = getPalette(player, name)
	if not palette then
		return 0, "no saved palette"
	end

	local changed = sweepPalette(plot, name, function(placement)
		return not placement.Linked or not SharedColorService:Equal(placement.Colors, palette)
	end, palette)

	if changed > 0 then
		Histories[player] = nil
		persist(plot)
	end
	return changed, if changed > 0 then nil else "everything already matches"
end

--[[
Retints one structural divider: the ceiling capping `ceilingFloor` and the floor tile
resting on top of it, which are the two faces of the same slab. Color 1 is the ceiling
underside, Color 2 the floor above. Materials are untouched, and whichever face isn't
built is skipped. `ceilingFloor` of 0 means the plot base, which has no ceiling.
]]
function ServerBuildingService:PaintSurface(
	player: Player,
	requests: { CellRequest },
	ceilingFloor: number,
	colors: any
): (number, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, "no plot"
	end
	local grid = plot:GetGrid()
	if ceilingFloor < 0 or ceilingFloor % 1 ~= 0 or #requests < 1 or #requests > grid.Width * grid.Depth then
		return 0, "invalid request"
	end
	if type(colors) ~= "table" then
		return 0, "bad request"
	end

	local floorLevel = ceilingFloor + 1
	local painted, seen = 0, {}
	local changes: { CeilingChange } = {}

	for _, request in requests do
		local key = `{request.X},{request.Z}`
		if seen[key] then
			continue
		end
		seen[key] = true

		local ceiling = if ceilingFloor >= 1 then copyCeiling(grid:GetCeiling(request.X, request.Z, ceilingFloor)) else nil
		local tile = grid:GetFloorEntry(request.X, request.Z, floorLevel)
		local beforeFloor = copyFloor(grid, request.X, request.Z, floorLevel)

		local newCeiling = ceiling
		if ceiling then
			local tint = SharedColorService:SanitizeMaterialColor("Ceiling", ceiling.Material, colors[1])
			if tint ~= ceiling.Color then
				grid:SetCeiling(request.X, request.Z, ceilingFloor, ceiling.TopOffset, ceiling.Material, tint)
				renderCeiling(plot, request.X, request.Z, ceilingFloor, ceiling.TopOffset, ceiling.Material, tint)
				newCeiling = copyCeiling(grid:GetCeiling(request.X, request.Z, ceilingFloor))
			end
		end

		local afterFloor = beforeFloor
		if tile then
			local tint = SharedColorService:SanitizeMaterialColor("Floor", tile.Material, colors[2])
			if tint ~= tile.Color then
				grid:SetFloorMaterial(request.X, request.Z, floorLevel, tile.Material, tint)
				afterFloor = copyFloor(grid, request.X, request.Z, floorLevel)
			end
		end

		if newCeiling ~= ceiling or afterFloor ~= beforeFloor then
			table.insert(changes, {
				X = request.X,
				Z = request.Z,
				Floor = ceilingFloor,
				BeforeCeiling = ceiling,
				AfterCeiling = newCeiling,
				BeforeFloor = beforeFloor,
				AfterFloor = afterFloor,
			})
			painted += 1
		end
	end

	if painted > 0 then
		pushHistory(player, { Kind = "Ceiling", Changes = changes })
		remeshFloor(plot, floorLevel)
		persist(plot)
	end
	return painted, nil
end

--[[
Removes a ceiling and clears the painted tile that rested on it one level above.
]]
function ServerBuildingService:RemoveCeiling(player: Player, requests: { CellRequest }, floor: number): number
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0
	end

	local grid = plot:GetGrid()
	if floor < 1 or floor % 1 ~= 0 or #requests < 1 or #requests > grid.Width * grid.Depth then
		return 0
	end
	local removed, seen = 0, {}
	local changes: { CeilingChange } = {}
	for _, request in requests do
		local key = `{request.X},{request.Z}`
		local ceiling = if not seen[key] then copyCeiling(grid:GetCeiling(request.X, request.Z, floor)) else nil
		local occupantId = grid:GetCellOccupant(request.X, request.Z, floor)
		local occupant = occupantId and grid:GetPlacement(occupantId)
		local occupantEntry = occupant and SharedBuildingService:GetEntry(occupant.Name)
		local supportsHanger = occupantEntry and occupantEntry.Type == "Hanger"
		if ceiling and not supportsHanger and grid:RemoveCeiling(request.X, request.Z, floor) then
			local beforeFloor = copyFloor(grid, request.X, request.Z, floor + 1)
			grid:SetFloorMaterial(request.X, request.Z, floor + 1, 0)
			derenderCeiling(plot, request.X, request.Z, floor)
			table.insert(changes, {
				X = request.X,
				Z = request.Z,
				Floor = floor,
				BeforeCeiling = ceiling,
				AfterCeiling = nil,
				BeforeFloor = beforeFloor,
				AfterFloor = { Material = 0 },
			})
			removed += 1
		end
		seen[key] = true
	end
	if removed > 0 then
		pushHistory(player, { Kind = "Ceiling", Changes = changes })
		remeshFloor(plot, floor + 1)
		persist(plot)
	end
	return removed
end

-- Client entry points (RemoteFunctions so the client gets accept/reject feedback for
-- its preview). Basic numeric guards keep malformed requests from erroring the grid;
-- full validation lives in :Place / :Remove. TODO: per-player rate limiting.
placeRemote.OnServerInvoke = function(player, name, requests, colors, usePalette)
	if type(name) ~= "string" or not isRequestList(requests, isPlacementRequest) then
		return 0, "bad request"
	end
	-- `colors` needs no shape guard here; SharedColorService:Sanitize rejects anything
	-- that isn't a table of valid slot -> packed-colour pairs.
	return ServerBuildingService:Place(player, name, requests, colors, usePalette == true)
end

recolorRemote.OnServerInvoke = function(player, placementIds, colors, usePalette)
	if not isRequestList(placementIds, isGridInteger) then
		return 0, "bad request"
	end
	return ServerBuildingService:Recolor(player, placementIds, colors, usePalette == true)
end

paletteRemote.OnServerInvoke = function(player, action, name, colors, propagate, paletteName, placementId)
	if type(name) ~= "string" then
		return false, "bad request"
	end
	if action == "save" then
		return ServerBuildingService:SavePalette(player, name, colors, propagate == true, paletteName, placementId)
	elseif action == "apply" then
		return ServerBuildingService:ApplyPalette(player, name)
	elseif action == "info" then
		return ServerBuildingService:PaletteInfo(player, name)
	end
	return false, "bad request"
end

removeRemote.OnServerInvoke = function(player, placementIds)
	if not isRequestList(placementIds, isGridInteger) then
		return 0
	end
	return ServerBuildingService:Remove(player, placementIds)
end

-- `color` needs no shape guard on these; SharedColorService:SanitizeMaterialColor
-- rejects anything that isn't an in-range packed integer.
paintRemote.OnServerInvoke = function(player, requests, floor, materialIndex, color)
	if not isRequestList(requests, isCellRequest) or not (isGridInteger(floor) and isGridInteger(materialIndex)) then
		return 0, "bad request"
	end
	return ServerBuildingService:PaintFloor(player, requests, floor, materialIndex, color)
end

ceilingRemote.OnServerInvoke = function(player, action, target, second, third, fourth)
	if action == "place" then
		if not isRequestList(target, isCellRequest) or not (isGridInteger(second) and isGridInteger(third)) then
			return 0, "bad request"
		end
		return ServerBuildingService:PlaceCeiling(player, target, second, third, fourth)
	elseif action == "surface" then
		if not isRequestList(target, isCellRequest) or not isGridInteger(second) then
			return 0, "bad request"
		end
		return ServerBuildingService:PaintSurface(player, target, second, third)
	elseif action == "remove" then
		if isRequestList(target, isCellRequest) and isGridInteger(second) then
			return ServerBuildingService:RemoveCeiling(player, target, second)
		end
	end
	return false
end

historyRemote.OnServerInvoke = function(player, action)
	if action == "undo" then
		return stepHistory(player, false)
	elseif action == "redo" then
		return stepHistory(player, true)
	elseif action == "clear" then
		Histories[player] = nil
		return true
	end
	return false, "bad request"
end

resetRemote.OnServerInvoke = function(player)
	return ServerBuildingService:ResetBase(player)
end

ServerPlotService.PlotAssigned:Connect(function(player, plotNumber)
	local plot = ServerPlotService:GetPlot(plotNumber)
	if plot then
		loadPlot(player, plot)
	end
end)
ServerPlotService.PlotReleased:Connect(function(player, plotNumber)
	local plot = ServerPlotService:GetPlot(plotNumber)
	if not plot then
		return
	end
	AssignedPlots[player] = nil
	persist(plot, player)
	emptyPlot(plot)
	Histories[player] = nil
end)

for _, player in Players:GetPlayers() do
	local plot = ServerPlotService:GetPlayerPlot(player)
	if plot then
		loadPlot(player, plot)
	end
end

Players.PlayerRemoving:Connect(function(player)
	Histories[player] = nil
	AssignedPlots[player] = nil
end)

return ServerBuildingService
