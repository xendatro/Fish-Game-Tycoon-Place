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

--[[Requests placing a ceiling at a cell (auto-snaps to the highest bordering support).]]
function ClientBuildingService:RequestPlaceCeiling(x: number, z: number, materialIndex: number): (boolean, string?)
	return ceilingRemote:InvokeServer("place", x, z, materialIndex)
end

--[[Requests removing the ceiling (and its floor-2 tile) at a cell.]]
function ClientBuildingService:RequestRemoveCeiling(x: number, z: number): boolean
	return ceilingRemote:InvokeServer("remove", x, z)
end

-- ===========================================================================
-- TEMPORARY DEBUG UI
-- A throwaway ScreenGui to exercise building before the real UI exists: a button
-- per catalog entry, a rotate button (or press R), and a delete toggle. Click the
-- plot to place/remove at the cell under the cursor. Replace with the real system.
-- TODO(real system): ghost/preview + CanPlace tint, height selection, free camera.
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

--[[Clears every non-place mode. Callers then set the one they want.]]
local function clearModes()
	deleteMode = false
	paintMode = false
	ceilingMode = false
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

local function hideDeleteHighlight()
	deleteHighlight.Adornee = nil
	deleteHighlight.Visible = false
end

--[[Outlines the placement under the cursor (in delete mode) so it's clear what a click
would remove.]]
local function updateDeleteHighlight()
	hideIndicators()
	local model = findPlacementModel(player:GetMouse().Target)
	deleteHighlight.Adornee = model
	deleteHighlight.Visible = model ~= nil
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
	local built = base.Parent and base.Parent:FindFirstChild("Built")
	if not built then
		return grid
	end

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
	return grid
end

--[[Returns the grid cell under the cursor, clamped to the plot so the ghost can't be
dragged off the plot.]]
local function clampedCellUnderCursor(grid: Grid.Grid): (number, number)
	local x, z = grid:WorldToCell(player:GetMouse().Hit.Position)
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
	statusLabel.Text = `{mode} | floor {currentFloor} | rot {currentRotation * 90}° | h{currentHeight}{if extra then " | " .. extra else ""}`
end

--[[Height level to send for the selected asset: the chosen level for extendables,
nil otherwise.]]
local function heightForSelection(): number?
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
local function updateIndicators(grid: Grid.Grid, x: number, z: number)
	local pieces = SharedBuildingService:GetHitboxPieces(grid, selectedAsset, x, z, 1, currentRotation, heightForSelection())

	for i, piece in pieces do
		local indicator = getIndicator(i)
		indicator.Size = piece.Size
		indicator.CFrame = piece.CFrame

		local colliding = not piece.InBounds or grid:IsOccupied(piece.Key)

		local outline = indicator:FindFirstChild("Outline") :: SelectionBox
		outline.Visible = colliding
		indicator.Parent = indicatorFolder
	end

	-- Hide any pooled indicators beyond this footprint's size.
	for i = #pieces + 1, #indicators do
		indicators[i].Parent = nil
	end
end

