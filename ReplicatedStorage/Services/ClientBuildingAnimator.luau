--[[
ClientBuildingAnimator - the "juice" layer for building. It has no authority and touches
no data; it only makes placements *feel* good on the local client.

Three jobs:
  1. Watches the local player's plot for newly-rendered placements (which arrive via normal
     Roblox replication once the server commits them) and pops each one in - a scale
     overshoot, a short drop, a dust puff, and a brief confirm flash.
  2. FloorStamp: the delete/paint tools call it to stamp painted floor cells in with an
     expanding splash + dust (floors greedy-remesh in bulk, so we can't animate the tiles
     themselves without the whole level churning - a decoupled effect reads far better).
  3. Exposes PoofModel/CloneForPoof/PoofClone so the delete tool can shrink an object out
     with a matching dust burst instead of having it blink out of existence.

Everything here is presentation-only and local: only you see your own pop-ins and poofs,
which is exactly what a build system wants (instant, personal feedback on your own action).

Telling an interactive placement from a bulk load is done authoritatively, not guessed: the
server stamps a `BulkRendered` attribute on anything it renders as part of loading or
resetting a base, and we simply never animate those. Everything else - a click, a drag of
any length, an undo - animates. To hide an object during its pre-pop wait we move it out of
the rendered world entirely (into a Lighting staging folder) rather than just shrinking it,
so it's genuinely invisible and stays intact even while its parts are still streaming in.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local ClientBuildingAnimator = {}

if not RunService:IsClient() then
	return ClientBuildingAnimator
end

local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local SharedColorService = require(ReplicatedStorage.Services.SharedColorService)

local player = Players.LocalPlayer

-- Server attribute marking a render that was part of a bulk load/reset, not a hand action.
local BULK_ATTRIBUTE = "BulkRendered"

-- Tuning. All timings are in seconds, all distances in studs.
local POP_DURATION = Building.CEILING_ANIMATION_DURATION -- pop-in length
local POP_START_SCALE = 0.04 -- scale the pop grows from (kept out of view while staged anyway)
local POP_DROP_HEIGHT = 1.6 -- how far above its rest the object starts before slamming down
local POP_STAGGER = Building.CEILING_ANIMATION_STAGGER -- per-item drag cascade delay
local POP_CONCURRENT_CAP = 40 -- above this many *live* animations, extra placements just snap in

-- Ceilings and floor tiles compress their cascade as more are placed in one batch, so a big
-- fill wraps up fast instead of dragging on. Walls/content ignore this (fixed cadence).
local CASCADE_REF = Building.ANIMATION_CASCADE_REF -- batches up to this size play at full speed
local CASCADE_MAX_SPEEDUP = Building.ANIMATION_CASCADE_MAX_SPEEDUP -- maximum large-batch speedup

local POOF_DURATION = 0.22 -- delete shrink-out length
local POOF_RISE = 0.9 -- slight upward drift as an object poofs

local STAMP_DURATION = 0.26 -- floor-tile drop-in length
local STAMP_DROP_HEIGHT = 1.2 -- how far above the surface a floor tile starts
local STAMP_STAGGER = 0.03 -- per-cell delay so a paint drag sweeps
local STAMP_THICKNESS = Building.FLOOR_THICKNESS
local STAMP_RENDER_OFFSET = 0.003 -- keeps covers above the real surface without looking raised
local STAMP_MAX = 200 -- paint requests beyond this skip the effect (bulk fill)

local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local DUST_COLOR = Color3.fromRGB(236, 231, 220)
local FLASH_COLOR = Color3.fromRGB(255, 255, 255)
local FLASH_OUTLINE = Color3.fromRGB(150, 220, 255)

local activeCount = 0

-- One shared home for transient effect instances so they never clutter the plot folders.
local effectsFolder = Instance.new("Folder")
effectsFolder.Name = "BuildingEffects"
effectsFolder.Parent = Workspace

-- Non-rendered staging area. Objects wait here (invisible, but still in the DataModel so
-- their parts finish streaming) between replicating in and their pop starting.
local stagingFolder = Instance.new("Folder")
stagingFolder.Name = "BuildingStaging"
stagingFolder.Parent = Lighting

-- ===== Easing ===============================================================
-- Standard penner curves. Back over/undershoots for anticipation; cubic decelerates.
local BACK = 1.70158
local function backOut(t: number): number
	local a = t - 1
	return 1 + (BACK + 1) * a * a * a + BACK * a * a
end
local function backIn(t: number): number
	return (BACK + 1) * t * t * t - BACK * t * t
end
local function cubicOut(t: number): number
	local a = 1 - t
	return 1 - a * a * a
end
local function quadOut(t: number): number
	return 1 - (1 - t) * (1 - t)
end

--[[How much to speed up a ceiling/floor cascade of `count` items: 1x for small batches,
scaling up to CASCADE_MAX_SPEEDUP for large ones so a big fill finishes quickly.]]
local function cascadeFactor(count: number): number
	return math.clamp(count / CASCADE_REF, 1, CASCADE_MAX_SPEEDUP)
end

-- ===== Effects ==============================================================

--[[A quick outward puff of dust at a world position - the "impact" of an object landing
or the debris of one removed.]]
local function spawnDust(position: Vector3, amount: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = DUST_TEXTURE
	emitter.Color = ColorSequence.new(DUST_COLOR)
	emitter.LightEmission = 0.15
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.15, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 2.3),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.55)
	emitter.Speed = NumberRange.new(3.5, 6.5)
	emitter.SpreadAngle = Vector2.new(140, 140)
	emitter.Acceleration = Vector3.new(0, -8, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Drag = 4
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rate = 0
	emitter.Parent = anchor

	anchor.Parent = effectsFolder
	emitter:Emit(amount)
	Debris:AddItem(anchor, 1.2)
end

--[[A short white confirm flash over a just-placed model, fading out.]]
local function spawnFlash(model: Model)
	local highlight = Instance.new("Highlight")
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = FLASH_COLOR
	highlight.FillTransparency = 0.55
	highlight.OutlineColor = FLASH_OUTLINE
	highlight.OutlineTransparency = 0.1
	highlight.Parent = model

	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	)
	tween.Completed:Connect(function()
		highlight:Destroy()
	end)
	tween:Play()
