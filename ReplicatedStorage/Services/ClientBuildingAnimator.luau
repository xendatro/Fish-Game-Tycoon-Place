--[[
ClientBuildingAnimator - the "juice" layer for building. It has no authority and touches
no data; it only makes placements *feel* good on the local client.

Two jobs:
  1. Watches the local player's plot for newly-rendered placements (which arrive via normal
     Roblox replication once the server commits them) and pops each one in - a scale
     overshoot, a short drop, a dust puff, and a brief confirm flash.
  2. Exposes PoofModel/CloneForPoof/PoofClone so the delete tool can shrink an object out
     with a matching dust burst instead of having it blink out of existence.

Everything here is presentation-only and local: only you see your own pop-ins and poofs,
which is exactly what a build system wants (instant, personal feedback on your own action).

Distinguishing an interactive placement from a bulk load matters - you don't want your
entire saved base popping in when you join. We can't ask the server "was this a click?",
so we infer it: a plot that replicates in already populated is a load (skip + a straggler
grace window), and any single frame that adds more than BATCH_MAX children at once is a
bulk op (undo of a huge drag, a paint sweep) rather than a hand placement. Small drags fall
under the threshold and get a satisfying staggered cascade.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local ClientBuildingAnimator = {}

if not RunService:IsClient() then
	return ClientBuildingAnimator
end

local player = Players.LocalPlayer

-- Tuning. All timings are in seconds, all distances in studs.
local POP_DURATION = 0.26 -- pop-in length
local POP_START_SCALE = 0.06 -- models grow from ~nothing so there's no full-size flash
local POP_DROP_HEIGHT = 1.6 -- how far above its rest the object starts before slamming down
local POP_STAGGER = 0.035 -- per-item delay so a drag cascades instead of popping as one blob
local POP_BATCH_MAX = 24 -- a single frame adding more than this is a bulk load, not a placement
local POP_BULK_GRACE = 2.5 -- ignore stragglers this long after a pre-populated plot binds
local POP_CONCURRENT_CAP = 16 -- above this many live animations, new placements just snap in

local POOF_DURATION = 0.22 -- delete shrink-out length
local POOF_RISE = 0.9 -- slight upward drift as an object poofs

local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local DUST_COLOR = Color3.fromRGB(236, 231, 220)
local FLASH_COLOR = Color3.fromRGB(255, 255, 255)
local FLASH_OUTLINE = Color3.fromRGB(150, 220, 255)

local activeCount = 0

-- One shared home for transient effect instances so they never clutter the plot folders.
local effectsFolder = Instance.new("Folder")
effectsFolder.Name = "BuildingEffects"
effectsFolder.Parent = Workspace

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

-- ===== Pop-in ===============================================================

-- A child captured the instant it was added. A Model's rest pivot is read straight away
-- (WorldPivot replicates before its parts stream in, so it's reliable even on an "empty"
-- model), and we shrink it to the pop's start scale right away too - both as a best-effort
-- hide the frame it appears, and so it stays tiny (near-invisible) through any stagger wait
-- rather than sitting full-size. A slab is a lone Part that arrives whole, so it's moved up
-- and made transparent. The scale/pivot edits are local only; the server never fights them.
type Pending = {
	inst: Instance,
	target: CFrame?,
	targetCF: CFrame?,
	transparency: number?,
}

local function hideModel(model: Model, target: CFrame)
	pcall(function()
		model:ScaleTo(POP_START_SCALE)
		model:PivotTo(target * CFrame.new(0, POP_DROP_HEIGHT, 0))
	end)
end

--[[Captures a new child's resting transform and immediately hides it, so it doesn't linger
at full size before its pop. Runs synchronously in ChildAdded, the same frame it appears.]]
local function prehide(inst: Instance): Pending
	local info: Pending = { inst = inst }
	if inst:IsA("Model") then
		info.target = inst:GetPivot()
		hideModel(inst, info.target)
	elseif inst:IsA("BasePart") then
		info.targetCF = inst.CFrame
		info.transparency = inst.Transparency
		inst.CFrame = (info.targetCF :: CFrame) * CFrame.new(0, POP_DROP_HEIGHT, 0)
		inst.Transparency = 1
	end
	return info
end

--[[Snaps a prehidden child back to its resting state with no animation. Used when a batch
turns out to be a bulk load, or when we're over the concurrency cap.]]
local function restore(info: Pending)
	local inst = info.inst
	if not inst.Parent then
		return
	end
	if inst:IsA("Model") and info.target then
		pcall(function()
			inst:ScaleTo(1)
			inst:PivotTo(info.target :: CFrame)
		end)
	elseif inst:IsA("BasePart") and info.targetCF then
		inst.CFrame = info.targetCF
		inst.Transparency = info.transparency or 0
	end
end

--[[Pops a content/wall Model in: from its tiny+high start it drops and scales up past full
size (Back overshoot) before settling exactly onto the server's transform. Dust and a flash
fire on landing. Scale/pivot edits are purely local, so the instance is never fought over.]]
local function popInModel(info: Pending, delay: number)
	local model = info.inst :: Model
	local target = info.target :: CFrame

	-- Re-assert the hidden state synchronously: parts may have streamed in (at full size)
	-- between the add and now, and staggered items must stay tiny through their wait.
	hideModel(model, target)

	activeCount += 1
	task.spawn(function()
		if delay > 0 then
			task.wait(delay)
		end
		local started = os.clock()
		while model.Parent do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - started) / POP_DURATION
			if t >= 1 then
				break
			end
			local scale = POP_START_SCALE + (1 - POP_START_SCALE) * backOut(t)
			local drop = POP_DROP_HEIGHT * (1 - cubicOut(t))
			pcall(function()
				model:ScaleTo(scale)
				model:PivotTo(target * CFrame.new(0, drop, 0))
			end)
		end
		if model.Parent then
			pcall(function()
				model:ScaleTo(1)
				model:PivotTo(target)
			end)
			local _, size = model:GetBoundingBox()
			spawnDust(Vector3.new(target.X, target.Y - size.Y / 2, target.Z), 10)
			spawnFlash(model)
		end
		activeCount -= 1
	end)
end

--[[Drops a ceiling/floor-style slab (a single Part, not a Model) in from above with a soft
fade. Slabs are thin, so a scale pop reads badly; a drop + materialise looks right.]]
local function popInPart(info: Pending, delay: number)
	local part = info.inst :: BasePart
	local targetCF = info.targetCF :: CFrame
	local targetTransparency = info.transparency or 0

	activeCount += 1
	task.spawn(function()
		if delay > 0 then
			task.wait(delay)
		end
		local started = os.clock()
		while part.Parent do
			RunService.Heartbeat:Wait()
			local t = (os.clock() - started) / POP_DURATION
			if t >= 1 then
				break
			end
			local drop = POP_DROP_HEIGHT * (1 - cubicOut(t))
			pcall(function()
				part.CFrame = targetCF * CFrame.new(0, drop, 0)
				part.Transparency = targetTransparency + (1 - targetTransparency) * (1 - t)
			end)
		end
		if part.Parent then
			pcall(function()
				part.CFrame = targetCF
				part.Transparency = targetTransparency
			end)
			spawnDust(part.Position - Vector3.new(0, part.Size.Y / 2, 0), 6)
		end
		activeCount -= 1
	end)
end

local function popIn(info: Pending, delay: number)
	if activeCount >= POP_CONCURRENT_CAP then
		restore(info) -- too much at once; reveal it instantly rather than drop frames
		return
	end
	local inst = info.inst
	if inst:IsA("Model") and info.target then
		popInModel(info, delay)
	elseif inst:IsA("BasePart") and info.targetCF then
		popInPart(info, delay)
	else
		restore(info)
	end
end

-- ===== Container watching ===================================================
-- Each rendered container (Built, Ceilings) gets one binding that coalesces the children
-- added in a frame into a batch, then decides: bulk load (restore) or hand placement (pop).

type Binding = { conn: RBXScriptConnection, pending: { Pending }, flushing: boolean, bulkUntil: number }
local bindings: { [Instance]: Binding } = {}

local function flush(container: Instance, binding: Binding)
	local batch = binding.pending
	binding.pending = {}
	binding.flushing = false
	if #batch == 0 then
		return
	end
	-- A whole base loading in, or a huge undo/paint sweep: no cascade, just reveal them.
	if #batch > POP_BATCH_MAX or os.clock() < binding.bulkUntil then
		for _, info in batch do
			restore(info)
		end
		return
	end
	local index = 0
	for _, info in batch do
		if info.inst.Parent ~= container then
			continue -- already removed before we could animate it
		end
		popIn(info, index * POP_STAGGER)
		index += 1
	end
end

local function bindContainer(container: Instance)
	if bindings[container] then
		return
	end
	local binding: Binding = {
		conn = nil :: any,
		pending = {},
		flushing = false,
		-- Present-at-bind children mean the plot arrived already built: treat it as a load
		-- and swallow anything still streaming in for a moment after.
		bulkUntil = if #container:GetChildren() > 0 then os.clock() + POP_BULK_GRACE else 0,
	}
	binding.conn = container.ChildAdded:Connect(function(child)
		-- Hide it right now, this frame, so it never flashes at full size.
		table.insert(binding.pending, prehide(child))
		if binding.flushing then
			return
		end
		binding.flushing = true
		task.spawn(function()
			-- Wait one frame so every child added this frame coalesces into one batch.
			RunService.Heartbeat:Wait()
			flush(container, binding)
		end)
	end)
	bindings[container] = binding
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
	if child.Name == "Built" or child.Name == "Ceilings" then
		bindContainer(child)
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

return ClientBuildingAnimator
