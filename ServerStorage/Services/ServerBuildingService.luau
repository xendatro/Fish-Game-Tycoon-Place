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

--[[
Attempts to place an asset for a player. Returns the new placement id, or nil + reason.
]]
function ServerBuildingService:Place(
	player: Player,
	name: string,
	x: number,
	z: number,
	floor: number,
	rotation: number
): (number?, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return nil, "no plot"
	end

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
	persist(plot)
	return id
end

--[[
Removes a placement by id. The id comes from the PlacementId attribute on the rendered
instance (which the client can read), so this works for any type - content or walls
(which live on edges and can't be found by a cell lookup). Only ids in the player's own
plot grid exist there, so a client can only remove its own builds. Returns success.
]]
function ServerBuildingService:Remove(player: Player, placementId: number): boolean
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return false
	end

	local removed = plot:GetGrid():RemovePlacement(placementId)
	if not removed then
		return false
	end

	derender(plot, placementId)
	persist(plot)
	return true
end

--[[
Paints a cell's floor material on the given level. Level 1 always works (grass reverts).
Higher levels require a ceiling directly below. Returns success + reason.
]]
function ServerBuildingService:PaintFloor(player: Player, x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return false, "no plot"
	end
	if floor < 1 or floor % 1 ~= 0 then
		return false, "invalid floor"
	end
	if materialIndex < 1 or materialIndex > #Materials.Floor then
		return false, "invalid material"
	end

	local grid = plot:GetGrid()
	if not grid:IsInBounds(x, z) then
		return false, "out of bounds"
	end
	if floor > 1 and not grid:GetCeiling(x, z, floor - 1) then
		return false, "no ceiling here"
	end

	grid:SetFloorMaterial(x, z, floor, materialIndex)
	remeshFloor(plot, floor)
	persist(plot)
	return true
end

--[[
Places a ceiling at the top of the selected fixed-height wall segment. A bordering wall or
adjacent ceiling on the same level supplies support. Returns success + reason.
]]
function ServerBuildingService:PlaceCeiling(
	player: Player,
	x: number,
	z: number,
	floor: number,
	materialIndex: number
): (boolean, string?)
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return false, "no plot"
	end
	if materialIndex < 1 or materialIndex > #Materials.Ceiling then
		return false, "invalid material"
	end
	if floor < 1 or floor % 1 ~= 0 then
		return false, "invalid floor"
	end

	local grid = plot:GetGrid()
	if not grid:IsInBounds(x, z) then
		return false, "out of bounds"
	end
	if grid:GetCeiling(x, z, floor) then
		return false, "ceiling already here"
	end

	local topOffset = SharedBuildingService:GetCeilingTopOffset(grid, x, z, floor)
	if not topOffset then
		return false, "needs a wall or ceiling"
	end

	grid:SetCeiling(x, z, floor, topOffset, materialIndex)
	renderCeiling(plot, x, z, floor, topOffset, materialIndex)
	persist(plot)
	return true
end

--[[
Removes a ceiling and clears the painted tile that rested on it one level above.
]]
function ServerBuildingService:RemoveCeiling(player: Player, x: number, z: number, floor: number): boolean
	local plot = ServerPlotService:GetPlayerPlot(player)
	if not plot then
		return false
	end

	local grid = plot:GetGrid()
	if not grid:RemoveCeiling(x, z, floor) then
		return false
	end

	grid:SetFloorMaterial(x, z, floor + 1, 1)
	remeshFloor(plot, floor + 1)
	derenderCeiling(plot, x, z, floor)
	persist(plot)
	return true
end

-- Client entry points (RemoteFunctions so the client gets accept/reject feedback for
-- its preview). Basic numeric guards keep malformed requests from erroring the grid;
-- full validation lives in :Place / :Remove. TODO: per-player rate limiting.
local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

placeRemote.OnServerInvoke = function(player, name, x, z, floor, rotation)
	if type(name) ~= "string" or not (isFiniteNumber(x) and isFiniteNumber(z) and isFiniteNumber(floor) and isFiniteNumber(rotation)) then
		return nil, "bad request"
	end
	return ServerBuildingService:Place(player, name, x, z, floor, rotation)
end

removeRemote.OnServerInvoke = function(player, placementId)
	if not isFiniteNumber(placementId) then
		return false
	end
	return ServerBuildingService:Remove(player, placementId)
end

paintRemote.OnServerInvoke = function(player, x, z, floor, materialIndex)
	if not (isFiniteNumber(x) and isFiniteNumber(z) and isFiniteNumber(floor) and isFiniteNumber(materialIndex)) then
		return false
	end
	return ServerBuildingService:PaintFloor(player, x, z, floor, materialIndex)
end

ceilingRemote.OnServerInvoke = function(player, action, x, z, floor, materialIndex)
	if not (isFiniteNumber(x) and isFiniteNumber(z) and isFiniteNumber(floor)) then
		return false
	end
	if action == "place" then
		if not isFiniteNumber(materialIndex) then
			return false
		end
		return ServerBuildingService:PlaceCeiling(player, x, z, floor, materialIndex)
	elseif action == "remove" then
		return ServerBuildingService:RemoveCeiling(player, x, z, floor)
	end
	return false
end

return ServerBuildingService