--[[Snaps the preview ghost + validity indicators to the (clamped) cell under the cursor
each frame, or parks them out of sight when the cursor isn't over the world.]]
local function updatePreview()
	if not previewModel or not previewSize or not selectedAsset then
		hideIndicators()
		return
	end

	local base = getMyPlotBase()
	if base and player:GetMouse().Target then
		local grid = buildMirrorGrid(base)
		local x, z = clampedCellUnderCursor(grid)
		local groundCF = SharedBuildingService:GetPlacementCFrame(grid, selectedAsset, x, z, currentRotation)
		if groundCF then
			previewModel:PivotTo(groundCF + Vector3.new(0, previewSize.Y / 2, 0))
			updateIndicators(grid, x, z)
			return
		end
	end
	-- No valid target: park the ghost far below the map and hide indicators.
	previewModel:PivotTo(CFrame.new(0, -1000, 0))
	hideIndicators()
end

local function onClick()
	-- Delete mode: remove the placement under the cursor by id; otherwise on floor 2 remove
	-- the whole ceiling+floor unit, and on floor 1 revert the cell's floor to grass (a base
	-- floor cell can't actually be deleted).
	if deleteMode then
		local model = findPlacementModel(player:GetMouse().Target)
		if model then
			local ok = ClientBuildingService:RequestRemove(model:GetAttribute("PlacementId") :: number)
			refreshStatus(if ok then "removed" else "remove failed")
			return
		end

		local base = getMyPlotBase()
		if not (base and player:GetMouse().Target) then
			refreshStatus("nothing to delete")
			return
		end
		local grid = Grid.new(base)
		local x, z = clampedCellUnderCursor(grid)
		if currentFloor == 2 then
			local ok = ClientBuildingService:RequestRemoveCeiling(x, z)
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

	-- Clamp to the plot so placement/paint matches the clamped ghost.
	local grid = Grid.new(base)
	local x, z = clampedCellUnderCursor(grid)

	if paintMode then
		local ok, reason = ClientBuildingService:RequestPaint(x, z, currentFloor, paintMaterial)
		refreshStatus(if ok then `painted ({x},{z})` else `rejected: {reason}`)
	elseif ceilingMode then
		local ok, reason = ClientBuildingService:RequestPlaceCeiling(x, z, ceilingMaterial)
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

	local panel = Instance.new("ScrollingFrame")
	panel.Size = UDim2.fromOffset(182, 500)
	panel.Position = UDim2.fromOffset(12, 12)
	panel.BackgroundColor3 = Color3.new(0, 0, 0)
	panel.BackgroundTransparency = 0.35
	panel.BorderSizePixel = 0
	panel.ScrollBarThickness = 6
	panel.CanvasSize = UDim2.new()
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.Parent = panel

	statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, 0, 0, 34)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.new(1, 1, 1)
	statusLabel.TextWrapped = true
	statusLabel.Parent = panel

	local function addButton(text: string, onActivate: () -> ()): TextButton
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 24)
		button.Text = text
		button.Parent = panel
		button.Activated:Connect(onActivate)
		return button
	end

	local function addHeader(text: string)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 20)
		label.BackgroundTransparency = 1
		label.Text = `— {text} —`
		label.TextColor3 = Color3.fromRGB(170, 210, 255)
		label.Parent = panel
	end

	-- Tools
	addHeader("Tools")
	addButton("Rotate", function()
		currentRotation = (currentRotation + 1) % 4
		refreshStatus()
	end)
	addButton("Height +1", function()
		currentHeight = (currentHeight % Building.MAX_HEIGHT_LEVEL) + 1
		rebuildPreview()
		refreshStatus()
	end)
	addButton("Floor: toggle", function()
		currentFloor = (currentFloor % Building.FLOOR_COUNT) + 1
		refreshStatus()
	end)
	addButton("Delete: toggle", function()
		local wasDelete = deleteMode
		clearModes()
		deleteMode = not wasDelete
		rebuildPreview()
		refreshStatus()
	end)

	-- Catalog assets, grouped by Type.
	local byType: { [string]: { string } } = {}
	for name, entry in SharedBuildingService:GetCatalog() do
		byType[entry.Type] = byType[entry.Type] or {}
		table.insert(byType[entry.Type], name)
	end
	local function addAssetSection(typeName: string, header: string)
		local names = byType[typeName]
		if not names or #names == 0 then
			return
		end
		table.sort(names)
		addHeader(header)
		for _, name in names do
			addButton(name, function()
				clearModes()
				selectedAsset = name
				rebuildPreview()
				refreshStatus()
			end)
		end
	end
	addAssetSection("Content", "Content")
	addAssetSection("Wall", "Walls")

	-- Ceilings: selecting one enters ceiling mode with that underside material.
	addHeader("Ceilings")
	for index, material in Materials.Ceiling do
		addButton(material, function()
			clearModes()
			ceilingMode = true
			ceilingMaterial = index
			rebuildPreview()
			refreshStatus()
		end)
	end

	-- Floor paint: selecting one enters paint mode with that floor material.
	addHeader("Floor Paint")
	for index, material in Materials.Floor do
		addButton(material, function()
			clearModes()
			paintMode = true
			paintMaterial = index
			rebuildPreview()
			refreshStatus()
		end)
	end

	refreshStatus()
end

buildDebugUI()

RunService.RenderStepped:Connect(function()
	if deleteMode then
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
