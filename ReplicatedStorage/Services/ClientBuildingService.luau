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
local SharedColorService = require(ReplicatedStorage.Services.SharedColorService)
local DataSaveService = require(ReplicatedStorage.Services.DataSaveService)
local Signal = require(ReplicatedStorage.Classes.Signal)

local DELETE_FILL_TRANSPARENCY = 0.85
local DELETE_COLOR = Color3.fromRGB(220, 60, 60)
local RECOLOR_COLOR = Color3.fromRGB(120, 190, 255)

-- Remotes authored in Studio under ReplicatedStorage.Communication.Building.
local BuildingRemotes = ReplicatedStorage:WaitForChild("Communication"):WaitForChild("Building")
local placeRemote = BuildingRemotes:WaitForChild("Place") :: RemoteFunction
local removeRemote = BuildingRemotes:WaitForChild("Remove") :: RemoteFunction
local paintRemote = BuildingRemotes:WaitForChild("Paint") :: RemoteFunction
local ceilingRemote = BuildingRemotes:WaitForChild("Ceiling") :: RemoteFunction
local historyRemote = BuildingRemotes:WaitForChild("History") :: RemoteFunction
local resetRemote = BuildingRemotes:WaitForChild("Reset") :: RemoteFunction
local recolorRemote = BuildingRemotes:WaitForChild("Recolor") :: RemoteFunction
local paletteRemote = BuildingRemotes:WaitForChild("Palette") :: RemoteFunction

local player = Players.LocalPlayer

type PlacementRequest = { X: number, Z: number, Floor: number, Rotation: number }
type CellRequest = { X: number, Z: number }

--[[
One global colour selection, slot -> packed colour. A slot with no entry means "leave the
object's authored colour alone", so the same five values work across objects with
different slot counts. This is both what new placements wear and what the Paint tool
stamps onto whatever you click.

`Linked` is the one exception to "colours are just values": it marks the selection as the
player's saved palette for `LinkedAsset`, which objects follow through future palette
edits. Config palettes are stamps by comparison - picking one fills these slots and is
then forgotten.
]]
local PlaceColors: SharedColorService.SlotMap = {}
local Linked = false
local LinkedAsset: string? = nil

ClientBuildingService.PlacementSelected = Signal.new()

function ClientBuildingService:GetPlaceColors(): SharedColorService.SlotMap
	return table.clone(PlaceColors)
end

function ClientBuildingService:IsLinked(name: string?): boolean
	return Linked and (name == nil or LinkedAsset == name)
end