end

--[[An expanding white "splash" square accent - the impact flash when a floor tile lands.]]
local function spawnSplash(position: Vector3, cellSize: number)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = FLASH_COLOR
	part.Transparency = 0.4
	part.Size = Vector3.new(cellSize * 0.3, 0.05, cellSize * 0.3)
	part.CFrame = CFrame.new(position + Vector3.new(0, 0.1, 0))
	part.Parent = effectsFolder

	local tween = TweenService:Create(
		part,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(cellSize * 1.05, 0.05, cellSize * 1.05), Transparency = 1 }
	)
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

type FloorStamp = {
	Position: Vector3,
	PreviousMaterial: Enum.Material,
	PreviousColor: Color3,
}

local function makeFloorTile(
	position: Vector3,
	cellSize: number,
	material: Enum.Material,
	color: Color3
): (Part, CFrame)
	local tile = Instance.new("Part")
	tile.Anchored = true
	tile.CanCollide = false
	tile.CanQuery = false
	tile.CanTouch = false
	tile.CastShadow = false
	tile.Material = material
	tile.Color = color
	tile.Size = Vector3.new(cellSize, STAMP_THICKNESS, cellSize)
	local restCF = CFrame.new(position + Vector3.new(0, STAMP_RENDER_OFFSET, 0))
	return tile, restCF
end

