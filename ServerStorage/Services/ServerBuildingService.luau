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
local DataSaveService = require(ReplicatedStorage.Services.DataSaveService)
local ServerPlotService = require(ServerStorage.Services.ServerPlotService)
local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local Grid = require(ReplicatedStorage.Classes.Grid)

local ServerBuildingService = {}

type PlacementRequest = { X: number, Z: number, Floor: number, Rotation: number }
type CellRequest = { X: number, Z: number }
type PlacementChange = { Placement: Grid.Placement, BeforePresent: boolean, AfterPresent: boolean }
type FloorChange = { X: number, Z: number, Floor: number, BeforeMaterial: number, AfterMaterial: number }
type CeilingState = { TopOffset: number, Material: number }
type CeilingChange = {
	X: number,
	Z: number,
	Floor: number,
	BeforeCeiling: CeilingState?,
	AfterCeiling: CeilingState?,
	BeforeFloorMaterial: number,
	AfterFloorMaterial: number,
}
type HistoryEntry =
	{ Kind: "Placement", Changes: { PlacementChange } }
	| { Kind: "Floor", Changes: { FloorChange } }
	| { Kind: "Ceiling", Changes: { CeilingChange } }
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
asset model, rotates it, and rests it on the plot's floor surface at its pivot cell.

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

	-- First place it on the correct X/Z edge or cell, then bottom-align its actual bounds
	-- to the level surface. Model pivots are not required to be centred.
	local groundCF = SharedBuildingService:GetPlacementCFrame(grid, placement.Name, placement.X, placement.Z, placement.Rotation)
	if groundCF then
		SharedBuildingService:PivotModelToLevel(clone, groundCF, grid.Origin.Y, placement.Floor)
	end

	clone.Parent = getBuildContainer(plot)
end

--[[Removes the rendered instance for a placement id.]]
local function derender(plot, placementId)
	for _, child in getBuildContainer(plot):GetChildren() do
		if child:GetAttribute("PlacementId") == placementId then
			child:Destroy()
		end
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
local function floorTileAt(grid, x: number, z: number, floor: number): ({ Material: number, SurfaceY: number }?)
	local entry = grid:GetFloorEntry(x, z, floor)
	if not entry then
		return nil
	end
	if floor == 1 then
		return { Material = entry.Material, SurfaceY = grid.Origin.Y }
	end
	local ceiling = grid:GetCeiling(x, z, floor - 1)
	if not ceiling then
		return nil
	end
	return { Material = entry.Material, SurfaceY = grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(floor) }
end

--[[
Re-meshes an entire floor: destroys its existing tiles and rebuilds them as merged
rectangles via greedy meshing, so a run of same-material cells becomes one part instead
of many. Cells only merge if they share both material and top-Y. (TODO(perf): re-mesh
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
				return other ~= nil and other.Material == tile.Material and other.SurfaceY == tile.SurfaceY
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
			part.Material = (Enum.Material :: any)[Materials.Floor[tile.Material]]
			-- The overlay's bottom rests directly on its supporting surface.
			part.CFrame = CFrame.new(
				grid.Origin.X + (x + w / 2) * cell,
				tile.SurfaceY + Building.FLOOR_THICKNESS / 2,
				grid.Origin.Z + (z + h / 2) * cell
			)
			part:SetAttribute("FloorLevel", floor)
			part:SetAttribute("MaterialIndex", tile.Material)
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
local function renderCeiling(plot, x: number, z: number, floor: number, topOffset: number, materialIndex: number)
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
	slab.Material = (Enum.Material :: any)[Materials.Ceiling[materialIndex]]
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
		renderCeiling(plot, ceiling.X, ceiling.Z, ceiling.Floor, ceiling.TopOffset, ceiling.Material)
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
		clearRendered(plot)
		plot:SetGrid(grid)
		renderGrid(plot)
		Histories[player] = nil
	end)
end

local function explicitFloorMaterial(grid: Grid.Grid, x: number, z: number, floor: number): number
	local entry = grid:GetFloorEntry(x, z, floor)
	return if entry then entry.Material else 0
end

local function copyCeiling(entry: Grid.CeilingEntry?): CeilingState?
	return if entry then { TopOffset = entry.TopOffset, Material = entry.Material } else nil
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
	elseif entry.Kind == "Floor" then
		local dirtyFloors = {}
		for _, change in entry.Changes do
			grid:SetFloorMaterial(
				change.X,
				change.Z,
				change.Floor,
				if after then change.AfterMaterial else change.BeforeMaterial
			)
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
				grid:SetCeiling(change.X, change.Z, change.Floor, ceiling.TopOffset, ceiling.Material)
				renderCeiling(plot, change.X, change.Z, change.Floor, ceiling.TopOffset, ceiling.Material)
			else
				grid:RemoveCeiling(change.X, change.Z, change.Floor)
				derenderCeiling(plot, change.X, change.Z, change.Floor)
			end
			grid:SetFloorMaterial(
				change.X,
				change.Z,
				change.Floor + 1,
				if after then change.AfterFloorMaterial else change.BeforeFloorMaterial
			)
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
local function placeOne(plot, name: string, x: number, z: number, floor: number, rotation: number): (number?, string?)
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
	})
	render(plot, grid:GetPlacement(id))
	return id
end

