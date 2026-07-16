--[[
BuildCamera - client-only orbit camera used by the temporary building UI. The camera
orbits a plot-clamped focal point rather than flying freely. Its focal height determines
the active configured build level and locally hides later levels.
]]

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Building = require(ReplicatedStorage.Config.Building)
local Grid = require(ReplicatedStorage.Classes.Grid)

local CAMERA_INPUT_ACTION = "BuildCameraMovement"
local INPUT_PRIORITY = Enum.ContextActionPriority.High.Value + 100

type PartState = {
	Transparency: number,
	CanQuery: boolean,
}

local BuildCamera = {}
BuildCamera.__index = BuildCamera

function BuildCamera.new()
	local config = Building.Camera
	local self = setmetatable({}, BuildCamera)
	self._enabled = false
	self._rotating = false
	self._plotBase = nil
	self._plotConnection = nil
	self._focalPoint = Vector3.zero
	self._level = 1
	self._yaw = math.rad(config.DefaultYaw)
	self._pitch = math.rad(config.DefaultPitch)
	self._distance = config.DefaultDistance
	self._ceilingSelected = false
	self._visibilityDirty = false
	self._partStates = {}

	self._inputBegan = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if self._enabled and not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton2 then
			self._rotating = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end)
	self._inputEnded = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self._rotating = false
			if self._enabled then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
		end
	end)
	self._inputChanged = UserInputService.InputChanged:Connect(function(input, gameProcessed)
		if not self._enabled or gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement and self._rotating then
			self._yaw += input.Delta.X * config.RotateSensitivity
			self._pitch = math.clamp(
				self._pitch + input.Delta.Y * config.RotateSensitivity,
				math.rad(config.MinPitch),
				math.rad(config.MaxPitch)
			)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel then
			self._distance = math.clamp(
				self._distance - input.Position.Z * config.ZoomStep,
				config.MinDistance,
				config.MaxDistance
			)
		end
	end)
	self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if self._enabled then
			self:_Update(deltaTime)
		end
	end)
	return self
end

