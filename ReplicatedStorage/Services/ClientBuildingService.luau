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

--[[Requests a placement. Returns the server's (placementId?, reason?) so the caller
can confirm or roll back its preview. Assumes the caller already previewed with
SharedBuildingService:CanPlace so this normally matches what the server accepts.]]
function ClientBuildingService:RequestPlace(name: string, x: number, z: number, floor: number, rotation: number): (number?, string?)
	return placeRemote:InvokeServer(name, x, z, floor, rotation)
end

--[[Requests removal of a placement by id (read from the rendered instance). Returns success.]]
function ClientBuildingService:RequestRemove(placementId: number): boolean
	return removeRemote:InvokeServer(placementId)
end

--[[Requests painting a cell's floor material. Returns success + reason.]]
function ClientBuildingService:RequestPaint(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	return paintRemote:InvokeServer(x, z, floor, materialIndex)
end

--[[Requests placing a ceiling at the top of the selected wall level.]]
function ClientBuildingService:RequestPlaceCeiling(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	return ceilingRemote:InvokeServer("place", x, z, floor, materialIndex)
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

--[[Clears every non-place mode. Callers then set the one they want.]]
local function clearModes()
	deleteMode = false
	paintMode = false
	ceilingMode = false
end

-- Live preview ("ghost") of the selected asset, following the cursor.
local previewModel: Model? = nil

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

-- Cell preview shared by floor painting and ceiling placement.
local tilePreview = Instance.new("Part")
tilePreview.Name = "BuildingTilePreview"
tilePreview.Anchored = true
tilePreview.CanCollide = false
tilePreview.CanQuery = false
tilePreview.CastShadow = false
tilePreview.Transparency = 1

local tileOutline = Instance.new("SelectionBox")
tileOutline.Name = "Outline"
tileOutline.Adornee = tilePreview
tileOutline.LineThickness = 0.05
tileOutline.SurfaceTransparency = 0.75
tileOutline.Parent = tilePreview

local function hideTilePreview()
	tilePreview.Parent = nil
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
local function cellUnderCursor(grid: Grid.Grid): (number?, number?, Vector3?)
	local targetY = if ceilingMode
		then grid.Origin.Y + SharedBuildingService:GetLevelTopOffset(currentFloor)
		else floorBaseY(grid, currentFloor)
	positionBuildPlane(grid, targetY)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { buildPlane }
	local ray = player:GetMouse().UnitRay
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	if not result then
		return nil, nil, nil
	end

	local x, z = grid:WorldToCell(result.Position)
	return math.clamp(x, 0, grid.Width - 1), math.clamp(z, 0, grid.Depth - 1), result.Position
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

--[[Rebuilds the preview ghost from the current selection. Destroys any old one.
The ghost is a non-collidable, non-queryable, semi-transparent clone so it doesn't block
the placement raycast.]]
local function rebuildPreview()
	if previewModel then
		previewModel:Destroy()
		previewModel = nil
	end

	if not buildMode or deleteMode or paintMode or ceilingMode or not selectedAsset then
		return
	end

	local model = SharedBuildingService:GetModel(selectedAsset)
	if not model then
		return
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
	previewModel = ghost
end

--[[Positions an invisible hitbox over each footprint piece (sized to the model) and shows
its red outline only when that piece is out of bounds or its occupancy key is already
taken in the mirror grid - the exact same check that blocks placement server-side.]]
local function updateIndicators(grid: Grid.Grid, x: number, z: number, rotation: number)
	local pieces = SharedBuildingService:GetHitboxPieces(grid, selectedAsset, x, z, currentFloor, rotation)
	local canPlace = SharedBuildingService:CanPlace(grid, selectedAsset, x, z, currentFloor, rotation)

	for i, piece in pieces do
		local indicator = getIndicator(i)
		indicator.Size = piece.Size
		indicator.CFrame = piece.CFrame

		local colliding = not canPlace or not piece.InBounds or grid:IsOccupied(piece.Key)

		local outline = indicator:FindFirstChild("Outline") :: SelectionBox
		outline.Visible = colliding
		indicator.Parent = indicatorFolder
	end

	-- Hide any pooled indicators beyond this footprint's size.
	for i = #pieces + 1, #indicators do
		indicators[i].Parent = nil
	end
end

local function setTilePreview(cframe: CFrame, size: Vector3, valid: boolean, filled: boolean)
	local color = if valid then Color3.fromRGB(65, 210, 105) else Color3.fromRGB(220, 60, 60)
	tilePreview.Size = size
	tilePreview.CFrame = cframe
	tilePreview.Color = color
	tilePreview.Transparency = if filled then 0.65 else 1
	tileOutline.Color3 = color
	tileOutline.SurfaceColor3 = color
	tilePreview.Parent = indicatorFolder
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
	local x, z = cellUnderCursor(grid)
	if x == nil or z == nil then
		hideTilePreview()
		return
	end
	local centre = grid:GetCellCenter(x, z)

	if paintMode then
		local topOffset = SharedBuildingService:GetLevelBaseOffset(currentFloor)
		local valid = currentFloor == 1 or grid:GetCeiling(x, z, currentFloor - 1) ~= nil
		setTilePreview(
			CFrame.new(centre.X, grid.Origin.Y + topOffset + 0.05, centre.Z),
			Vector3.new(Building.CELL_SIZE, 0.1, Building.CELL_SIZE),
			valid,
			false
		)
		return
	end

	local topOffset = SharedBuildingService:GetLevelTopOffset(currentFloor)
	local supported = SharedBuildingService:GetCeilingTopOffset(grid, x, z, currentFloor) ~= nil
	local valid = supported and grid:GetCeiling(x, z, currentFloor) == nil
	setTilePreview(
		CFrame.new(centre.X, grid.Origin.Y + topOffset - Building.CEILING_THICKNESS / 2, centre.Z),
		Vector3.new(Building.CELL_SIZE, Building.CEILING_THICKNESS, Building.CELL_SIZE),
		valid,
		true
	)
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
		local x, z, hitPosition = cellUnderCursor(grid)
		if x == nil or z == nil or hitPosition == nil then
			previewModel:PivotTo(CFrame.new(0, -1000, 0))
			hideIndicators()
			return
		end
		local rotation = resolvePlacementRotation(grid, selectedAsset, x, z, hitPosition)
		local groundCF = SharedBuildingService:GetPlacementCFrame(grid, selectedAsset, x, z, rotation)
		if groundCF then
			SharedBuildingService:PivotModelToLevel(previewModel, groundCF, grid.Origin.Y, currentFloor)
			updateIndicators(grid, x, z, rotation)
			return
		end
	end
	-- No valid target: park the ghost far below the map and hide indicators.
	previewModel:PivotTo(CFrame.new(0, -1000, 0))
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
		local id, reason = ClientBuildingService:RequestPlace(selectedAsset :: string, x, z, currentFloor, rotation)
		refreshStatus(if id then `placed ({x},{z})` else `rejected: {reason}`)
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
		freeCameraMode = false
		cameraController:SetEnabled(false)
		if previewModel then
			previewModel:PivotTo(CFrame.new(0, -1000, 0))
		end
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
		onClick()
	end
end)

return ClientBuildingService