--[[Replaces the whole selection. `linkedAsset` marks it as that asset's saved palette.]]
function ClientBuildingService:SetPlaceColors(colors: SharedColorService.SlotMap?, linkedAsset: string?)
	table.clear(PlaceColors)
	for slot, packed in colors or {} do
		PlaceColors[slot] = packed
	end
	Linked = linkedAsset ~= nil
	LinkedAsset = linkedAsset
end

--[[Sets one slot (nil clears it). Hand-picking a colour drops any palette link.]]
function ClientBuildingService:SetPlaceColor(slot: number, packed: number?)
	PlaceColors[slot] = packed
	Linked, LinkedAsset = false, nil
end

--[[Reads the player's saved palette for an asset off the replicated profile.]]
function ClientBuildingService:GetSavedPalette(name: string): (SharedColorService.SlotMap?, string?)
	local profile = DataSaveService:GetProfile()
	local store = profile and profile.Data.CustomPalettes
	local saved = store and store[name]
	if not saved then
		return nil, nil
	end
	local plain = if saved.Serialize then saved:Serialize() else saved
	return SharedColorService:Sanitize(name, SharedColorService.ExpandSlots(plain.Colors)), plain.Name
end

--[[Asks the server how many placements of an asset exist and how many wear the saved
palette. Authoritative on purpose - counting the replicated attributes locally races
replication, and a stale count made the propagate prompt lie about what it would do.]]
function ClientBuildingService:PaletteInfo(name: string): (number, number)
	return paletteRemote:InvokeServer("info", name)
end

--[[The colours to send for one asset: only the slots it actually defines survive.]]
local function currentColors(name: string): SharedColorService.SlotMap?
	if Linked and LinkedAsset == name then
		return (ClientBuildingService:GetSavedPalette(name))
	end
	return SharedColorService:Sanitize(name, PlaceColors)
end

-- Single clicks use the same bulk remote contract as drags.
function ClientBuildingService:RequestPlace(name: string, x: number, z: number, floor: number, rotation: number): (boolean, string?)
	local count, reason = placeRemote:InvokeServer(
		name,
		{ { X = x, Z = z, Floor = floor, Rotation = rotation } },
		currentColors(name),
		self:IsLinked(name)
	)
	return count > 0, reason
end

--[[Recolours a placement. Succeeds when the server accepted the request, including when
the object already looked like this - that's a no-op, not a failure.]]
function ClientBuildingService:RecolorPlacement(
	placementId: number,
	colors: SharedColorService.SlotMap?,
	usePalette: boolean?
): (boolean, string?)
	local _, reason = recolorRemote:InvokeServer({ placementId }, colors, usePalette == true)
	return reason == nil, reason
end

function ClientBuildingService:SavePalette(
	name: string,
	colors: SharedColorService.SlotMap?,
	propagate: boolean,
	paletteName: string,
	placementId: number?
): (boolean, string?, number)
	return paletteRemote:InvokeServer("save", name, colors, propagate, paletteName, placementId)
end

function ClientBuildingService:ApplyPalette(name: string): (number, string?)
	return paletteRemote:InvokeServer("apply", name)
end

--[[Requests removal of a placement by id (read from the rendered instance). Returns success.]]
function ClientBuildingService:RequestRemove(placementId: number): boolean
	return removeRemote:InvokeServer({ placementId }) > 0
end

--[[A surface's tint comes from the same global slots: Color 1 is a ceiling underside,
Color 2 a floor, matching how the Paint tool treats the two faces of one slab.]]
local function surfaceColor(kind: "Floor" | "Ceiling"): number?
	return PlaceColors[if kind == "Ceiling" then 1 else 2]
end

--[[Requests painting a cell's floor material. Material 0 removes an overlay.]]
function ClientBuildingService:RequestPaint(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	local color = if materialIndex > 0 then surfaceColor("Floor") else nil
	local count, reason = paintRemote:InvokeServer({ { X = x, Z = z } }, floor, materialIndex, color)
	return count > 0, reason
end

--[[Requests placing a ceiling at the top of the selected wall level.]]
function ClientBuildingService:RequestPlaceCeiling(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	local count, reason =
		ceilingRemote:InvokeServer("place", { { X = x, Z = z } }, floor, materialIndex, surfaceColor("Ceiling"))
	return count > 0, reason
end

--[[Requests removing the ceiling on one selected build floor.]]
function ClientBuildingService:RequestRemoveCeiling(x: number, z: number, floor: number): boolean
	return ceilingRemote:InvokeServer("remove", { { X = x, Z = z } }, floor) > 0
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
local paintMaterial = 2 -- floor material index while painting (1 = grass)
local ceilingMode = false
local ceilingMaterial = 1 -- ceiling material index while placing ceilings
local paintObjectMode = false -- stamp the current colours onto whatever you click
local pickMode = false -- read an object's colours into the selection, then go back to paint

-- Everything a paint stroke has swept over, committed in one batch on release.
type PaintDragState = { Targets: { Instance }, Seen: { [Instance]: boolean } }
local paintDragState: PaintDragState? = nil
-- Assigned by the debug UI; rebuilds the Colors tab around the current selection.
local refreshColorPage: () -> () = function() end
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

type DeleteDragState = {
	Kind: "Placement" | "Ceiling" | "Floor",
	StartX: number,
	StartZ: number,
	LastX: number,
	LastZ: number,
	Floor: number,
	PlaneY: number,
	Rotation: number,
	Name: string?,
	ItemType: string?,
	DragMode: "Line" | "Area",
	MovedAway: boolean,
}
local deleteDragState: DeleteDragState? = nil

--[[Clears every non-place mode. Callers then set the one they want.]]
local function clearModes()
	dragState = nil
	deleteDragState = nil
	deleteMode = false
	paintMode = false
	ceilingMode = false
	paintObjectMode = false
	pickMode = false
	paintDragState = nil
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

-- Pooled red outlines for click and drag deletion previews.
local deleteHighlights: { SelectionBox } = {}

local function getDeleteHighlight(index: number): SelectionBox
	local highlight = deleteHighlights[index]
	if not highlight then
		highlight = Instance.new("SelectionBox")
		highlight.Name = "BuildingDeleteHighlight"
		highlight.Color3 = DELETE_COLOR
		highlight.LineThickness = 0.06
		highlight.SurfaceColor3 = DELETE_COLOR
		highlight.SurfaceTransparency = DELETE_FILL_TRANSPARENCY
		highlight.Parent = indicatorFolder
		deleteHighlights[index] = highlight
	end
	return highlight
end

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
	for _, highlight in deleteHighlights do
		highlight.Adornee = nil
		highlight.Visible = false
	end
end

--[[Outlines a set of targets. The pool is shared with the recolour tool, which passes
its own colour so the two tools read differently at a glance.]]
local function setDeleteHighlights(targets: { Model | BasePart }, color: Color3?)
	for index, target in targets do
		local highlight = getDeleteHighlight(index)
		highlight.Color3 = color or DELETE_COLOR
		highlight.SurfaceColor3 = color or DELETE_COLOR
		highlight.Adornee = target
		highlight.Visible = true
	end
	for index = #targets + 1, #deleteHighlights do
		deleteHighlights[index].Adornee = nil
		deleteHighlights[index].Visible = false
	end
end

-- Delete targeting ignores only parts hidden by the build camera. Their CanQuery state
-- remains untouched for every other system.
local function deleteRaycast(): (Instance?, Vector3?)
	local ignored: { Instance } = { indicatorFolder }
	local plane = Workspace:FindFirstChild("BuildGridPlane")
	if plane then
		table.insert(ignored, plane)
	end
	if player.Character then
		table.insert(ignored, player.Character)
	end
	for _, part in cameraController:GetHiddenParts() do
		table.insert(ignored, part)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	local ray = player:GetMouse().UnitRay
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	return if result then result.Instance else nil, if result then result.Position else nil
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
local function cellUnderCursor(grid: Grid.Grid, floor: number?, ceiling: boolean?, exactY: number?): (number?, number?, Vector3?)
	local targetFloor = floor or currentFloor
	local placementY = if ceiling == true or (ceiling == nil and ceilingMode)
		then grid.Origin.Y + SharedBuildingService:GetLevelTopOffset(targetFloor)
		else floorBaseY(grid, targetFloor)
	local targetY = exactY or placementY
	if deleteDragState and not Building.SHOW_GRID_DURING_DELETE_DRAG then
		hideBuildPlane()
	else
		positionBuildPlane(grid, placementY)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { buildPlane }
	local ray = player:GetMouse().UnitRay
	local result = if exactY then nil else Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	local position = if result then result.Position else nil
	local activeDrag = dragState or deleteDragState
	if exactY and math.abs(ray.Direction.Y) > 0.0001 then
		local distance = (exactY - ray.Origin.Y) / ray.Direction.Y
		position = if distance > 0 then ray.Origin + ray.Direction * distance else nil
	end
	-- Once a drag has started, keep its endpoint clamped to the plot even when the
	-- cursor ray moves beyond the finite build plane.
	if not position and activeDrag and math.abs(ray.Direction.Y) > 0.0001 then
		local distance = (targetY - ray.Origin.Y) / ray.Direction.Y
		if distance > 0 then
			position = ray.Origin + ray.Direction * distance
		end
	end
	if not position and activeDrag then
		local last = grid:GetCellCenter(activeDrag.LastX, activeDrag.LastZ)
		return activeDrag.LastX, activeDrag.LastZ, Vector3.new(last.X, targetY, last.Z)
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
	elseif pickMode then
		mode = "PICK"
	elseif paintObjectMode then
		mode = "PAINT"
	elseif paintMode then
		mode = `Floor: {Materials.Floor[paintMaterial].Material}`
	elseif ceilingMode then
		mode = `Ceiling: {Materials.Ceiling[ceilingMaterial].Material}`
	else
		mode = `Place: {selectedAsset or "none"}{if Linked then " (my palette)" else ""}`
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

local function requestHistory(action: "undo" | "redo")
	local changed, reason = historyRemote:InvokeServer(action)
	refreshStatus(if changed then action else reason)
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

local function deleteEndpointMoved(state: DeleteDragState, x: number, z: number): boolean
	if state.DragMode == "Line" then
		return if state.Rotation % 2 == 0 then x ~= state.StartX else z ~= state.StartZ
	end
	return x ~= state.StartX or z ~= state.StartZ
end

-- Selects compatible draggable placements whose occupancy intersects the same shape
-- placement dragging would produce from the starting item.
local function deleteSelection(state: DeleteDragState, endX: number, endZ: number): { Model }
	if state.MovedAway and not deleteEndpointMoved(state, endX, endZ) then
		return {}
	end
	local name = state.Name
	if not name then
		return {}
	end
	local base = getMyPlotBase()
	local built = base and base.Parent and base.Parent:FindFirstChild("Built")
	if not built then
		return {}
	end
	local placementState: DragState = {
		Mode = "Item",
		StartX = state.StartX,
		StartZ = state.StartZ,
		LastX = endX,
		LastZ = endZ,
		Floor = state.Floor,
		Rotation = state.Rotation,
		Name = name,
		Material = nil,
	}
	local selectedKeys = {}
	for _, request in dragPlacements(placementState, endX, endZ) do
		local cells, edges = SharedBuildingService:ResolveOccupancy(
			name,
			request.X,
			request.Z,
			request.Floor,
			request.Rotation
		)
		for _, key in cells do selectedKeys[key] = true end
		for _, key in edges do selectedKeys[key] = true end
	end

	local models = {}
	for _, model in built:GetChildren() do
		local name = model:GetAttribute("AssetName")
		local entry = type(name) == "string" and SharedBuildingService:GetEntry(name)
		if not entry or entry.Type ~= state.ItemType or entry.Draggable ~= state.DragMode then
			continue
		end
		local cells, edges = SharedBuildingService:ResolveOccupancy(
			name,
			model:GetAttribute("GridX"),
			model:GetAttribute("GridZ"),
			model:GetAttribute("Floor"),
			model:GetAttribute("Rotation")
		)
		local selected = false
		for _, key in cells do selected = selected or selectedKeys[key] == true end
		for _, key in edges do selected = selected or selectedKeys[key] == true end
		if selected then
			table.insert(models, model)
		end
	end
	return models
end

local function deleteCells(state: DeleteDragState, endX: number, endZ: number): { CellRequest }
	if state.MovedAway and not deleteEndpointMoved(state, endX, endZ) then
		return {}
	end
	return rectangleCells(state.StartX, state.StartZ, endX, endZ)
end

-- Rendered floor rectangles may cover many cells after greedy meshing.
local function floorPartAt(container: Instance?, grid: Grid.Grid, x: number, z: number, floor: number): BasePart?
	if not container then
		return nil
	end
	local centre = grid:GetCellCenter(x, z)
	for _, part in container:GetChildren() do
		if part:IsA("BasePart") and part:GetAttribute("FloorLevel") == floor then
			local localPoint = part.CFrame:PointToObjectSpace(centre)
			if math.abs(localPoint.X) <= part.Size.X / 2 and math.abs(localPoint.Z) <= part.Size.Z / 2 then
				return part
			end
		end
	end
	return nil
end

local function renderedFloorMaterial(container: Instance?, grid: Grid.Grid, x: number, z: number, floor: number): number?
	local part = floorPartAt(container, grid, x, z, floor)
	return if part then part:GetAttribute("MaterialIndex") :: number else if floor == 1 then 1 else nil
end

local function existingDeleteCells(state: DeleteDragState, cells: { CellRequest }): { CellRequest }
	local base = getMyPlotBase()
	local plot = base and base.Parent
	local container = plot and plot:FindFirstChild(if state.Kind == "Ceiling" then "Ceilings" else "Floor")
	if not base or not container then
		return {}
	end
	local grid = Grid.new(base)
	local existing = {}
	for _, cell in cells do
		if state.Kind == "Ceiling" then
			if container:FindFirstChild(Grid.ceilingKey(cell.X, cell.Z, state.Floor)) then
				table.insert(existing, cell)
			end
			continue
		end
		if floorPartAt(container, grid, cell.X, cell.Z, state.Floor) then
			table.insert(existing, cell)
		end
	end
	return existing
end

local function updateDeleteCells(
	grid: Grid.Grid,
	kind: "Ceiling" | "Floor",
	floor: number,
	cells: { CellRequest }
)
	hideDeleteHighlight()
	local ceiling = kind == "Ceiling"
	local y = grid.Origin.Y
		+ (if ceiling then SharedBuildingService:GetLevelTopOffset(floor) else SharedBuildingService:GetLevelBaseOffset(floor))
	for index, cell in cells do
		local centre = grid:GetCellCenter(cell.X, cell.Z)
		local indicator = getIndicator(index)
		indicator.Size = Vector3.new(
			Building.CELL_SIZE,
			if ceiling then Building.CEILING_THICKNESS else 0.1,
			Building.CELL_SIZE
		)
		indicator.CFrame = CFrame.new(
			centre.X,
			y + (if ceiling then -Building.CEILING_THICKNESS / 2 else Building.FLOOR_THICKNESS + 0.05),
			centre.Z
		)
		local outline = indicator:FindFirstChild("Outline") :: SelectionBox
		outline.SurfaceColor3 = outline.Color3
		outline.SurfaceTransparency = DELETE_FILL_TRANSPARENCY
		outline.Visible = true
		indicator.Parent = indicatorFolder
	end
	for index = #cells + 1, #indicators do
		indicators[index].Parent = nil
	end
end

--[[Outlines the visible placement or exact merged-floor cell under the cursor.]]
local function updateDeleteHover()
	hideTilePreview()
	local target, hitPosition = deleteRaycast()
	local model = findPlacementModel(target)
	local ceiling = findCeilingPart(target)
	if model or ceiling then
		hideIndicators()
		setDeleteHighlights({ model or ceiling })
		return
	end

	local floor = target and target:GetAttribute("FloorLevel")
	local base = getMyPlotBase()
	if typeof(floor) ~= "number" or not base or not hitPosition then
		hideIndicators()
		hideDeleteHighlight()
		return
	end
	local grid = Grid.new(base)
	local x, z = grid:WorldToCell(hitPosition)
	updateDeleteCells(grid, "Floor", floor, {
		{ X = math.clamp(x, 0, grid.Width - 1), Z = math.clamp(z, 0, grid.Depth - 1) },
	})
end

local function updateDeleteHighlight()
	local state = deleteDragState
	if not state then
		updateDeleteHover()
		return
	end
	hideTilePreview()
	local base = getMyPlotBase()
	if not base then
		hideDeleteHighlight()
		hideIndicators()
		return
	end
	local grid = Grid.new(base)
	local x, z = cellUnderCursor(grid, state.Floor, state.Kind == "Ceiling", state.PlaneY)
	if x ~= nil and z ~= nil then
		state.LastX, state.LastZ = x, z
		state.MovedAway = state.MovedAway or deleteEndpointMoved(state, x, z)
	end
	if state.Kind == "Placement" then
		hideIndicators()
		setDeleteHighlights(deleteSelection(state, state.LastX, state.LastZ))
	else
		local cells = existingDeleteCells(state, deleteCells(state, state.LastX, state.LastZ))
		updateDeleteCells(grid, state.Kind, state.Floor, cells)
	end
end

--[[
Returns the instance under the cursor a colour tool can act on: a colourable placement, a
ceiling slab, or a painted floor tile.
]]
local function colorHover(): Instance?
	local target = (deleteRaycast())
	local model = findPlacementModel(target)
	if model then
		local name = model:GetAttribute("AssetName")
		return if type(name) == "string" and SharedColorService:IsColorable(name) then model else nil
	end
	local ceiling = findCeilingPart(target)
	if ceiling then
		return ceiling
	end
	return if target and target:GetAttribute("FloorLevel") then target else nil
end

local function updateColorHover()
	hideTilePreview()
	hideIndicators()
	local target = colorHover()
	if target then
		setDeleteHighlights({ target :: any }, RECOLOR_COLOR)
	else
		hideDeleteHighlight()
	end
end

--[[
The cells a rendered floor tile covers. Greedy meshing merges same-material, same-tint
runs into one part, so clicking a tile recolours the whole visible rectangle rather than
splitting one cell out of it.
]]
local function floorCellsOfPart(grid: Grid.Grid, part: BasePart): { CellRequest }
	local cell = Building.CELL_SIZE
	local minCorner = part.Position - Vector3.new(part.Size.X / 2, 0, part.Size.Z / 2)
	local startX, startZ = grid:WorldToCell(minCorner + Vector3.new(cell / 2, 0, cell / 2))
	local cells = {}
	for z = 0, math.round(part.Size.Z / cell) - 1 do
		for x = 0, math.round(part.Size.X / cell) - 1 do
			table.insert(cells, { X = startX + x, Z = startZ + z })
		end
	end
	return cells
end

local function createGhost(name: string): Model?
	local model = SharedBuildingService:GetModel(name)
	if not model then
		return nil
	end
	local ghost = model:Clone()
	SharedColorService:ApplyColors(ghost, name, currentColors(name))
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

	if not buildMode or deleteMode or paintMode or ceilingMode or paintObjectMode or pickMode or not selectedAsset then
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
			outline.SurfaceTransparency = 1
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
		local floorContainer = base.Parent:FindFirstChild("Floor")
		local previewCount = 0
		for _, cell in cells do
			if renderedFloorMaterial(floorContainer, grid, cell.X, cell.Z, targetFloor) == paintMaterial then
				continue
			end
			previewCount += 1
			local centre = grid:GetCellCenter(cell.X, cell.Z)
			local valid = SharedBuildingService:CanPaintFloor(grid, cell.X, cell.Z, targetFloor)
			setTilePreview(
				previewCount,
				CFrame.new(centre.X, grid.Origin.Y + topOffset + Building.FLOOR_THICKNESS + 0.05, centre.Z),
				Vector3.new(Building.CELL_SIZE, 0.1, Building.CELL_SIZE),
				valid,
				false
			)
		end
		for index = previewCount + 1, #tilePreviews do
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
				local entry = SharedBuildingService:GetEntry(name)
				SharedBuildingService:PivotModelToLevel(
					model,
					groundCF,
					grid.Origin.Y,
					request.Floor,
					entry and entry.Type
				)
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

--[[
Stamps the global colour selection onto whatever was clicked. A placement takes the slots
it defines; a floor tile or ceiling slab is treated as one divider, taking Color 1 on its
ceiling underside and Color 2 on the floor above it.
]]
--[[
Paint accumulates everything the cursor sweeps over while held, then commits once on
release. An ordinary click is just a drag that never moved, so there's one path.
]]
local function addPaintTarget()
	local state = paintDragState
	local target = colorHover()
	if not state or not target or state.Seen[target] then
		return
	end
	state.Seen[target] = true
	table.insert(state.Targets, target)
end

local function beginPaintDrag()
	paintDragState = { Targets = {}, Seen = {} }
	addPaintTarget()
end

local function updatePaintDrag()
	hideTilePreview()
	hideIndicators()
	addPaintTarget()
	setDeleteHighlights((paintDragState :: PaintDragState).Targets :: any, RECOLOR_COLOR)
end

local function finishPaintDrag()
	local state = paintDragState
	paintDragState = nil
	hideDeleteHighlight()
	if not state or #state.Targets == 0 then
		refreshStatus("nothing colourable there")
		return
	end

	local base = getMyPlotBase()
	local grid = base and Grid.new(base)
	local placementIds = {}
	-- Surface cells grouped by divider level, since one call covers one level.
	local surfaces: { [number]: { CellRequest } } = {}
	local seenCells = {}

	local function addCell(ceilingFloor: number, x: number, z: number)
		local key = `{ceilingFloor}:{x},{z}`
		if seenCells[key] then
			return
		end
		seenCells[key] = true
		surfaces[ceilingFloor] = surfaces[ceilingFloor] or {}
		table.insert(surfaces[ceilingFloor], { X = x, Z = z })
	end

	for _, target in state.Targets do
		if target:IsA("Model") then
			table.insert(placementIds, target:GetAttribute("PlacementId"))
		elseif target:GetAttribute("TopOffset") ~= nil then
			addCell(
				target:GetAttribute("Floor") :: number,
				target:GetAttribute("GridX") :: number,
				target:GetAttribute("GridZ") :: number
			)
		elseif grid then
			local ceilingFloor = (target:GetAttribute("FloorLevel") :: number) - 1
			for _, cell in floorCellsOfPart(grid, target :: BasePart) do
				addCell(ceilingFloor, cell.X, cell.Z)
			end
		end
	end

	-- Colours go unsanitised: the server sanitises per placement, so one sweep can cover
	-- several asset types at once.
	local painted, failure = 0, nil
	if #placementIds > 0 then
		local count, reason = recolorRemote:InvokeServer(placementIds, PlaceColors, false)
		painted += count
		failure = failure or reason
	end
	for ceilingFloor, cells in surfaces do
		local count, reason = ceilingRemote:InvokeServer("surface", cells, ceilingFloor, PlaceColors)
		painted += count
		failure = failure or reason
	end
	refreshStatus(if failure then `rejected: {failure}` else `painted {painted}`)
end

--[[
Reads every colour off whatever was clicked and makes it the current selection. A
placement gives up the slots it defines; a floor or ceiling gives Color 1 from the ceiling
underside and Color 2 from the floor above, matching how the Paint tool writes them back.
]]
local function pickTarget()
	local target = colorHover()
	if not target then
		refreshStatus("nothing colourable there")
		return
	end

	local picked: SharedColorService.SlotMap
	if target:IsA("Model") then
		local name = target:GetAttribute("AssetName") :: string
		picked = SharedColorService:ReadColors(target, name)
	else
		local base = getMyPlotBase()
		local plot = base and base.Parent
		local ceilingFloor, cellX, cellZ
		if target:GetAttribute("TopOffset") ~= nil then
			ceilingFloor = target:GetAttribute("Floor") :: number
			cellX, cellZ = target:GetAttribute("GridX") :: number, target:GetAttribute("GridZ") :: number
		else
			ceilingFloor = (target:GetAttribute("FloorLevel") :: number) - 1
			local x, z = Grid.new(base :: BasePart):WorldToCell((target :: BasePart).Position)
			cellX, cellZ = x, z
		end

		-- Read the partner face off the rendered instances so picking one surface fills
		-- both slots, the same pair the Paint tool would write.
		picked = {}
		local ceilings = plot and plot:FindFirstChild("Ceilings")
		local slab = ceilings and ceilings:FindFirstChild(Grid.ceilingKey(cellX, cellZ, ceilingFloor))
		if slab then
			picked[1] = SharedColorService.Pack((slab :: BasePart).Color)
		end
		local floors = plot and plot:FindFirstChild("Floor")
		local tile = base and floorPartAt(floors, Grid.new(base), cellX, cellZ, ceilingFloor + 1)
		if tile then
			picked[2] = SharedColorService.Pack(tile.Color)
		end
	end

	ClientBuildingService:SetPlaceColors(picked, nil)
	refreshColorPage()
	-- Eyedropper convention: hand the brush straight back.
	pickMode, paintObjectMode = false, true
	refreshStatus("picked colours")
end

local function onClick()
	if not buildMode then
		return
	end
	if pickMode then
		pickTarget()
		return
	end
	-- Delete mode prioritises rendered placements/ceilings under the cursor. A rendered
	-- floor overlay is removed independently from its supporting ceiling.
	if deleteMode then
		local target, hitPosition = deleteRaycast()
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
		if not (base and target and hitPosition) then
			refreshStatus("nothing to delete")
			return
		end
		-- Delete targets the physical thing under the cursor, so use the raw mouse hit.
		local grid = Grid.new(base)
		local rawX, rawZ = grid:WorldToCell(hitPosition)
		local x, z = math.clamp(rawX, 0, grid.Width - 1), math.clamp(rawZ, 0, grid.Depth - 1)
		local floorLevel = target:GetAttribute("FloorLevel")
		local level = if typeof(floorLevel) == "number" then floorLevel else currentFloor
		local ok = ClientBuildingService:RequestPaint(x, z, level, 0)
		refreshStatus(if ok then `removed floor ({x},{z})` else "nothing to delete")
		return
	end

	-- Nothing active: clicking a placeable selects it, which is what opens the item panel.
	if not paintMode and not ceilingMode and not selectedAsset then
		local model = findPlacementModel((deleteRaycast()))
		if model then
			ClientBuildingService.PlacementSelected:Fire(model)
			refreshStatus(`selected {model:GetAttribute("AssetName")}`)
		else
			ClientBuildingService.PlacementSelected:Fire(nil)
			refreshStatus("select an asset first")
		end
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

-- Draggable catalog items use their placement drag geometry for deletion. Everything
-- else retains immediate click deletion.
local function beginDeleteDrag(): boolean
	local target, hitPosition = deleteRaycast()
	if not target or not hitPosition then
		return false
	end
	local model = findPlacementModel(target)
	if model then
		local name = model:GetAttribute("AssetName")
		local entry = type(name) == "string" and SharedBuildingService:GetEntry(name)
		if not entry or not entry.Draggable then
			return false
		end
		deleteDragState = {
			Kind = "Placement",
			StartX = model:GetAttribute("GridX"),
			StartZ = model:GetAttribute("GridZ"),
			LastX = model:GetAttribute("GridX"),
			LastZ = model:GetAttribute("GridZ"),
			Floor = model:GetAttribute("Floor"),
			PlaneY = hitPosition.Y,
			Rotation = model:GetAttribute("Rotation"),
			Name = name,
			ItemType = entry.Type,
			DragMode = entry.Draggable,
			MovedAway = false,
		}
		return true
	end

	local ceiling = findCeilingPart(target)
	local base = getMyPlotBase()
	local floor = target:GetAttribute("FloorLevel")
	if not ceiling and (typeof(floor) ~= "number" or not base) then
		return false
	end
	local grid = base and Grid.new(base)
	local x, z
	if ceiling then
		x, z, floor = ceiling:GetAttribute("GridX"), ceiling:GetAttribute("GridZ"), ceiling:GetAttribute("Floor")
	else
		local rawX, rawZ = grid:WorldToCell(hitPosition)
		x, z = math.clamp(rawX, 0, grid.Width - 1), math.clamp(rawZ, 0, grid.Depth - 1)
	end
	deleteDragState = {
		Kind = if ceiling then "Ceiling" else "Floor",
		StartX = x,
		StartZ = z,
		LastX = x,
		LastZ = z,
		Floor = floor,
		PlaneY = hitPosition.Y,
		Rotation = 0,
		Name = nil,
		ItemType = nil,
		DragMode = "Area",
		MovedAway = false,
	}
	return true
end

local function finishDeleteDrag()
	local state = deleteDragState
	if not state then
		return
	end
	local base = getMyPlotBase()
	if base then
		local grid = Grid.new(base)
		local x, z = cellUnderCursor(grid, state.Floor, state.Kind == "Ceiling", state.PlaneY)
		if x ~= nil and z ~= nil then
			state.LastX, state.LastZ = x, z
			state.MovedAway = state.MovedAway or deleteEndpointMoved(state, x, z)
		end
	end
	deleteDragState = nil
	hideDeleteHighlight()
	hideIndicators()
	if state.Kind == "Placement" then
		local models = deleteSelection(state, state.LastX, state.LastZ)
		if #models == 0 then
			refreshStatus("delete cancelled")
			return
		end
		local placementIds = {}
		for _, model in models do
			table.insert(placementIds, model:GetAttribute("PlacementId"))
		end
		local removed = removeRemote:InvokeServer(placementIds)
		refreshStatus(if removed > 0 then `removed {removed}/{#placementIds}` else "remove failed")
		return
	end

	local cells = existingDeleteCells(state, deleteCells(state, state.LastX, state.LastZ))
	if #cells == 0 then
		refreshStatus("delete cancelled")
		return
	end
	if state.Kind == "Ceiling" then
		local removed = ceilingRemote:InvokeServer("remove", cells, state.Floor)
		refreshStatus(if removed > 0 then `removed {removed}/{#cells} ceilings` else "remove failed")
	else
		local removed, reason = paintRemote:InvokeServer(cells, state.Floor, 0)
		refreshStatus(if removed > 0 then `removed {removed}/{#cells} floors` else `rejected: {reason}`)
	end
end

--[[Starts a configured item drag, or an area drag for the floor/ceiling tools. A
non-draggable catalog item returns false so the caller can use normal click placement.]]
local function beginDrag(): boolean
	if not buildMode or deleteMode or paintObjectMode or pickMode then
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
		local placed, reason =
			placeRemote:InvokeServer(
				state.Name,
				requests,
				currentColors(state.Name),
				ClientBuildingService:IsLinked(state.Name)
			)
		refreshStatus(if placed > 0 then `placed {placed}/{#requests}` else `rejected: {reason}`)
	else
		local requests = rectangleCells(state.StartX, state.StartZ, state.LastX, state.LastZ)
		if state.Mode == "Paint" then
			local color = surfaceColor("Floor")
			local painted, reason = paintRemote:InvokeServer(requests, state.Floor, state.Material, color)
			refreshStatus(if painted > 0 then `painted {painted}/{#requests}` else `rejected: {reason}`)
		else
			local color = surfaceColor("Ceiling")
			local placed, reason = ceilingRemote:InvokeServer("place", requests, state.Floor, state.Material, color)
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
		historyRemote:InvokeServer("clear")
		dragState = nil
		deleteDragState = nil
		paintDragState = nil
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
	tools.Size = UDim2.new(1, -8, 0, 180)
	tools.Position = UDim2.fromOffset(4, 46)
	tools.BackgroundTransparency = 1
	tools.Parent = panel

	local toolLayout = Instance.new("UIGridLayout")
	toolLayout.CellPadding = UDim2.fromOffset(2, 2)
	toolLayout.CellSize = UDim2.new(0.5, -1, 0, 24)
	toolLayout.Parent = tools

	local tabs = Instance.new("Frame")
	tabs.Size = UDim2.new(1, -8, 0, 26)
	tabs.Position = UDim2.fromOffset(4, 230)
	tabs.BackgroundTransparency = 1
	tabs.Parent = panel

	local tabLayout = Instance.new("UIGridLayout")
	tabLayout.CellPadding = UDim2.fromOffset(2, 0)
	tabLayout.CellSize = UDim2.new(0.2, -2, 1, 0)
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
		page.Size = UDim2.new(1, -8, 1, -264)
		page.Position = UDim2.fromOffset(4, 260)
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
	addButton(tools, "Undo", function()
		requestHistory("undo")
	end)
	addButton(tools, "Redo", function()
		requestHistory("redo")
	end)
	local resetArmed = false
	local resetVersion = 0
	local resetButton: TextButton
	resetButton = addButton(tools, "Reset Base", function()
		if not resetArmed then
			resetArmed = true
			resetVersion += 1
			local version = resetVersion
			resetButton.Text = "CONFIRM RESET"
			task.delay(3, function()
				if resetArmed and resetVersion == version then
					resetArmed = false
					resetButton.Text = "Reset Base"
				end
			end)
			return
		end
		resetArmed = false
		resetVersion += 1
		resetButton.Text = "Reset Base"
		local reset = resetRemote:InvokeServer()
		if reset then
			currentFloor = 1
			if freeCameraMode then
				cameraController:SetLevel(currentFloor)
			end
		end
		refreshStatus(if reset then "base reset" else "reset failed")
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
	addButton(tools, "Paint", function()
		local wasPaint = paintObjectMode
		clearModes()
		selectedAsset = nil
		paintObjectMode = not wasPaint
		refreshColorPage()
		rebuildPreview()
		refreshStatus()
	end)
	addButton(tools, "Pick", function()
		local wasPick = pickMode
		clearModes()
		selectedAsset = nil
		pickMode = not wasPick
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
	local colorPage = addPage("Colors")

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
			-- Re-clicking the selected asset deselects it, which is how you reach the
			-- neutral state where clicking a placeable opens its panel.
			addButton(page, name, function()
				local wasSelected = selectedAsset == name
				clearModes()
				selectedAsset = if wasSelected then nil else name
				refreshColorPage()
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
		addButton(ceilingPage, material.Material, function()
			clearModes()
			ceilingMode = true
			ceilingMaterial = index
			refreshColorPage()
			rebuildPreview()
			refreshStatus()
		end)
	end

	for index, material in Materials.Floor do
		addButton(floorPage, material.Material, function()
			clearModes()
			paintMode = true
			paintMaterial = index
			refreshColorPage()
			rebuildPreview()
			refreshStatus()
		end)
	end

	-- The Colors page edits the one global selection: always all five slots, unlabelled.
	-- Per-object slot names ("Pot", "Trunk") belong to the item panel, where you can see
	-- which object they apply to.
	local slotBoxes: { [number]: TextBox } = {}

	local function refreshSlots()
		local colors = ClientBuildingService:GetPlaceColors()
		for slot, box in slotBoxes do
			local packed = colors[slot]
			local color = if packed then SharedColorService.Unpack(packed) else Color3.fromRGB(45, 45, 45)
			box.BackgroundColor3 = color
			local luminance = color.R * 0.299 + color.G * 0.587 + color.B * 0.114
			box.TextColor3 = if packed and luminance > 0.55 then Color3.new() else Color3.new(1, 1, 1)
		end
		rebuildPreview()
		refreshStatus()
	end

	refreshColorPage = function()
		for _, child in colorPage:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
		table.clear(slotBoxes)

		local name = selectedAsset

		addButton(colorPage, "Reset To Default", function()
			ClientBuildingService:SetPlaceColors(nil, nil)
			refreshColorPage()
		end)

		if name and SharedColorService:IsColorable(name) then
			-- Config palettes stamp their colours into the slots and are then forgotten.
			for _, palette in SharedColorService:GetPalettes(name) do
				addButton(colorPage, palette.Name, function()
					ClientBuildingService:SetPlaceColors(palette.Colors, nil)
					refreshColorPage()
				end)
			end
			-- The saved palette stays a live link so future edits can propagate.
			local saved, savedName = ClientBuildingService:GetSavedPalette(name)
			if saved then
				addButton(colorPage, `Use "{savedName}" (linked)`, function()
					ClientBuildingService:SetPlaceColors(saved, name)
					refreshColorPage()
				end)
			end
		end

		for slot = 1, Building.COLOR_SLOTS do
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -8, 0, 24)
			row.BackgroundTransparency = 1
			row.Parent = colorPage

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(0.45, 0, 1, 0)
			label.BackgroundTransparency = 1
			label.TextColor3 = Color3.new(1, 1, 1)
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = `Color {slot}`
			label.Parent = row

			local box = Instance.new("TextBox")
			box.Size = UDim2.new(0.55, 0, 1, 0)
			box.Position = UDim2.new(0.45, 0, 0, 0)
			box.BorderSizePixel = 0
			box.ClearTextOnFocus = false
			box.PlaceholderText = "#rrggbb"
			box.Text = ""
			box.Parent = row
			slotBoxes[slot] = box

			box.FocusLost:Connect(function()
				local packed = SharedColorService.ParseColor(box.Text)
				ClientBuildingService:SetPlaceColor(slot, packed)
				if not packed then
					box.Text = ""
				end
				refreshSlots()
			end)
		end

		addNotice(colorPage, "255,128,0 or #ff8000. Empty = keep the object's own colour.")
		refreshSlots()
	end

	showPage("Walls")
	refreshColorPage()
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
	if paintObjectMode or pickMode then
		hideBuildPlane()
		if paintDragState then
			updatePaintDrag()
		else
			updateColorHover()
		end
	elseif deleteMode then
		-- Hover targets real objects; an active drag can optionally show one stable grid plane.
		if not deleteDragState then
			hideBuildPlane()
		end
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
	end
	local controlDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	local shiftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if controlDown and input.KeyCode == Enum.KeyCode.Z then
		requestHistory(if shiftDown then "redo" else "undo")
	elseif controlDown and input.KeyCode == Enum.KeyCode.Y then
		requestHistory("redo")
	elseif input.KeyCode == Enum.KeyCode.R then
		rotateSelection()
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		if deleteMode then
			if not beginDeleteDrag() then
				onClick()
			end
		elseif paintObjectMode then
			beginPaintDrag()
		elseif not beginDrag() then
			onClick()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if paintDragState then
			finishPaintDrag()
		elseif deleteDragState then
			finishDeleteDrag()
		else
			finishDrag()
		end
	end
end)

return ClientBuildingService