--[[Drops a tile matched to the new floor while an old-look cover hides the server remesh.
The cover disappears only when the falling tile lands, so the new floor never flashes in
under the animation.]]
local function spawnFloorTile(
	stamp: FloorStamp,
	cellSize: number,
	material: Enum.Material,
	color: Color3,
	duration: number,
	cover: Part
)
	local tile, restCF = makeFloorTile(stamp.Position, cellSize, material, color)
	tile.CFrame = restCF * CFrame.new(0, STAMP_DROP_HEIGHT, 0)
	tile.Parent = effectsFolder

	task.spawn(function()
		local started = os.clock()
		while tile.Parent do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - started) / duration
			if t >= 1 then
				break
			end
			tile.CFrame = restCF * CFrame.new(0, STAMP_DROP_HEIGHT * (1 - cubicOut(t)), 0)
		end
		tile.CFrame = restCF
		cover:Destroy()
		spawnDust(stamp.Position, 5)
		spawnSplash(stamp.Position, cellSize)
		task.wait(0.1) -- hold so the real tile is certainly present beneath before we hand off
		local fadeStart = os.clock()
		while tile.Parent do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - fadeStart) / 0.12
			if t >= 1 then
				break
			end
			tile.Transparency = t
		end
		tile:Destroy()
	end)
end

-- ===== Pop-in ===============================================================

-- A child captured the instant it was added, together with the container to return it to.
-- A Model's rest pivot reads reliably straight away (WorldPivot replicates before its parts
-- stream in); a slab is a lone Part with a CFrame. While it waits for its turn we park it in
-- a non-rendered staging folder, so it's genuinely invisible - never a small-but-visible
-- speck - and stays intact even mid-stream. All edits are local; the server never fights us.
type Pending = {
	inst: Instance,
	container: Instance,
	target: CFrame?,
	targetCF: CFrame?,
	transparency: number?,
}

--[[Captures a new child's resting transform and moves it out of the rendered world into the
staging folder. Runs synchronously in ChildAdded, the same frame it first appears.]]
local function stage(inst: Instance, container: Instance): Pending
	local info: Pending = { inst = inst, container = container }
	if inst:IsA("Model") then
		info.target = inst:GetPivot()
	elseif inst:IsA("BasePart") then
		info.targetCF = inst.CFrame
		info.transparency = inst.Transparency
	end
	inst.Parent = stagingFolder
	return info
end