local function sinkInput(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

function BuildCamera:_BindMovement()
	ContextActionService:BindActionAtPriority(
		CAMERA_INPUT_ACTION,
		sinkInput,
		false,
		INPUT_PRIORITY,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Q,
		Enum.KeyCode.E
	)
end

function BuildCamera:_SetPartVisible(part: BasePart, visible: boolean)
	local state = self._partStates[part]
	if not state then
		state = {
			Transparency = part.LocalTransparencyModifier,
			CanQuery = part.CanQuery,
		}
		self._partStates[part] = state
	end
	part.LocalTransparencyModifier = if visible then state.Transparency else 1
	part.CanQuery = if visible then state.CanQuery else false
end

function BuildCamera:_SetTreeVisible(instance: Instance, visible: boolean)
	if instance:IsA("BasePart") then
		self:_SetPartVisible(instance, visible)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			self:_SetPartVisible(descendant, visible)
		end
	end
end

function BuildCamera:_ApplyVisibility()
	local plot = self._plotBase and self._plotBase.Parent
	if not plot then
		return
	end

	local built = plot:FindFirstChild("Built")
	if built then
		for _, placement in built:GetChildren() do
			local floor = placement:GetAttribute("Floor")
			self:_SetTreeVisible(placement, typeof(floor) ~= "number" or floor <= self._level)
		end
	end

	local ceilings = plot:FindFirstChild("Ceilings")
	if ceilings then
		for _, ceiling in ceilings:GetChildren() do
			local floor = ceiling:GetAttribute("Floor")
			local visible = typeof(floor) ~= "number"
				or floor < self._level
				or (self._ceilingSelected and floor == self._level)
			self:_SetTreeVisible(ceiling, visible)
		end
	end

	local floors = plot:FindFirstChild("Floor")
	if floors then
		for _, floorPart in floors:GetChildren() do
			local floor = floorPart:GetAttribute("FloorLevel")
			self:_SetTreeVisible(floorPart, typeof(floor) ~= "number" or floor <= self._level)
		end
	end
	self._visibilityDirty = false
end

function BuildCamera:_RestoreVisibility()
	for part, state in self._partStates do
		if part.Parent then
			part.LocalTransparencyModifier = state.Transparency
			part.CanQuery = state.CanQuery
		end
	end
	table.clear(self._partStates)
end

function BuildCamera:_Update(deltaTime: number)
	local config = Building.Camera
	local forward = Vector3.new(-math.cos(self._yaw), 0, -math.sin(self._yaw))
	local right = Vector3.new(math.sin(self._yaw), 0, -math.cos(self._yaw))
	local movement = Vector3.zero

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then movement += forward end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then movement -= forward end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then movement += right end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then movement -= right end
	if movement.Magnitude > 1 then movement = movement.Unit end

	local vertical = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then vertical += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then vertical -= 1 end
	local nextPoint = self._focalPoint
		+ movement * config.PanSpeed * deltaTime
		+ Vector3.new(0, vertical * config.VerticalSpeed * deltaTime, 0)
	self._focalPoint = Vector3.new(
		math.clamp(nextPoint.X, self._origin.X, self._maxX),
		math.max(self._origin.Y, nextPoint.Y),
		math.clamp(nextPoint.Z, self._origin.Z, self._maxZ)
	)

	local level = math.floor((self._focalPoint.Y - self._origin.Y) / Building.WALL_HEIGHT) + 1
	if level ~= self._level then
		self._level = level
		self._visibilityDirty = true
	end

	local horizontal = math.cos(self._pitch)
	local offset = Vector3.new(
		horizontal * math.cos(self._yaw),
		math.sin(self._pitch),
		horizontal * math.sin(self._yaw)
	) * self._distance
	local camera = Workspace.CurrentCamera
	camera.CFrame = CFrame.lookAt(self._focalPoint + offset, self._focalPoint)
	camera.Focus = CFrame.new(self._focalPoint)

	if self._visibilityDirty then
		self:_ApplyVisibility()
	end
end

function BuildCamera:SetEnabled(enabled: boolean, plotBase: BasePart?, level: number?)
	if enabled == self._enabled then
		if enabled and level then
			self:SetLevel(level)
		end
		return
	end

	if enabled then
		if not plotBase then
			return
		end
		self._enabled = true
		self._plotBase = plotBase
		local grid = Grid.new(plotBase)
		self._origin = grid.Origin
		self._maxX = grid.Origin.X + grid.Width * Building.CELL_SIZE
		self._maxZ = grid.Origin.Z + grid.Depth * Building.CELL_SIZE
		self._focalPoint = Vector3.new(
			grid.Origin.X + grid.Width * Building.CELL_SIZE / 2,
			grid.Origin.Y + ((level or 1) - 1) * Building.WALL_HEIGHT,
			grid.Origin.Z + grid.Depth * Building.CELL_SIZE / 2
		)
		self._level = level or 1
		local camera = Workspace.CurrentCamera
		self._savedCameraType = camera.CameraType
		self._savedCameraSubject = camera.CameraSubject
		self._savedFieldOfView = camera.FieldOfView
		self._savedCameraCFrame = camera.CFrame
		self._savedCameraFocus = camera.Focus
		self._savedMouseBehavior = UserInputService.MouseBehavior
		camera.CameraType = Enum.CameraType.Scriptable
		self:_BindMovement()
		self._plotConnection = plotBase.Parent.DescendantAdded:Connect(function()
			self._visibilityDirty = true
		end)
		self._visibilityDirty = true
		return
	end

	self._enabled = false
	self._rotating = false
	ContextActionService:UnbindAction(CAMERA_INPUT_ACTION)
	if self._plotConnection then
		self._plotConnection:Disconnect()
		self._plotConnection = nil
	end
	self:_RestoreVisibility()
	local camera = Workspace.CurrentCamera
	camera.CFrame = self._savedCameraCFrame
	camera.Focus = self._savedCameraFocus
	camera.CameraSubject = self._savedCameraSubject
	camera.FieldOfView = self._savedFieldOfView
	camera.CameraType = self._savedCameraType
	UserInputService.MouseBehavior = self._savedMouseBehavior or Enum.MouseBehavior.Default
	self._plotBase = nil
end

function BuildCamera:SetLevel(level: number)
	if not self._plotBase then
		return
	end
	self._level = math.max(1, level)
	self._focalPoint = Vector3.new(
		self._focalPoint.X,
		self._origin.Y + (self._level - 1) * Building.WALL_HEIGHT,
		self._focalPoint.Z
	)
	self._visibilityDirty = true
end

function BuildCamera:GetLevel(): number
	return self._level
end

function BuildCamera:IsEnabled(): boolean
	return self._enabled
end

function BuildCamera:SetCeilingSelected(selected: boolean)
	if self._ceilingSelected ~= selected then
		self._ceilingSelected = selected
		self._visibilityDirty = true
	end
end

function BuildCamera:Destroy()
	self:SetEnabled(false)
	self._inputBegan:Disconnect()
	self._inputEnded:Disconnect()
	self._inputChanged:Disconnect()
	self._renderConnection:Disconnect()
end

return BuildCamera
