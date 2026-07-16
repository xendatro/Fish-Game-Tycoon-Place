--[[
ServerBuildingService - the authority for building. It:
  * receives place/remove requests from clients,
  * validates them with SharedBuildingService (the same rules the client predicted),
  * mutates the owning plot's Grid,
  * renders the result on the server (so it replicates to everyone),
  * charges money and persists the compressed grid into the profile.

Rendering, money, and persistence are stubbed below with clear TODOs - the request
-> validate -> commit pipeline and the plumbing are in place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SharedBuildingService = require(ReplicatedStorage.Services.SharedBuildingService)
local ServerPlotService = require(ServerStorage.Services.ServerPlotService)
local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local Grid = require(ReplicatedStorage.Classes.Grid)

local ServerBuildingService = {}

type PlacementRequest = { X: number, Z: number, Floor: number, Rotation: number }
type CellRequest = { X: number, Z: number }

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

--[[Marks a plot's grid dirty so its compressed form is written back to the owner's
profile (debounced). TODO: wire to DataSaveService profile field + debounce.]]
local function persist(_plot)
	-- local blob = plot:GetGrid():Compress()
	-- write blob into DataSaveService:GetProfile(plot.Owner).Data.Build (debounced)
end

--[[TODO(load): on profile load, rebuild the plot's grid from its saved blob via
Grid.Decompress(blob, basePart, resolver), where resolver wraps
SharedBuildingService:ResolveOccupancy, then render each placement.]]

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
world Y of its top surface - or nil if the cell has no tile. Grass (material 1) renders
nothing (base/ceiling shows through). Elevated tiles sit on the ceiling one level below.
]]
local function floorTileAt(grid, x: number, z: number, floor: number): ({ Material: number, TopY: number }?)
	local material = grid:GetFloorMaterial(x, z, floor)
	if material <= 1 then
		return nil
	end
	if floor == 1 then
		return { Material = material, TopY = grid.Origin.Y }
	end
	local ceiling = grid:GetCeiling(x, z, floor - 1)
	if not ceiling then
		return nil
	end
	return { Material = material, TopY = grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(floor) }
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
				return other ~= nil and other.Material == tile.Material and other.TopY == tile.TopY
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
			part.Size = Vector3.new(w * cell, 0.2, h * cell)
			part.Material = (Enum.Material :: any)[Materials.Floor[tile.Material]]
			-- Sit a hair above the surface to avoid z-fighting.
			part.CFrame = CFrame.new(
				grid.Origin.X + (x + w / 2) * cell,
				tile.TopY + 0.1,
				grid.Origin.Z + (z + h / 2) * cell
			)
			part:SetAttribute("FloorLevel", floor)
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
with the supporting wall top (the next floor surface) and the thickness hangs below it.]]
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
	for _, request in requests do
		local id, reason = placeOne(plot, name, request.X, request.Z, request.Floor, request.Rotation)
		if not id then
			firstReason = firstReason or reason
			continue
		end
		placed += 1
	end
	if placed > 0 then
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
	for _, placementId in placementIds do
		if not seen[placementId] and grid:RemovePlacement(placementId) then
			seen[placementId] = true
			derender(plot, placementId)
			removed += 1
		end
	end
	if removed > 0 then
		persist(plot)
	end
	return removed
end

--[[Paints every valid request and remeshes once. A click sends one request.]]
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
	if materialIndex < 1 or materialIndex > #Materials.Floor then
		return 0, "invalid material"
	end
	local grid = plot:GetGrid()
	if #requests < 1 or #requests > grid.Width * grid.Depth then
		return 0, "invalid drag"
	end

	local painted = 0
	local seen = {}
	for _, request in requests do
		local key = `{request.X},{request.Z}`
		local valid = not seen[key] and SharedBuildingService:CanPaintFloor(grid, request.X, request.Z, floor)
		seen[key] = true
		if valid then
			grid:SetFloorMaterial(request.X, request.Z, floor, materialIndex)
			painted += 1
		end
	end
	if painted > 0 then
		remeshFloor(plot, floor)
		persist(plot)
	end
	return painted, if painted > 0 then nil else "no valid floor cells"
end

--[[Places supported requests. Shared propagation handles both clicks and area drags.]]
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
	for _, result in placed do
		renderCeiling(plot, result.X, result.Z, floor, result.TopOffset, materialIndex)
	end
	if #placed > 0 then
		persist(plot)
	end
	return #placed, if #placed > 0 then nil else "no supported ceiling cells"
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
	for _, request in requests do
		local key = `{request.X},{request.Z}`
		if not seen[key] and grid:RemoveCeiling(request.X, request.Z, floor) then
			grid:SetFloorMaterial(request.X, request.Z, floor + 1, 1)
			derenderCeiling(plot, request.X, request.Z, floor)
			removed += 1
		end
		seen[key] = true
	end
	if removed > 0 then
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

return ServerBuildingService