--[[Returns a staged child to its container at its final resting state, no animation. Used
when we're over the concurrency cap.]]
local function revealAtRest(info: Pending)
	local inst = info.inst
	if inst:IsA("Model") and info.target then
		pcall(function()
			inst:PivotTo(info.target :: CFrame)
		end)
	elseif inst:IsA("BasePart") and info.targetCF then
		inst.CFrame = info.targetCF
		inst.Transparency = info.transparency or 0
	end
	inst.Parent = info.container
end

--[[Pops a local display clone while the streamed server model stays staged and unscaled.
At the end the clone hands off to the untouched server model. This prevents late-streamed
parts from inheriting a changed scale and turning giant.]]
local function popInModel(info: Pending, delay: number, duration: number)
	local model = info.inst :: Model
	local target = info.target :: CFrame
	local container = info.container

	task.spawn(function()
		if delay > 0 then
			task.wait(delay)
		end
		if model.Parent ~= stagingFolder then
			return -- removed (or reset) while it waited
		end
		-- Wait for the bounding box to settle so the display clone looks complete. The
		-- authoritative model stays untouched even if more descendants stream in later.
		local prevSize: Vector3? = nil
		local stableFrames = 0
		local deadline = os.clock() + 0.5
		while model.Parent == stagingFolder do
			local _, size = model:GetBoundingBox()
			if prevSize and size.Magnitude > 1e-2 and (size - prevSize).Magnitude < 1e-3 then
				stableFrames += 1
				if stableFrames >= 2 then
					break
				end
			else
				stableFrames = 0
			end
			prevSize = size
			if os.clock() > deadline then
				break
			end
			RunService.Heartbeat:Wait()
		end
		if model.Parent ~= stagingFolder then
			return
		end
		if activeCount >= POP_CONCURRENT_CAP then
			revealAtRest(info)
			return
		end
		local ok, display = pcall(function()
			return model:Clone()
		end)
		if not ok or not display then
			revealAtRest(info)
			return
		end
		activeCount += 1
		pcall(function()
			display:ScaleTo(POP_START_SCALE)
			display:PivotTo(target * CFrame.new(0, POP_DROP_HEIGHT, 0))
		end)
		display.Parent = effectsFolder

		local started = os.clock()
		while display.Parent and model.Parent == stagingFolder do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - started) / duration
			if t >= 1 then
				break
			end
			local scale = POP_START_SCALE + (1 - POP_START_SCALE) * backOut(t)
			local drop = POP_DROP_HEIGHT * (1 - cubicOut(t))
			pcall(function()
				display:ScaleTo(scale)
				display:PivotTo(target * CFrame.new(0, drop, 0))
			end)
		end
		if model.Parent == stagingFolder and container.Parent then
			revealAtRest(info)
			local _, size = model:GetBoundingBox()
			spawnDust(Vector3.new(target.X, target.Y - size.Y / 2, target.Z), 10)
			spawnFlash(model)
		end
		display:Destroy()
		activeCount -= 1
	end)
end

local function ceilingFloorTile(part: BasePart, targetCF: CFrame): (Part?, CFrame?)
	local materialIndex = part:GetAttribute("MaterialIndex")
	if typeof(materialIndex) ~= "number" then
		return nil, nil
	end
	local floorIndex = Materials.Ceiling[materialIndex].FloorMaterial
	local topY = targetCF.Position.Y + part.Size.Y / 2
	local position = Vector3.new(
		targetCF.Position.X,
		topY + Building.FLOOR_SURFACE_OFFSET - Building.FLOOR_THICKNESS / 2,
		targetCF.Position.Z
	)
	local tile, restCF = makeFloorTile(
		position,
		Building.CELL_SIZE,
		(Enum.Material :: any)[Materials.Floor[floorIndex].Material],
		SharedColorService:MaterialColor("Floor", floorIndex, part:GetAttribute("TintColor"))
	)
	return tile, restCF
end

--[[Drops a ceiling slab and its matching upper floor tile as one piece. The temporary
floor face stays until the server publishes the remeshed floor, then fades away.]]
local function popInPart(info: Pending, delay: number, duration: number, hold: number)
	local part = info.inst :: BasePart
	local targetCF = info.targetCF :: CFrame
	local targetTransparency = info.transparency or 0
	local container = info.container

	task.spawn(function()
		if delay > 0 then
			task.wait(delay)
		end
		if part.Parent ~= stagingFolder then
			return
		end
		if activeCount >= POP_CONCURRENT_CAP then
			revealAtRest(info)
			return
		end
		activeCount += 1
		local floorTile, floorTarget = ceilingFloorTile(part, targetCF)
		part.CFrame = targetCF * CFrame.new(0, POP_DROP_HEIGHT, 0)
		part.Transparency = 1
		part.Parent = container
		if floorTile and floorTarget then
			floorTile.CFrame = floorTarget * CFrame.new(0, POP_DROP_HEIGHT, 0)
			floorTile.Transparency = 1
			floorTile.Parent = effectsFolder
		end

		local started = os.clock()
		while part.Parent == container do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - started) / duration
			if t >= 1 then
				break
			end
			local drop = POP_DROP_HEIGHT * (1 - cubicOut(t))
			pcall(function()
				part.CFrame = targetCF * CFrame.new(0, drop, 0)
				part.Transparency = targetTransparency + (1 - targetTransparency) * (1 - t)
				if floorTile and floorTarget then
					floorTile.CFrame = floorTarget * CFrame.new(0, drop, 0)
					floorTile.Transparency = 1 - t
				end
			end)
		end
		if part.Parent == container then
			pcall(function()
				part.CFrame = targetCF
				part.Transparency = targetTransparency
			end)
			if floorTile and floorTarget then
				floorTile.CFrame = floorTarget
				floorTile.Transparency = 0
			end
			spawnDust(part.Position - Vector3.new(0, part.Size.Y / 2, 0), 6)
		elseif floorTile then
			floorTile:Destroy()
		end
		activeCount -= 1
		if floorTile and floorTile.Parent then
			task.wait(hold)
			local fade = TweenService:Create(floorTile, TweenInfo.new(0.12), { Transparency = 1 })
			fade.Completed:Connect(function()
				floorTile:Destroy()
			end)
			fade:Play()
		end
	end)
end

