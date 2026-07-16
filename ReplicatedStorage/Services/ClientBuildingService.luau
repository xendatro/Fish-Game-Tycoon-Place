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
local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local SharedBuildingService = require(ReplicatedStorage.Services.SharedBuildingService)
-- Measured height of the shortest wall - the height one build floor adds. Used as the
-- default surface height for elevated-floor previews (config levels can disagree with models).
local MIN_WALL_HEIGHT = SharedBuildingService:GetShortestWallHeight()

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
function ClientBuildingService:RequestPlace(name: string, x: number, z: number, floor: number, rotation: number, height: number?): (number?, string?)
	return placeRemote:InvokeServer(name, x, z, floor, rotation, height)
end

--[[Requests removal of a placement by id (read from the rendered instance). Returns success.]]
function ClientBuildingService:RequestRemove(placementId: number): boolean
	return removeRemote:InvokeServer(placementId)
end

--[[Requests painting a cell's floor material. Returns success + reason.]]
function ClientBuildingService:RequestPaint(x: number, z: number, floor: number, materialIndex: number): (boolean, string?)
	return paintRemote:InvokeServer(x, z, floor, materialIndex)
end

--[[Requests placing a ceiling at a cell. `desiredTopOffset` is the mouse-chosen support
height; the server validates it and otherwise snaps to the highest.]]
function ClientBuildingService:RequestPlaceCeiling(x: number, z: number, floor: number, materialIndex: number, desiredTopOffset: number?): (boolean, string?)
	return ceilingRemote:InvokeServer("place", x, z, floor, materialIndex, desiredTopOffset)
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
-- TODO(real system): replace this panel/input with the final build UI and free camera.
-- ===========================================================================

local selectedAsset: string? = nil
local currentRotation = 0
local currentHeight = 1 -- height level for extendables (1..4)
local currentFloor = 1 -- which floor placement/painting targets
local deleteMode = false
local paintMode = false
local paintMaterial = 2 -- floor material index while painting (1 = grass/revert)
local ceilingMode = false
local ceilingMaterial = 1 -- ceiling material index while placing ceilings
local statusLabel: TextLabel
local HeightButton: TextButton?
local FloorButton: TextButton?
local lastPreviewFloorOffsets: { [number]: number } = {}
local lastCeilingTopOffsets: { [number]: number } = {}
local heightForSelection: () -> number?

-- The ceiling height the player is currently aiming at, kept between frames so height
-- switching has hysteresis (doesn't flip-flop between two candidates near a boundary).
local activeCeilingOffset: number? = nil
local CEILING_SWITCH_MARGIN = 22 -- px another candidate must beat the current one by to switch

--[[Clears every non-place mode. Callers then set the one they want.]]
local function clearModes()
	deleteMode = false
	paintMode = false
	ceilingMode = false
	activeCeilingOffset = nil
end

-- Live preview ("ghost") of the selected asset, following the cursor.
local previewModel: Model? = nil
local previewSize: Vector3? = nil

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
			local height = model:GetAttribute("Height")
			local cells, edges = SharedBuildingService:ResolveOccupancy(name, x, z, floor, rotation, height)
			grid:AddPlacement({
				Name = name,
				X = x,
				Z = z,
				Floor = floor,
				Rotation = rotation,
				Height = height,
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

--[[The default world Y of a floor's surface: floor 1 is the plot top; each higher floor
adds one (shortest) wall height.]]
local function floorBaseY(grid: Grid.Grid, floor: number): number
	return grid.Origin.Y + (floor - 1) * MIN_WALL_HEIGHT
end

-- An invisible plot-sized plane kept at the active build level - a placeholder for a future
-- visible build grid. Not raycast against (the cursor uses real surfaces below).
local buildPlane = Instance.new("Part")
buildPlane.Name = "BuildGridPlane"
buildPlane.Anchored = true
buildPlane.CanCollide = false
buildPlane.CanQuery = false
buildPlane.Transparency = 1
buildPlane.Size = Vector3.new(1, 0.05, 1)

local function positionBuildPlane(grid: Grid.Grid, planeY: number)
	local cell = Building.CELL_SIZE
	buildPlane.Size = Vector3.new(grid.Width * cell, 0.05, grid.Depth * cell)
	buildPlane.CFrame = CFrame.new(grid.Origin.X + grid.Width * cell / 2, planeY, grid.Origin.Z + grid.Depth * cell / 2)
	buildPlane.Parent = Workspace
end

local function hideBuildPlane()
	buildPlane.Parent = nil
end

-- Build surfaces the cursor can land on to choose a cell + level: the plot base (floor 1),
-- ceiling tops (the floor above them), and painted floor tiles. Walls/content are excluded
-- so the ray passes through them to the floor surface behind.
local function surfaceRaycast(base: BasePart): RaycastResult?
	local includes: { Instance } = { base }
	local plot = base.Parent
	if plot then
		for _, name in { "Ceilings", "Floor" } do
			local folder = plot:FindFirstChild(name)
			if folder then
				table.insert(includes, folder)
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = includes
	local ray = player:GetMouse().UnitRay
	return Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
end

--[[The build floor you're standing on for a surface: the plot base (or a floor-1 tile) is
floor 1; a ceiling top is the floor above it; a floor-N tile is floor N.]]
local function floorFromSurface(instance: Instance): number
	if instance.Parent and instance.Parent.Name == "Ceilings" then
		local ceilingFloor = instance:GetAttribute("Floor")
		return (if typeof(ceilingFloor) == "number" then ceilingFloor else 1) + 1
	end
	local floorLevel = instance:GetAttribute("FloorLevel")
	if typeof(floorLevel) == "number" then
		return floorLevel
	end
	return 1
end

--[[Given a cell's ceiling support options, picks the one the mouse is aiming at: the
candidate whose ceiling-top (at the cell centre, that height) projects nearest the mouse on
screen. So aiming higher picks a taller wall, lower a shorter one. Hysteresis keeps the
current choice unless another candidate is clearly nearer, to stop flip-flopping. Updates
activeCeilingOffset and returns it (nil if unsupported).]]
local function chooseCeilingOffset(grid: Grid.Grid, x: number, z: number): number?
	local candidates = SharedBuildingService:GetCeilingSupportOffsets(grid, x, z, currentFloor)
	if #candidates == 0 then
		activeCeilingOffset = nil
		return nil
	end
	if #candidates == 1 then
		activeCeilingOffset = candidates[1]
		return candidates[1]
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return activeCeilingOffset or candidates[#candidates]
	end
	local centre = grid:GetCellCenter(x, z)
	local mousePos = Vector2.new(player:GetMouse().X, player:GetMouse().Y)

	local nearest, nearestDist, activeDist
	local activeIsCandidate = false
	for _, offset in candidates do
		local screen = camera:WorldToViewportPoint(Vector3.new(centre.X, grid.Origin.Y + offset, centre.Z))
		local dist = (Vector2.new(screen.X, screen.Y) - mousePos).Magnitude
		if not nearestDist or dist < nearestDist then
			nearest, nearestDist = offset, dist
		end
		if offset == activeCeilingOffset then
			activeDist, activeIsCandidate = dist, true
		end
	end

	-- Keep the current choice unless another beats it by the margin.
	if activeIsCandidate and activeDist <= nearestDist + CEILING_SWITCH_MARGIN then
		return activeCeilingOffset
	end
	activeCeilingOffset = nearest
	return nearest
end

--[[Resolves the (clamped) cell under the cursor from the real surface it points at, and
auto-detects the build floor from that surface (setting currentFloor). Ground/no-hit stays
floor 1; a ceiling top bumps to the floor above. Since we land on a real surface, there's no
parallax.]]
local function clampedCellUnderCursor(grid: Grid.Grid, base: BasePart): (number, number)
	local result = surfaceRaycast(base)
	local point
	if result then
		currentFloor = math.clamp(floorFromSurface(result.Instance), 1, Building.FLOOR_COUNT)
		point = result.Position
	else
		point = player:GetMouse().Hit.Position
	end

	-- Keep the (invisible) build-grid placeholder on the active level.
	positionBuildPlane(grid, floorBaseY(grid, currentFloor))
	if FloorButton then
		FloorButton.Text = `Floor: {currentFloor}`
	end

	local x, z = grid:WorldToCell(point)
	return math.clamp(x, 0, grid.Width - 1), math.clamp(z, 0, grid.Depth - 1)
end

local function refreshStatus(extra: string?)
	if not statusLabel then
		return
	end
	local mode
	if deleteMode then
		mode = "DELETE"
	elseif paintMode then
		mode = `Paint: {Materials.Floor[paintMaterial]}`
	elseif ceilingMode then
		mode = `Ceiling: {Materials.Ceiling[ceilingMaterial]}`
	else
		mode = `Place: {selectedAsset or "none"}`
	end
	local displayedHeight = heightForSelection() or currentHeight
	if HeightButton then
		HeightButton.Text = `Height: {displayedHeight}`
	end
	if FloorButton then
		FloorButton.Text = `Floor: {currentFloor}`
	end
	statusLabel.Text = `{mode} | floor {currentFloor} | rot {currentRotation * 90}° | h{displayedHeight}{if extra then " | " .. extra else ""}`
end

--[[Height level to send for the selected asset: the chosen level for extendables,
nil otherwise.]]
heightForSelection = function(): number?
	local entry = selectedAsset and SharedBuildingService:GetEntry(selectedAsset)
	return if entry and entry.Extendable then currentHeight else nil
end

--[[Rebuilds the preview ghost from the current selection/height. Destroys any old one.
The ghost is a non-collidable, non-queryable, semi-transparent clone so it doesn't block
the placement raycast.]]
local function rebuildPreview()
	if previewModel then
		previewModel:Destroy()
		previewModel = nil
		previewSize = nil
	end

	if deleteMode or paintMode or ceilingMode or not selectedAsset then
		return
	end

	local model = SharedBuildingService:GetModel(selectedAsset, heightForSelection())
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
	local _, size = ghost:GetBoundingBox()
	ghost.Parent = Workspace
	previewModel = ghost
	previewSize = size
end

--[[Positions an invisible hitbox over each footprint piece (sized to the model) and shows
its red outline only when that piece is out of bounds or its occupancy key is already
taken in the mirror grid - the exact same check that blocks placement server-side.]]
local function updateIndicators(grid: Grid.Grid, x: number, z: number, previewFloorOffset: number)
	local pieces = SharedBuildingService:GetHitboxPieces(
		grid,
		selectedAsset,
		x,
		z,
		currentFloor,
		currentRotation,
		heightForSelection(),
		previewFloorOffset
	)
	local floorOffset = SharedBuildingService:GetFloorOffset(grid, selectedAsset, x, z, currentFloor, currentRotation)

	for i, piece in pieces do
		local indicator = getIndicator(i)
		indicator.Size = piece.Size
		indicator.CFrame = piece.CFrame

		local colliding = floorOffset == nil or not piece.InBounds or grid:IsOccupied(piece.Key)

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
	if not (base and player:GetMouse().Target) then
		hideTilePreview()
		hideBuildPlane()
		return
	end

	local grid = buildMirrorGrid(base)
	local x, z = clampedCellUnderCursor(grid, base)
	local centre = grid:GetCellCenter(x, z)

	if paintMode then
		local topOffset = 0
		local valid = true
		if currentFloor == 2 then
			local ceiling = grid:GetCeiling(x, z, 1)
			valid = ceiling ~= nil
			topOffset = if ceiling then ceiling.TopOffset else (lastPreviewFloorOffsets[2] or MIN_WALL_HEIGHT)
		end
		setTilePreview(
			CFrame.new(centre.X, grid.Origin.Y + topOffset + 0.05, centre.Z),
			Vector3.new(Building.CELL_SIZE, 0.1, Building.CELL_SIZE),
			valid,
			false
		)
		return
	end

	-- Preview at the height the mouse is choosing (matches what a click will place).
	local topOffset = chooseCeilingOffset(grid, x, z)
	local valid = topOffset ~= nil and grid:GetCeiling(x, z, currentFloor) == nil
	if topOffset then
		lastCeilingTopOffsets[currentFloor] = topOffset
	else
		local floorBelow = currentFloor == 2 and grid:GetCeiling(x, z, 1)
		local minimumBaseOffset = if floorBelow then floorBelow.TopOffset else (currentFloor - 1) * MIN_WALL_HEIGHT
		local borderingFloorOneTop = currentFloor == 2 and SharedBuildingService:GetCeilingTopOffset(grid, x, z, 1)
		-- Rough guess for the invalid (unsupported) hover preview only; the ceiling top
		-- sits at the wall top (no extra thickness added).
		topOffset = borderingFloorOneTop
			or lastCeilingTopOffsets[currentFloor]
			or (minimumBaseOffset + Building.HEIGHT_STUDS[currentHeight])
	end
	setTilePreview(
		CFrame.new(centre.X, grid.Origin.Y + topOffset - Building.CEILING_THICKNESS / 2, centre.Z),
		Vector3.new(Building.CELL_SIZE, Building.CEILING_THICKNESS, Building.CELL_SIZE),
		valid,
		true
	)
end

--[[Snaps the preview ghost + validity indicators to the (clamped) cell under the cursor
each frame, or parks them out of sight when the cursor isn't over the world.]]
local function updatePreview()
	if paintMode or ceilingMode then
		hideIndicators()
		updateTilePreview()
		return
	end
	hideTilePreview()

	if not previewModel or not previewSize or not selectedAsset then
		hideIndicators()
		hideBuildPlane()
		return
	end

	local base = getMyPlotBase()
	if base and player:GetMouse().Target then
		local grid = buildMirrorGrid(base)
		local x, z = clampedCellUnderCursor(grid, base)
		local groundCF = SharedBuildingService:GetPlacementCFrame(grid, selectedAsset, x, z, currentRotation)
		if groundCF then
			local floorOffset = SharedBuildingService:GetFloorOffset(grid, selectedAsset, x, z, currentFloor, currentRotation)
			if floorOffset then
				lastPreviewFloorOffsets[currentFloor] = floorOffset
			end
			local previewFloorOffset = floorOffset or lastPreviewFloorOffsets[currentFloor] or MIN_WALL_HEIGHT
			previewModel:PivotTo(groundCF + Vector3.new(0, previewFloorOffset + previewSize.Y / 2, 0))
			updateIndicators(grid, x, z, previewFloorOffset)
			return
		end
	end
	-- No valid target: park the ghost far below the map and hide indicators.
	previewModel:PivotTo(CFrame.new(0, -1000, 0))
	hideIndicators()
	hideBuildPlane()
end

local function onClick()
	-- Delete mode prioritises rendered placements/ceilings under the cursor. Clicking a
	-- floor-2 surface removes its supporting floor-1 ceiling; floor 1 paint reverts.
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
		-- Delete targets the physical thing under the cursor, so use the raw mouse hit, and
		-- read the level from the surface itself (not the auto floor, which lags in delete mode).
		local grid = Grid.new(base)
		local rawX, rawZ = grid:WorldToCell(player:GetMouse().Hit.Position)
		local x, z = math.clamp(rawX, 0, grid.Width - 1), math.clamp(rawZ, 0, grid.Depth - 1)
		if floorFromSurface(target) >= 2 then
			local ok = ClientBuildingService:RequestRemoveCeiling(x, z, 1)
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
	if not player:GetMouse().Target then
		return
	end

	-- Mirror grid so the cell (and ceiling height choice) match the preview's occupancy.
	local grid = buildMirrorGrid(base)
	local x, z = clampedCellUnderCursor(grid, base)

	if paintMode then
		local ok, reason = ClientBuildingService:RequestPaint(x, z, currentFloor, paintMaterial)
		refreshStatus(if ok then `painted ({x},{z})` else `rejected: {reason}`)
	elseif ceilingMode then
		local desired = chooseCeilingOffset(grid, x, z)
		local ok, reason = ClientBuildingService:RequestPlaceCeiling(x, z, currentFloor, ceilingMaterial, desired)
		refreshStatus(if ok then `ceiling ({x},{z})` else `rejected: {reason}`)
	else
		local id, reason = ClientBuildingService:RequestPlace(selectedAsset, x, z, currentFloor, currentRotation, heightForSelection())
		refreshStatus(if id then `placed ({x},{z})` else `rejected: {reason}`)
	end
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
	tools.Size = UDim2.new(1, -8, 0, 52)
	tools.Position = UDim2.fromOffset(4, 46)
	tools.BackgroundTransparency = 1
	tools.Parent = panel

	local toolLayout = Instance.new("UIGridLayout")
	toolLayout.CellPadding = UDim2.fromOffset(2, 2)
	toolLayout.CellSize = UDim2.new(0.5, -1, 0, 24)
	toolLayout.Parent = tools

	local tabs = Instance.new("Frame")
	tabs.Size = UDim2.new(1, -8, 0, 26)
	tabs.Position = UDim2.fromOffset(4, 102)
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
		page.Size = UDim2.new(1, -8, 1, -136)
		page.Position = UDim2.fromOffset(4, 132)
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
		currentRotation = (currentRotation + 1) % 4
		refreshStatus()
	end)
	HeightButton = addButton(tools, `Height: {currentHeight}`, function()
		currentHeight = (currentHeight % Building.MAX_HEIGHT_LEVEL) + 1
		rebuildPreview()
		refreshStatus()
	end)
	-- Floor is auto-detected from the surface under the cursor; this button is just a readout.
	FloorButton = addButton(tools, `Floor: {currentFloor}`, function() end)
	addButton(tools, "Delete", function()
		local wasDelete = deleteMode
		clearModes()
		deleteMode = not wasDelete
		rebuildPreview()
		refreshStatus()
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
	if input.KeyCode == Enum.KeyCode.R then
		currentRotation = (currentRotation + 1) % 4
		refreshStatus()
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		onClick()
	end
end)

return ClientBuildingService