--[[Places every valid request. An ordinary click is simply a one-entry request list.]]
function ServerBuildingService:Place(player: Player, name: string, requests: { PlacementRequest }): (number, string?)
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

	local placed = 0
	local firstReason: string? = nil
	local changes: { PlacementChange } = {}
	for _, request in requests do
		local id, reason = placeOne(plot, name, request.X, request.Z, request.Floor, request.Rotation)
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

--[[Paints every changed, valid request and remeshes once. A click sends one request.]]
function ServerBuildingService:PaintFloor(
	player: Player,
	requests: { CellRequest },
	floor: number,
	materialIndex: number
): (number, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, "no plot"
	end
	if floor < 1 or floor % 1 ~= 0 then
		return 0, "invalid floor"
	end
	if materialIndex < 0 or materialIndex > #Materials.Floor then
		return 0, "invalid material"
	end
	local grid = plot:GetGrid()
	if #requests < 1 or #requests > grid.Width * grid.Depth then
		return 0, "invalid drag"
	end

	local painted = 0
	local seen = {}
	local changes: { FloorChange } = {}
	for _, request in requests do
		local key = `{request.X},{request.Z}`
		local entry = grid:GetFloorEntry(request.X, request.Z, floor)
		local unchanged = if entry then entry.Material == materialIndex else floor == 1 and materialIndex == 1
		local valid = not seen[key] and grid:IsInBounds(request.X, request.Z)
			and (if materialIndex == 0
				then entry ~= nil
				else not unchanged and SharedBuildingService:CanPaintFloor(grid, request.X, request.Z, floor))
		seen[key] = true
		if valid then
			local beforeMaterial = explicitFloorMaterial(grid, request.X, request.Z, floor)
			grid:SetFloorMaterial(request.X, request.Z, floor, materialIndex)
			table.insert(changes, {
				X = request.X,
				Z = request.Z,
				Floor = floor,
				BeforeMaterial = beforeMaterial,
				AfterMaterial = explicitFloorMaterial(grid, request.X, request.Z, floor),
			})
			painted += 1
		end
	end
	if painted > 0 then
		pushHistory(player, { Kind = "Floor", Changes = changes })
		remeshFloor(plot, floor)
		persist(plot)
	end
	return painted, if painted > 0 then nil else "no changed floor cells"
end

--[[Places every available requested slab. The same path handles clicks and area drags.]]
function ServerBuildingService:PlaceCeiling(
	player: Player,
	requests: { CellRequest },
	floor: number,
	materialIndex: number
): (number, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return 0, "no plot"
	end
	if floor < 1 or floor % 1 ~= 0 then
		return 0, "invalid floor"
	end
	if materialIndex < 1 or materialIndex > #Materials.Ceiling then
		return 0, "invalid material"
	end
	local grid = plot:GetGrid()
	if #requests < 1 or #requests > grid.Width * grid.Depth then
		return 0, "invalid drag"
	end

	local placed = SharedBuildingService:FillCeilings(grid, requests, floor, materialIndex)
	local changes: { CeilingChange } = {}
	for _, result in placed do
		renderCeiling(plot, result.X, result.Z, floor, result.TopOffset, materialIndex)
		local floorMaterial = explicitFloorMaterial(grid, result.X, result.Z, floor + 1)
		table.insert(changes, {
			X = result.X,
			Z = result.Z,
			Floor = floor,
			BeforeCeiling = nil,
			AfterCeiling = copyCeiling(grid:GetCeiling(result.X, result.Z, floor)),
			BeforeFloorMaterial = floorMaterial,
			AfterFloorMaterial = floorMaterial,
		})
	end
	if #placed > 0 then
		pushHistory(player, { Kind = "Ceiling", Changes = changes })
		persist(plot)
	end
	return #placed, if #placed > 0 then nil else "no available floor cells"
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
		if ceiling and grid:RemoveCeiling(request.X, request.Z, floor) then
			local floorMaterial = explicitFloorMaterial(grid, request.X, request.Z, floor + 1)
			grid:SetFloorMaterial(request.X, request.Z, floor + 1, 0)
			derenderCeiling(plot, request.X, request.Z, floor)
			table.insert(changes, {
				X = request.X,
				Z = request.Z,
				Floor = floor,
				BeforeCeiling = ceiling,
				AfterCeiling = nil,
				BeforeFloorMaterial = floorMaterial,
				AfterFloorMaterial = 0,
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
placeRemote.OnServerInvoke = function(player, name, requests)
	if type(name) ~= "string" or not isRequestList(requests, isPlacementRequest) then
		return 0, "bad request"
	end
	return ServerBuildingService:Place(player, name, requests)
end

removeRemote.OnServerInvoke = function(player, placementIds)
	if not isRequestList(placementIds, isGridInteger) then
		return 0
	end
	return ServerBuildingService:Remove(player, placementIds)
end

paintRemote.OnServerInvoke = function(player, requests, floor, materialIndex)
	if not isRequestList(requests, isCellRequest) or not (isGridInteger(floor) and isGridInteger(materialIndex)) then
		return 0, "bad request"
	end
	return ServerBuildingService:PaintFloor(player, requests, floor, materialIndex)
end

ceilingRemote.OnServerInvoke = function(player, action, target, second, third)
	if action == "place" then
		if not isRequestList(target, isCellRequest) or not (isGridInteger(second) and isGridInteger(third)) then
			return 0, "bad request"
		end
		return ServerBuildingService:PlaceCeiling(player, target, second, third)
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
