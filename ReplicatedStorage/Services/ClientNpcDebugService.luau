--[[
TEMPORARY DEBUG UI for guests. Wires the Studio-authored StarterGui.NpcDebug panel:
a popularity slider, live counts for the plot you're standing nearest, force-spawn and
clear buttons, and a path overlay drawn from the legs the client is already walking.

Popularity is a dev override for now. Once aquarium appeal computes it for real, this
service and the panel both go away - nothing else depends on them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ClientNpcDebugService = {}
if not RunService:IsClient() then
	return ClientNpcDebugService
end

local ClientNpcService = require(ReplicatedStorage.Services.ClientNpcService)

local Player = Players.LocalPlayer
local debugRemote = ReplicatedStorage:WaitForChild("Communication"):WaitForChild("Npc"):WaitForChild("Debug") :: RemoteFunction

local REFRESH_INTERVAL = 0.25
local SEND_INTERVAL = 0.15
local PATH_COLOR = Color3.fromRGB(120, 220, 255)

local Popularity = 50
local PathsVisible = false
local PathFolder: Folder? = nil

local panel = Player:WaitForChild("PlayerGui"):WaitForChild("NpcDebug"):WaitForChild("Panel")
local slider = panel.Slider
local fill = slider.Fill
local handle = slider.Handle

-- ===== Popularity slider ====================================================

local function paintSlider()
	local alpha = Popularity / 100
	fill.Size = UDim2.new(alpha, 0, 1, 0)
	handle.Position = UDim2.new(alpha, 0, 0.5, 0)
	panel.PopularityLabel.Text = `Popularity  {math.floor(Popularity + 0.5)}`
end

--[[Pushes the slider value to the server, at most one request in flight at a time.]]
local sending = false
local pending: number? = nil
local function push()
	if sending then
		pending = Popularity
		return
	end
	sending = true
	task.spawn(function()
		local value = Popularity
		repeat
			debugRemote:InvokeServer("Popularity", value)
			task.wait(SEND_INTERVAL)
			value = pending
			pending = nil
		until value == nil
		sending = false
	end)
end

local function setFromInput(x: number)
	Popularity = math.clamp((x - slider.AbsolutePosition.X) / slider.AbsoluteSize.X, 0, 1) * 100
	paintSlider()
	push()
end

local dragging = false
local function beginDrag(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		setFromInput(input.Position.X)
	end
end

handle.InputBegan:Connect(beginDrag)
slider.InputBegan:Connect(beginDrag)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		setFromInput(input.Position.X)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

-- The server owns each plot's popularity, so switching plots adopts that plot's value
-- rather than pushing this panel's onto it.
local synced = false
ClientNpcService.WatchedPlotChanged:Connect(function(_plotNumber: number, popularity: number?)
	Popularity = popularity or Popularity
	synced = true
	paintSlider()
end)

-- ===== Buttons ==============================================================

panel.Spawn.Activated:Connect(function()
	task.spawn(debugRemote.InvokeServer, debugRemote, "Spawn")
end)

panel.Clear.Activated:Connect(function()
	task.spawn(debugRemote.InvokeServer, debugRemote, "Clear")
end)

panel.Paths.Activated:Connect(function()
	PathsVisible = not PathsVisible
	panel.Paths.Text = `Paths: {if PathsVisible then "On" else "Off"}`
	if not PathsVisible and PathFolder then
		PathFolder:Destroy()
		PathFolder = nil
	end
end)

-- ===== Path overlay =========================================================

--[[Redraws every walked polyline as a thin neon line, so pathing and floor weighting are
visible at a glance.]]
local function drawPaths()
	if PathFolder then
		PathFolder:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "GuestPathDebug"
	folder.Parent = Workspace
	PathFolder = folder

	for _, points in ClientNpcService:GetActiveLegs() do
		for i = 2, #points do
			local from, to = points[i - 1], points[i]
			local segment = to - from
			if segment.Magnitude < 1e-3 then
				continue
			end
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Material = Enum.Material.Neon
			part.Color = PATH_COLOR
			part.Transparency = 0.4
			part.Size = Vector3.new(0.15, 0.15, segment.Magnitude)
			part.CFrame = CFrame.lookAt(from:Lerp(to, 0.5) + Vector3.new(0, 0.2, 0), to + Vector3.new(0, 0.2, 0))
			part.Parent = folder
		end
	end
end

-- ===== Refresh loop =========================================================

task.spawn(function()
	while true do
		local guests, groups = ClientNpcService:GetCounts()
		panel.Watching.Text = `Watching plot {ClientNpcService:GetWatchedPlot() or "-"}`
		panel.Stats.Text = `{guests} guests / {groups} groups`
		if PathsVisible then
			drawPaths()
		end
		-- The first subscription can land before this panel is listening, so adopt the
		-- watched plot's real value once rather than showing a stale default.
		if not synced and not dragging and ClientNpcService:GetWatchedPlot() then
			local state = debugRemote:InvokeServer("Query")
			if state then
				Popularity = state.Popularity
				synced = true
				paintSlider()
			end
		end
		task.wait(REFRESH_INTERVAL)
	end
end)

paintSlider()

return ClientNpcDebugService
