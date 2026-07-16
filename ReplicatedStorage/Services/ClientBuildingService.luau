--[[
ClientBuildingService - the local half of building: firing place/remove requests to
the server, plus (currently) a temporary debug UI and a live preview ghost. The real
system will replace the debug UI with proper input, a CanPlace tint, and a free camera.

This module lives in ReplicatedStorage/Services and is started by the client Init.
It is a no-op on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientBuildingService = {}

if not RunService:IsClient() then
	return ClientBuildingService
end

local Grid = require(ReplicatedStorage.Classes.Grid)
local BuildCamera = require(ReplicatedStorage.Classes.BuildCamera)
local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local SharedBuildingService = require(ReplicatedStorage.Services.SharedBuildingService)

-- Remotes authored in Studio under ReplicatedStorage.Communication.Building.
local BuildingRemotes = ReplicatedStorage:WaitForChild("Communication"):WaitForChild("Building")
local placeRemote = BuildingRemotes:WaitForChild("Place") :: RemoteFunction
local removeRemote = BuildingRemotes:WaitForChild("Remove") :: RemoteFunction
local paintRemote = BuildingRemotes:WaitForChild("Paint") :: RemoteFunction
local ceilingRemote = BuildingRemotes:WaitForChild("Ceiling") :: RemoteFunction

local player = Players.LocalPlayer

type PlacementRequest = { X: number, Z: number, Floor: number, Rotation: number }
type CellRequest = { X: number, Z: number }

-- Single clicks use the same bulk remote contract as drags.
function ClientBuildingService:RequestPlace(name: string, x: number, z: number, floor: number, rotation: number): (boolean, string?)
	local count, reason = placeRemote:InvokeServer(name, { { X = x, Z = z, Floor = floor, Rotation = rotation } })
	return count > 0, reason
end

--[[Requests removal of a placement by id (read from the rendered instance). Returns success.]]
function ClientBuildingService:RequestRemove(placementId: number): boolean
	return removeRemote:InvokeServer(placementId)
end

--[[Requests painting a cell's floor material. Returns success + reason.]]
function ClientBuildingService:RequestPaint(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	local count, reason = paintRemote:InvokeServer({ { X = x, Z = z } }, floor, materialIndex)
	return count > 0, reason
end

--[[Requests placing a ceiling at the top of the selected wall level.]]
function ClientBuildingService:RequestPlaceCeiling(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	local count, reason = ceilingRemote:InvokeServer("place", { { X = x, Z = z } }, floor, materialIndex)
	return count > 0, reason
end

--[[Requests removing the ceiling on one selected build floor.]]
function ClientBuildingService:RequestRemoveCeiling(x: number, z: number, floor: number): boolean
	return ceilingRemote:InvokeServer("remove", x, z, floor)
end

-- ===========================================================================
-- TEMPORARY DEBUG UI
-- A throwaway ScreenGui to exercise building before the real UI exists: a button
-- per catalog entry, a rotate button (or press R), and a delete toggle. Click the
-- plot to place/remove at the cell under the cursor. Replace with the real system.
-- TODO(real system): replace this panel/input with the final build UI.
-- ===========================================================================

local selectedAsset: string? = nil
local currentRotation = 0
local currentFloor = 1 -- unbounded build level; each level is one configured wall segment
local buildMode = true
local freeCameraMode = false
local deleteMode = false
local paintMode = false
local paintMaterial = 2 -- floor material index while painting (1 = grass/revert)
local ceilingMode = false
local ceilingMaterial = 1 -- ceiling material index while placing ceilings
local statusLabel: TextLabel
local BuildModeButton: TextButton?
local CameraModeButton: TextButton?
local cameraController = BuildCamera.new()

type DragState = {
	Mode: "Item" | "Paint" | "Ceiling",
	StartX: number,
	StartZ: number,
	LastX: number,
	LastZ: number,
	Floor: number,
	Rotation: number,
	Name: string?,
	Material: number?,
}
local dragState: DragState? = nil

--[[Clears every non-place mode. Callers then set the one they want.]]
local function clearModes()
	dragState = nil
	deleteMode = false
	paintMode = false
	ceilingMode = false
end

-- Live preview ("ghost") of the selected asset, following the cursor.
local previewModel: Model? = nil
local extraPreviewModels: { Model } = {}

-- Per-piece hitboxes (pooled). The parts are invisible; each carries a SelectionBox
-- outline that shows red only on the pieces that actually collide / are out of bounds.
local indicatorFolder = Instance.new("Folder")
indicatorFolder.Name = "BuildingPreviewIndicators"
indicatorFolder.Parent = Workspace
local indicators: { BasePart } = {}

local function getIndicator(index: number): BasePart
	local part = indicators[index]
	if not part then
		part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CastShadow = false
		part.Transparency = 1 -- invisible; the SelectionBox is what shows

		local outline = Instance.new("SelectionBox")
		outline.Name = "Outline"
		outline.Adornee = part
		outline.Color3 = Color3.fromRGB(220, 60, 60)
		outline.LineThickness = 0.04
		outline.SurfaceTransparency = 1
		outline.Visible = false
		outline.Parent = part

		indicators[index] = part
	end
	return part
end

local function hideIndicators()
	for _, part in indicators do
		part.Parent = nil
	end
end

-- Red outline shown around the placement the cursor would delete.
local deleteHighlight = Instance.new("SelectionBox")
deleteHighlight.Name = "BuildingDeleteHighlight"
deleteHighlight.Color3 = Color3.fromRGB(220, 60, 60)
deleteHighlight.LineThickness = 0.06
deleteHighlight.SurfaceColor3 = Color3.fromRGB(220, 60, 60)
deleteHighlight.SurfaceTransparency = 0.85
deleteHighlight.Visible = false
deleteHighlight.Parent = indicatorFolder

-- Pooled per-cell previews shared by floor painting and ceiling placement.
local tilePreviews: { BasePart } = {}

local function getTilePreview(index: number): BasePart
	local part = tilePreviews[index]
	if part then
		return part
	end
	part = Instance.new("Part")
	part.Name = "BuildingTilePreview"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1

	local outline = Instance.new("SelectionBox")
	outline.Name = "Outline"
	outline.Adornee = part
	outline.LineThickness = 0.05
	outline.SurfaceTransparency = 0.75
	outline.Parent = part
	tilePreviews[index] = part
	return part
end

local function hideTilePreview()
	for _, part in tilePreviews do
		part.Parent = nil
	end
end

--[[Walks up from an instance to the placement Model carrying a PlacementId attribute.]]
local function findPlacementModel(instance: Instance?): Model?
	local current = instance
	while current and current ~= Workspace do
		if current:IsA("Model") and current:GetAttribute("PlacementId") ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

--[[Walks up to a rendered ceiling slab carrying authoritative ceiling attributes.]]
local function findCeilingPart(instance: Instance?): BasePart?
	local current = instance
	while current and current ~= Workspace do
		if current:IsA("BasePart") and current:GetAttribute("TopOffset") ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function hideDeleteHighlight()
	deleteHighlight.Adornee = nil
	deleteHighlight.Visible = false
end

--[[Outlines the placement under the cursor (in delete mode) so it's clear what a click
would remove.]]
local function updateDeleteHighlight()
	hideIndicators()
	hideTilePreview()
	local model = findPlacementModel(player:GetMouse().Target)
	local ceiling = findCeilingPart(player:GetMouse().Target)
	deleteHighlight.Adornee = model or ceiling
	deleteHighlight.Visible = model ~= nil or ceiling ~= nil
end

-- The player's own plot is found via the Owner attribute set by Plot:Assign.
local function getMyPlotBase(): BasePart?
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, plotModel in plots:GetChildren() do
		if plotModel:GetAttribute("Owner") == player.Name then
			local base = plotModel:FindFirstChild("Plot")
			return if base and base:IsA("BasePart") then base else nil
		end
	end
	return nil
end

--[[Builds a client mirror of the plot's authoritative grid by reading the placement data
stamped on each rendered model. This is what the preview validates against, so the
highlight uses the exact same occupancy that blocks placement server-side.]]
local function buildMirrorGrid(base: BasePart): Grid.Grid
	local grid = Grid.new(base)
	local plot = base.Parent
	local built = plot and plot:FindFirstChild("Built")

	if built then
		for _, model in built:GetChildren() do
			local name = model:GetAttribute("AssetName")
			if type(name) ~= "string" then
				continue
			end
			local x = model:GetAttribute("GridX")
			local z = model:GetAttribute("GridZ")
			local floor = model:GetAttribute("Floor")
			local rotation = model:GetAttribute("Rotation")
			local cells, edges = SharedBuildingService:ResolveOccupancy(name, x, z, floor, rotation)
			grid:AddPlacement({
				Name = name,
				X = x,
				Z = z,
				Floor = floor,
				Rotation = rotation,
				Cells = cells,
				Edges = edges,
			})
		end
	end

	local ceilings = plot and plot:FindFirstChild("Ceilings")
	if ceilings then
		for _, slab in ceilings:GetChildren() do
			grid:SetCeiling(
				slab:GetAttribute("GridX"),
				slab:GetAttribute("GridZ"),
				slab:GetAttribute("Floor"),
				slab:GetAttribute("TopOffset"),
				slab:GetAttribute("MaterialIndex")
			)
		end
	end
	return grid
end

--[[World Y of the selected build level's base.]]
local function floorBaseY(grid: Grid.Grid, floor: number): number
	return grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(floor)
end

-- Invisible plot-sized target plane. It is moved to the exact placement height before
-- raycasting so lower geometry cannot shift the selected cell.
local buildPlane = Instance.new("Part")
buildPlane.Name = "BuildGridPlane"
buildPlane.Anchored = true
buildPlane.CanCollide = false
buildPlane.CanQuery = true
buildPlane.CanTouch = false
buildPlane.CastShadow = false
buildPlane.Transparency = 1
buildPlane.Size = Vector3.new(1, 0.05, 1)

-- Authored in Studio as a Texture child of this ModuleScript. The clone follows the
-- same temporary part used by the placement raycast at every build height.
local GridTexture = (script:WaitForChild("Grid") :: Texture):Clone()
GridTexture.Face = Enum.NormalId.Top
GridTexture.Parent = buildPlane

local function positionBuildPlane(grid: Grid.Grid, planeY: number)
	local cell = Building.CELL_SIZE
	buildPlane.Size = Vector3.new(grid.Width * cell, 0.05, grid.Depth * cell)
	buildPlane.CFrame = CFrame.new(grid.Origin.X + grid.Width * cell / 2, planeY, grid.Origin.Z + grid.Depth * cell / 2)
	buildPlane.Parent = Workspace
end

local function hideBuildPlane()
	buildPlane.Parent = nil
end

--[[Returns the cursor cell on the exact plane where the active mode places. Ceilings
target the top of the selected wall segment; every other object targets its base.]]
local function cellUnderCursor(grid: Grid.Grid, floor: number?, ceiling: boolean?): (number?, number?, Vector3?)
	local targetFloor = floor or currentFloor
	local targetY = if ceiling == true or (ceiling == nil and ceilingMode)
		then grid.Origin.Y + SharedBuildingService:GetLevelTopOffset(targetFloor)
		else floorBaseY(grid, targetFloor)
	positionBuildPlane(grid, targetY)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { buildPlane }
	local ray = player:GetMouse().UnitRay
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	local position = if result then result.Position else nil
	-- Once a drag has started, keep its endpoint clamped to the plot even when the
	-- cursor ray moves beyond the finite build plane.
	if not position and dragState and math.abs(ray.Direction.Y) > 0.0001 then
		local distance = (targetY - ray.Origin.Y) / ray.Direction.Y
		if distance > 0 then
			position = ray.Origin + ray.Direction * distance
		end
	end
	if not position and dragState then
		local last = grid:GetCellCenter(dragState.LastX, dragState.LastZ)
		return dragState.LastX, dragState.LastZ, Vector3.new(last.X, targetY, last.Z)
	end
	if not position then
		return nil, nil, nil
	end

	local x, z = grid:WorldToCell(position)
	return math.clamp(x, 0, grid.Width - 1), math.clamp(z, 0, grid.Depth - 1), position
end

--[[For walls, rotation chooses the horizontal/vertical axis while the cursor chooses
the nearest edge on that axis. Other assets keep their explicit four-way rotation.]]
local function resolvePlacementRotation(grid: Grid.Grid, name: string, x: number, z: number, hitPosition: Vector3): number
	local entry = SharedBuildingService:GetEntry(name)
	if not entry or entry.Type ~= "Wall" then
		return currentRotation
	end

	local centre = grid:GetCellCenter(x, z)
	if currentRotation % 2 == 0 then
		return if hitPosition.Z < centre.Z then 0 else 2 -- south / north
	end
	return if hitPosition.X < centre.X then 3 else 1 -- west / east
end

local function refreshStatus(extra: string?)
	if not statusLabel then
		return
	end
	local mode
	if not buildMode then
		mode = "BUILD OFF"
	elseif deleteMode then
		mode = "DELETE"
	elseif paintMode then
		mode = `Paint: {Materials.Floor[paintMaterial]}`
	elseif ceilingMode then
		mode = `Ceiling: {Materials.Ceiling[ceilingMaterial]}`
	else
		mode = `Place: {selectedAsset or "none"}`
	end
	if BuildModeButton then
		BuildModeButton.Text = if buildMode then "Build: ON" else "Build: OFF"
	end
	if CameraModeButton then
		CameraModeButton.Text = if freeCameraMode then "Camera: Free" else "Camera: Character"
	end
	local entry = selectedAsset and SharedBuildingService:GetEntry(selectedAsset)
	local rotationText = if entry and entry.Type == "Wall"
		then (if currentRotation % 2 == 0 then "wall horizontal" else "wall vertical")
		else `rot {currentRotation * 90}°`
	statusLabel.Text = `{mode} | level {currentFloor} | {if freeCameraMode then "free cam" else "character cam"} | {rotationText}{if extra then " | " .. extra else ""}`
end

local function rotateSelection()
	local entry = selectedAsset and SharedBuildingService:GetEntry(selectedAsset)
	currentRotation = if entry and entry.Type == "Wall" then (currentRotation + 1) % 2 else (currentRotation + 1) % 4
	refreshStatus()
end

local function rectangleCells(startX: number, startZ: number, endX: number, endZ: number): { CellRequest }
	local cells = {}
	local stepX = if endX >= startX then 1 else -1
	local stepZ = if endZ >= startZ then 1 else -1
	for z = startZ, endZ, stepZ do
		for x = startX, endX, stepX do
			table.insert(cells, { X = x, Z = z })
		end
	end
	return cells
end

local function dragPlacements(state: DragState, endX: number, endZ: number): { PlacementRequest }
	local entry = state.Name and SharedBuildingService:GetEntry(state.Name)
	if not entry then
		return {}
	end
	if entry.Draggable == "Area" then
		local spanX = if state.Rotation % 2 == 0 then entry.Footprint.Width else entry.Footprint.Depth
		local spanZ = if state.Rotation % 2 == 0 then entry.Footprint.Depth else entry.Footprint.Width
		local deltaX, deltaZ = endX - state.StartX, endZ - state.StartZ
		local directionX = if deltaX < 0 then -1 else 1
		local directionZ = if deltaZ < 0 then -1 else 1
		local countX = math.floor(math.abs(deltaX) / spanX) + 1
		local countZ = math.floor(math.abs(deltaZ) / spanZ) + 1
		local requests = {}
		for zIndex = 0, countZ - 1 do
			for xIndex = 0, countX - 1 do
				table.insert(requests, {
					X = state.StartX + xIndex * spanX * directionX,
					Z = state.StartZ + zIndex * spanZ * directionZ,
					Floor = state.Floor,
					Rotation = state.Rotation,
				})
			end
		end
		return requests
	end

	local horizontal = state.Rotation % 2 == 0
	local delta = if horizontal then endX - state.StartX else endZ - state.StartZ
	local direction = if delta < 0 then -1 else 1
	local step = entry.Footprint.Width
	local count = math.floor(math.abs(delta) / step) + 1
	local requests = {}
	for index = 0, count - 1 do
		table.insert(requests, {
			X = state.StartX + (if horizontal then index * step * direction else 0),
			Z = state.StartZ + (if horizontal then 0 else index * step * direction),
			Floor = state.Floor,
			Rotation = state.Rotation,
		})
	end
	return requests
end

local function createGhost(name: string): Model?
	local model = SharedBuildingService:GetModel(name)
	if not model then
		return nil
	end
	local ghost = model:Clone()
	for _, part in ghost:GetDescendants() do
		if part:IsA("BasePart") then
			part.Transparency = 0.5
			part.CanCollide = false
			part.CanQuery = false
			part.Anchored = true
		end
	end
	ghost.Parent = Workspace
	return ghost
end

local function hideExtraPreviews()
	for _, model in extraPreviewModels do
		model:PivotTo(CFrame.new(0, -1000, 0))
	end
end

local function getPlacementPreview(index: number, name: string): Model?
	if index == 1 then
		return previewModel
	end
	local model = extraPreviewModels[index - 1]
	if not model then
		model = createGhost(name)
		if model then
			extraPreviewModels[index - 1] = model
		end
	end
	return model
end

--[[Rebuilds the preview ghost from the current selection. Destroys any old one.
The ghost is a non-collidable, non-queryable, semi-transparent clone so it doesn't block
the placement raycast.]]
local function rebuildPreview()
	if previewModel then
		previewModel:Destroy()
		previewModel = nil
	end
	for _, model in extraPreviewModels do
		model:Destroy()
	end
	table.clear(extraPreviewModels)

	if not buildMode or deleteMode or paintMode or ceilingMode or not selectedAsset then
		return
	end

	previewModel = createGhost(selectedAsset)
end

--[[Positions an invisible hitbox over each footprint piece (sized to the model) and shows
its red outline only when that piece is out of bounds or its occupancy key is already
taken in the mirror grid - the exact same check that blocks placement server-side.]]
local function updateIndicators(grid: Grid.Grid, name: string, requests: { PlacementRequest })
	local indicatorIndex = 0
	for _, request in requests do
		local pieces = SharedBuildingService:GetHitboxPieces(
			grid,
			name,
			request.X,
			request.Z,
			request.Floor,
			request.Rotation
		)
		local canPlace = SharedBuildingService:CanPlace(
			grid,
			name,
			request.X,
			request.Z,
			request.Floor,
			request.Rotation
		)
		for _, piece in pieces do
			indicatorIndex += 1
			local indicator = getIndicator(indicatorIndex)
			indicator.Size = piece.Size
			indicator.CFrame = piece.CFrame
			local outline = indicator:FindFirstChild("Outline") :: SelectionBox
			outline.Visible = not canPlace or not piece.InBounds or grid:IsOccupied(piece.Key)
			indicator.Parent = indicatorFolder
		end
	end
	for i = indicatorIndex + 1, #indicators do
		indicators[i].Parent = nil
	end
end

local function setTilePreview(index: number, cframe: CFrame, size: Vector3, valid: boolean, filled: boolean)
	local color = if valid then Color3.fromRGB(65, 210, 105) else Color3.fromRGB(220, 60, 60)
	local part = getTilePreview(index)
	local outline = part:FindFirstChild("Outline") :: SelectionBox
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Transparency = if filled then 0.65 else 1
	outline.Color3 = color
	outline.SurfaceColor3 = color
	part.Parent = indicatorFolder
end

local function ceilingValidity(grid: Grid.Grid, cells: { CellRequest }, floor: number): { [number]: boolean }
	local valid = {}
	for _, result in SharedBuildingService:FillCeilings(grid, cells, floor, ceilingMaterial) do
		valid[result.Index] = true
	end
	return valid
end

--[[Shows the target cell for paint and ceiling modes. Paint uses a thin outline on
the selected floor surface; ceilings use a translucent slab at their computed top.]]
local function updateTilePreview()
	local base = getMyPlotBase()
	if not base then
		hideTilePreview()
		hideBuildPlane()
		return
	end

	local grid = buildMirrorGrid(base)
	local targetFloor = if dragState then dragState.Floor else currentFloor
	local x, z = cellUnderCursor(grid, targetFloor, ceilingMode)
	if x == nil or z == nil then
		hideTilePreview()
		return
	end
	if dragState then
		dragState.LastX, dragState.LastZ = x, z
	end
	local cells = if dragState
		then rectangleCells(dragState.StartX, dragState.StartZ, x, z)
		else { { X = x, Z = z } }

	if paintMode then
		local topOffset = SharedBuildingService:GetLevelBaseOffset(targetFloor)
		for index, cell in cells do
			local centre = grid:GetCellCenter(cell.X, cell.Z)
			local valid = SharedBuildingService:CanPaintFloor(grid, cell.X, cell.Z, targetFloor)
			setTilePreview(
				index,
				CFrame.new(centre.X, grid.Origin.Y + topOffset + 0.05, centre.Z),
				Vector3.new(Building.CELL_SIZE, 0.1, Building.CELL_SIZE),
				valid,
				false
			)
		end
		for index = #cells + 1, #tilePreviews do
			tilePreviews[index].Parent = nil
		end
		return
	end

	local topOffset = SharedBuildingService:GetLevelTopOffset(targetFloor)
	local validity = ceilingValidity(grid, cells, targetFloor)
	for index, cell in cells do
		local centre = grid:GetCellCenter(cell.X, cell.Z)
		setTilePreview(
			index,
			CFrame.new(centre.X, grid.Origin.Y + topOffset - Building.CEILING_THICKNESS / 2, centre.Z),
			Vector3.new(Building.CELL_SIZE, Building.CEILING_THICKNESS, Building.CELL_SIZE),
			validity[index] == true,
			true
		)
	end
	for index = #cells + 1, #tilePreviews do
		tilePreviews[index].Parent = nil
	end
end

--[[Snaps the preview ghost + validity indicators to the cell under the cursor
each frame, or parks them out of sight when the cursor isn't over the world.]]
local function updatePreview()
	if paintMode or ceilingMode then
		hideIndicators()
		updateTilePreview()
		return
	end
	hideTilePreview()

	if not previewModel or not selectedAsset then
		hideIndicators()
		hideBuildPlane()
		return
	end

	local base = getMyPlotBase()
	if base then
		local grid = buildMirrorGrid(base)
		local targetFloor = if dragState then dragState.Floor else currentFloor
		local x, z, hitPosition = cellUnderCursor(grid, targetFloor, false)
		if x == nil or z == nil or hitPosition == nil then
			previewModel:PivotTo(CFrame.new(0, -1000, 0))
			hideExtraPreviews()
			hideIndicators()
			return
		end
		local name = if dragState and dragState.Name then dragState.Name else selectedAsset
		local requests
		if dragState and dragState.Mode == "Item" then
			dragState.LastX, dragState.LastZ = x, z
			requests = dragPlacements(dragState, x, z)
		else
			local rotation = resolvePlacementRotation(grid, name, x, z, hitPosition)
			requests = { { X = x, Z = z, Floor = targetFloor, Rotation = rotation } }
		end
		for index, request in requests do
			local model = getPlacementPreview(index, name)
			local groundCF = SharedBuildingService:GetPlacementCFrame(
				grid,
				name,
				request.X,
				request.Z,
				request.Rotation
			)
			if model and groundCF then
				SharedBuildingService:PivotModelToLevel(model, groundCF, grid.Origin.Y, request.Floor)
			end
		end
		for index = #requests, #extraPreviewModels do
			local extra = extraPreviewModels[index]
			if extra then
				extra:PivotTo(CFrame.new(0, -1000, 0))
			end
		end
		updateIndicators(grid, name, requests)
		return
	end
	-- No valid target: park the ghost far below the map and hide indicators.
	previewModel:PivotTo(CFrame.new(0, -1000, 0))
	hideExtraPreviews()
	hideIndicators()
	hideBuildPlane()
end

local function onClick()
	if not buildMode then
		return
	end
	-- Delete mode prioritises rendered placements/ceilings under the cursor. Clicking a
	-- painted elevated surface removes its supporting ceiling; level 1 paint reverts.
	if deleteMode then
		local target = player:GetMouse().Target
		local model = findPlacementModel(target)
		if model then
			local ok = ClientBuildingService:RequestRemove(model:GetAttribute("PlacementId") :: number)
			refreshStatus(if ok then "removed" else "remove failed")
			return
		end
		local ceiling = findCeilingPart(target)
		if ceiling then
			local ok = ClientBuildingService:RequestRemoveCeiling(
				ceiling:GetAttribute("GridX"),
				ceiling:GetAttribute("GridZ"),
				ceiling:GetAttribute("Floor")
			)
			refreshStatus(if ok then "removed ceiling" else "remove failed")
			return
		end

		local base = getMyPlotBase()
		if not (base and player:GetMouse().Target) then
			refreshStatus("nothing to delete")
			return
		end
		-- Delete targets the physical thing under the cursor, so use the raw mouse hit.
		local grid = Grid.new(base)
		local rawX, rawZ = grid:WorldToCell(player:GetMouse().Hit.Position)
		local x, z = math.clamp(rawX, 0, grid.Width - 1), math.clamp(rawZ, 0, grid.Depth - 1)
		local floorLevel = target:GetAttribute("FloorLevel")
		local level = if typeof(floorLevel) == "number" then floorLevel else currentFloor
		if level > 1 then
			local ok = ClientBuildingService:RequestRemoveCeiling(x, z, level - 1)
			refreshStatus(if ok then `removed ceiling ({x},{z})` else "no ceiling here")
		else
			local ok = ClientBuildingService:RequestPaint(x, z, 1, 1) -- 1 = grass/revert
			refreshStatus(if ok then `reverted ({x},{z})` else "nothing to delete")
		end
		return
	end

	if not paintMode and not ceilingMode and not selectedAsset then
		refreshStatus("select an asset first")
		return
	end

	local base = getMyPlotBase()
	if not base then
		refreshStatus("no owned plot")
		return
	end
	-- Mirror grid so the click uses the same target plane and occupancy as the preview.
	local grid = buildMirrorGrid(base)
	local x, z, hitPosition = cellUnderCursor(grid)
	if x == nil or z == nil then
		return
	end

	if paintMode then
		local ok, reason = ClientBuildingService:RequestPaint(x, z, currentFloor, paintMaterial)
		refreshStatus(if ok then `painted ({x},{z})` else `rejected: {reason}`)
	elseif ceilingMode then
		local ok, reason = ClientBuildingService:RequestPlaceCeiling(x, z, currentFloor, ceilingMaterial)
		refreshStatus(if ok then `ceiling ({x},{z})` else `rejected: {reason}`)
	else
		local rotation = resolvePlacementRotation(grid, selectedAsset :: string, x, z, hitPosition :: Vector3)
		local ok, reason = ClientBuildingService:RequestPlace(selectedAsset :: string, x, z, currentFloor, rotation)
		refreshStatus(if ok then `placed ({x},{z})` else `rejected: {reason}`)
	end
end

--[[Starts a configured item drag, or an area drag for the floor/ceiling tools. A
non-draggable catalog item returns false so the caller can use normal click placement.]]
local function beginDrag(): boolean
	if not buildMode or deleteMode then
		return false
	end
	local entry = selectedAsset and SharedBuildingService:GetEntry(selectedAsset)
	if not paintMode and not ceilingMode and not (entry and entry.Draggable) then
		return false
	end
	local base = getMyPlotBase()
	if not base then
		refreshStatus("no owned plot")
		return true
	end
	local grid = buildMirrorGrid(base)
	local x, z, hitPosition = cellUnderCursor(grid, currentFloor, ceilingMode)
	if x == nil or z == nil or hitPosition == nil then
		return true
	end
	local mode = if paintMode then "Paint" elseif ceilingMode then "Ceiling" else "Item"
	local rotation = if mode == "Item"
		then resolvePlacementRotation(grid, selectedAsset :: string, x, z, hitPosition)
		else currentRotation
	dragState = {
		Mode = mode,
		StartX = x,
		StartZ = z,
		LastX = x,
		LastZ = z,
		Floor = currentFloor,
		Rotation = rotation,
		Name = if mode == "Item" then selectedAsset else nil,
		Material = if mode == "Paint" then paintMaterial elseif mode == "Ceiling" then ceilingMaterial else nil,
	}
	return true
end

local function finishDrag()
	local state = dragState
	if not state then
		return
	end
	local base = getMyPlotBase()
	if base then
		local grid = buildMirrorGrid(base)
		local x, z = cellUnderCursor(grid, state.Floor, state.Mode == "Ceiling")
		if x ~= nil and z ~= nil then
			state.LastX, state.LastZ = x, z
		end
	end
	dragState = nil

	if state.Mode == "Item" then
		local requests = dragPlacements(state, state.LastX, state.LastZ)
		local placed, reason = placeRemote:InvokeServer(state.Name, requests)
		refreshStatus(if placed > 0 then `placed {placed}/{#requests}` else `rejected: {reason}`)
	else
		local requests = rectangleCells(state.StartX, state.StartZ, state.LastX, state.LastZ)
		if state.Mode == "Paint" then
			local painted, reason = paintRemote:InvokeServer(requests, state.Floor, state.Material)
			refreshStatus(if painted > 0 then `painted {painted}/{#requests}` else `rejected: {reason}`)
		else
			local placed, reason = ceilingRemote:InvokeServer("place", requests, state.Floor, state.Material)
			refreshStatus(if placed > 0 then `ceiling {placed}/{#requests}` else `rejected: {reason}`)
		end
	end
end

local function syncCameraMode()
	cameraController:SetCeilingSelected(ceilingMode)
	if buildMode and freeCameraMode then
		local base = getMyPlotBase()
		cameraController:SetEnabled(base ~= nil, base, currentFloor)
	else
		cameraController:SetEnabled(false)
	end
end

local function setBuildMode(enabled: boolean)
	buildMode = enabled
	if enabled then
		syncCameraMode()
		rebuildPreview()
	else
		dragState = nil
		freeCameraMode = false
		cameraController:SetEnabled(false)
		if previewModel then
			previewModel:PivotTo(CFrame.new(0, -1000, 0))
		end
		hideExtraPreviews()
		hideIndicators()
		hideTilePreview()
		hideBuildPlane()
		hideDeleteHighlight()
	end
	refreshStatus()
end

local function setFreeCameraMode(enabled: boolean)
	freeCameraMode = enabled
	syncCameraMode()
	refreshStatus()
end

local function buildDebugUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "BuildingDebug"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(260, 500)
	panel.Position = UDim2.fromOffset(12, 12)
	panel.BackgroundColor3 = Color3.new(0, 0, 0)
	panel.BackgroundTransparency = 0.35
	panel.BorderSizePixel = 0
	panel.Parent = gui

	statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -8, 0, 42)
	statusLabel.Position = UDim2.fromOffset(4, 2)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.new(1, 1, 1)
	statusLabel.TextWrapped = true
	statusLabel.Parent = panel

	local function addButton(parent: Instance, text: string, onActivate: () -> ()): TextButton
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 24)
		button.Text = text
		button.Parent = parent
		button.Activated:Connect(onActivate)
		return button
	end

	local tools = Instance.new("Frame")
	tools.Size = UDim2.new(1, -8, 0, 76)
	tools.Position = UDim2.fromOffset(4, 46)
	tools.BackgroundTransparency = 1
	tools.Parent = panel

	local toolLayout = Instance.new("UIGridLayout")
	toolLayout.CellPadding = UDim2.fromOffset(2, 2)
	toolLayout.CellSize = UDim2.new(0.5, -1, 0, 24)
	toolLayout.Parent = tools

	local tabs = Instance.new("Frame")
	tabs.Size = UDim2.new(1, -8, 0, 26)
	tabs.Position = UDim2.fromOffset(4, 126)
	tabs.BackgroundTransparency = 1
	tabs.Parent = panel

	local tabLayout = Instance.new("UIGridLayout")
	tabLayout.CellPadding = UDim2.fromOffset(2, 0)
	tabLayout.CellSize = UDim2.new(0.25, -2, 1, 0)
	tabLayout.Parent = tabs

	local pages: { [string]: ScrollingFrame } = {}
	local tabButtons: { [string]: TextButton } = {}

	local function showPage(selected: string)
		for name, page in pages do
			local active = name == selected
			page.Visible = active
			tabButtons[name].BackgroundColor3 = if active then Color3.fromRGB(110, 160, 210) else Color3.fromRGB(70, 70, 70)
		end
	end

	local function addPage(name: string): ScrollingFrame
		local page = Instance.new("ScrollingFrame")
		page.Name = name
		page.Size = UDim2.new(1, -8, 1, -160)
		page.Position = UDim2.fromOffset(4, 156)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = 6
		page.CanvasSize = UDim2.new()
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.Visible = false
		page.Parent = panel

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 2)
		layout.Parent = page

		pages[name] = page
		tabButtons[name] = addButton(tabs, name, function()
			showPage(name)
		end)
		return page
	end

	local function addNotice(page: ScrollingFrame, text: string)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -8, 0, 28)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(170, 210, 255)
		label.Parent = page
	end

	addButton(tools, "Rotate", function()
		rotateSelection()
	end)
	addButton(tools, "Level -", function()
		currentFloor = math.max(1, currentFloor - 1)
		if freeCameraMode then
			cameraController:SetLevel(currentFloor)
		end
		refreshStatus()
	end)
	addButton(tools, "Level +", function()
		currentFloor += 1
		if freeCameraMode then
			cameraController:SetLevel(currentFloor)
		end
		refreshStatus()
	end)
	addButton(tools, "Delete", function()
		local wasDelete = deleteMode
		clearModes()
		deleteMode = not wasDelete
		rebuildPreview()
		refreshStatus()
	end)
	BuildModeButton = addButton(tools, "Build: ON", function()
		setBuildMode(not buildMode)
	end)
	CameraModeButton = addButton(tools, "Camera: Character", function()
		if buildMode then
			setFreeCameraMode(not freeCameraMode)
		else
			refreshStatus("enter build mode first")
		end
	end)

	local assetPage = addPage("Assets")
	local wallPage = addPage("Walls")
	local ceilingPage = addPage("Ceilings")
	local floorPage = addPage("Floors")

	local byType: { [string]: { string } } = {}
	for name, entry in SharedBuildingService:GetCatalog() do
		byType[entry.Type] = byType[entry.Type] or {}
		table.insert(byType[entry.Type], name)
	end

	local assetNames = byType.Content or {}
	for _, name in byType.Hanger or {} do
		table.insert(assetNames, name)
	end
	local function addAssets(page: ScrollingFrame, names: { string })
		table.sort(names)
		for _, name in names do
			addButton(page, name, function()
				clearModes()
				selectedAsset = name
				rebuildPreview()
				refreshStatus()
			end)
		end
	end
	addAssets(assetPage, assetNames)
	addAssets(wallPage, byType.Wall or {})
	if #assetNames == 0 then
		addNotice(assetPage, "No content assets configured")
	end
	if #(byType.Wall or {}) == 0 then
		addNotice(wallPage, "No walls configured")
	end

	for index, material in Materials.Ceiling do
		addButton(ceilingPage, material, function()
			clearModes()
			ceilingMode = true
			ceilingMaterial = index
			rebuildPreview()
			refreshStatus()
		end)
	end

	for index, material in Materials.Floor do
		addButton(floorPage, material, function()
			clearModes()
			paintMode = true
			paintMaterial = index
			rebuildPreview()
			refreshStatus()
		end)
	end

	showPage("Walls")
	refreshStatus()
end

buildDebugUI()

RunService.RenderStepped:Connect(function()
	if not buildMode then
		return
	end
	if freeCameraMode then
		if not cameraController:IsEnabled() then
			syncCameraMode()
		end
		if cameraController:IsEnabled() then
			cameraController:SetCeilingSelected(ceilingMode)
			local cameraLevel = cameraController:GetLevel()
			if currentFloor ~= cameraLevel then
				currentFloor = cameraLevel
				refreshStatus()
			end
		end
	end
	if deleteMode then
		-- Hide the build plane so the cursor ray hits real objects to delete.
		hideBuildPlane()
		updateDeleteHighlight()
	else
		hideDeleteHighlight()
		updatePreview()
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if not buildMode then
		return
	elseif input.KeyCode == Enum.KeyCode.R then
		rotateSelection()
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		if deleteMode or not beginDrag() then
			onClick()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		finishDrag()
	end
end)

return ClientBuildingService