local function popIn(info: Pending, delay: number, duration: number, hold: number)
	local inst = info.inst
	if inst:IsA("Model") and info.target then
		popInModel(info, delay, duration)
	elseif inst:IsA("BasePart") and info.targetCF then
		popInPart(info, delay, duration, hold)
	else
		revealAtRest(info)
	end
end

-- ===== Container watching ===================================================
-- Each rendered container (Built, Ceilings) gets one binding. New non-bulk children are
-- staged out of view immediately, then popped in on the next frame (batched so a drag's
-- children coalesce into one staggered cascade). Bulk children (server-marked loads/resets)
-- are left untouched - that's the whole load-vs-placement decision, made authoritatively.
-- `speedUp` containers (ceilings) compress their cascade as the batch grows; walls/content do not.

type Binding = {
	conn: RBXScriptConnection,
	pending: { Pending },
	flushing: boolean,
	seen: { [Instance]: boolean },
	speedUp: boolean,
}
local bindings: { [Instance]: Binding } = {}

local function flush(container: Instance, binding: Binding)
	local batch = binding.pending
	binding.pending = {}
	binding.flushing = false

	-- Filter to what's still staged, so the cascade compresses over the real count.
	local live = {}
	for _, info in batch do
		if info.inst.Parent == stagingFolder then
			table.insert(live, info)
		end
	end

	local factor = if binding.speedUp then cascadeFactor(#live) else 1
	local stagger = POP_STAGGER / factor
	local duration = POP_DURATION / factor
	local totalDuration = duration + math.max(0, #live - 1) * stagger
	for index, info in live do
		local delay = (index - 1) * stagger
		local hold = totalDuration - delay - duration + Building.ANIMATION_HANDOFF_DELAY
		popIn(info, delay, duration, hold)
	end
end

local function bindContainer(container: Instance, speedUp: boolean)
	if bindings[container] then
		return
	end
	local binding: Binding = {
		conn = nil :: any,
		pending = {},
		flushing = false,
		seen = setmetatable({}, { __mode = "k" }) :: any,
		speedUp = speedUp,
	}

	local function consider(child: Instance)
		if binding.seen[child] then
			return
		end
		binding.seen[child] = true
		if child:GetAttribute(BULK_ATTRIBUTE) then
			return -- server rendered this as part of a load/reset; leave it be
		end
		table.insert(binding.pending, stage(child, container))
		if binding.flushing then
			return
		end
		binding.flushing = true
		task.spawn(function()
			-- Wait one frame so every child added this frame coalesces into one batch.
			RunService.Heartbeat:Wait()
			flush(container, binding)
		end)
	end

	binding.conn = container.ChildAdded:Connect(consider)
	bindings[container] = binding
	-- A first placement can land in the container before we connect (bind race); animate any
	-- non-bulk children already present. A normal load's children are all bulk-marked.
	for _, child in container:GetChildren() do
		consider(child)
	end
end

local function unbindContainer(container: Instance)
	local binding = bindings[container]
	if binding then
		binding.conn:Disconnect()
		bindings[container] = nil
	end
end

-- ===== Plot tracking ========================================================
-- Follow whichever plot the local player owns and bind its render containers. The plot's
-- Built/Ceilings folders are created lazily and destroyed on reset/reload, so we bind them
-- as they appear and unbind as they go - each fresh folder restarts the load heuristic.

local plotConns: { [Instance]: { RBXScriptConnection } } = {}

local function maybeBindContainer(child: Instance)
	-- Ceilings speed up their cascade as more are placed; Built (walls/content) keeps a fixed cadence.
	if child.Name == "Built" then
		bindContainer(child, false)
	elseif child.Name == "Ceilings" then
		bindContainer(child, true)
	end
end

local function bindPlot(plotModel: Instance)
	if plotConns[plotModel] then
		return
	end
	local conns = {}
	for _, child in plotModel:GetChildren() do
		maybeBindContainer(child)
	end
	table.insert(conns, plotModel.ChildAdded:Connect(maybeBindContainer))
	table.insert(conns, plotModel.ChildRemoved:Connect(unbindContainer))
	plotConns[plotModel] = conns
end

local function unbindPlot(plotModel: Instance)
	local conns = plotConns[plotModel]
	if not conns then
		return
	end
	for _, conn in conns do
		conn:Disconnect()
	end
	plotConns[plotModel] = nil
	for _, child in plotModel:GetChildren() do
		unbindContainer(child)
	end
end

local function isMine(plotModel: Instance): boolean
	return plotModel:GetAttribute("Owner") == player.Name
end

local function refreshPlots(plotsFolder: Instance)
	for _, plotModel in plotsFolder:GetChildren() do
		if isMine(plotModel) then
			bindPlot(plotModel)
		elseif plotConns[plotModel] then
			unbindPlot(plotModel)
		end
	end
end

task.spawn(function()
	local plotsFolder = Workspace:WaitForChild("Plots")
	local function hookPlot(plotModel: Instance)
		plotModel:GetAttributeChangedSignal("Owner"):Connect(function()
			refreshPlots(plotsFolder)
		end)
	end
	for _, plotModel in plotsFolder:GetChildren() do
		hookPlot(plotModel)
	end
	plotsFolder.ChildAdded:Connect(function(plotModel)
		hookPlot(plotModel)
		refreshPlots(plotsFolder)
	end)
	plotsFolder.ChildRemoved:Connect(function(plotModel)
		unbindPlot(plotModel)
	end)
	refreshPlots(plotsFolder)
end)

-- ===== Delete poof (driven by the delete tool) ==============================

--[[Detaches a display-only copy of a live model before it's removed, so we still have
something to animate after the real instance is destroyed by replication. Anchored and
non-interactive; it exists only to poof.]]
function ClientBuildingAnimator:CloneForPoof(model: Model): Model?
	if not model or not model.Parent then
		return nil
	end
	local clone = model:Clone()
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end
	clone:PivotTo(model:GetPivot())
	clone.Parent = effectsFolder
	return clone
end

--[[Shrinks a detached clone out with a little anticipation and rise, plus a dust burst,
then destroys it. Pass a clone from CloneForPoof.]]
function ClientBuildingAnimator:PoofClone(clone: Model)
	if not clone then
		return
	end
	local target = clone:GetPivot()
	local _, size = clone:GetBoundingBox()
	local basePos = Vector3.new(target.X, target.Y - size.Y / 2, target.Z)
	spawnDust(basePos, 12)
	task.spawn(function()
		local started = os.clock()
		while clone.Parent do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - started) / POOF_DURATION
			if t >= 1 then
				break
			end
			local scale = math.max(0.02, 1 - (1 - 0.02) * backIn(t))
			local rise = POOF_RISE * quadOut(t)
			pcall(function()
				clone:ScaleTo(scale)
				clone:PivotTo(target * CFrame.new(0, rise, 0))
			end)
		end
		clone:Destroy()
	end)
end

--[[Convenience for the common case: clone a live model right now and poof the copy.
Returns whether a clone was produced (nil-safe on already-removed models).]]
function ClientBuildingAnimator:PoofModel(model: Model): boolean
	local clone = self:CloneForPoof(model)
	if not clone then
		return false
	end
	self:PoofClone(clone)
	return true
end

-- ===== Floor stamps (driven by the paint tool) ==============================

--[[Drops a matched tile into each painted cell while a cell-sized copy of its old surface
covers the immediate server remesh. A huge fill skips the effect.]]
function ClientBuildingAnimator:FloorStamp(
	stamps: { FloorStamp },
	cellSize: number,
	material: Enum.Material,
	color: Color3
)
	if #stamps == 0 or #stamps > STAMP_MAX then
		return
	end
	local factor = cascadeFactor(#stamps)
	local stagger = STAMP_STAGGER / factor
	local duration = STAMP_DURATION / factor
	for index, stamp in stamps do
		local cover, restCF = makeFloorTile(
			stamp.Position,
			cellSize,
			stamp.PreviousMaterial,
			stamp.PreviousColor
		)
		cover.CFrame = restCF
		cover.Parent = effectsFolder
		task.delay((index - 1) * stagger, function()
			spawnFloorTile(stamp, cellSize, material, color, duration, cover)
		end)
	end
end

return ClientBuildingAnimator
