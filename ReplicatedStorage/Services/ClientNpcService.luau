--[[
ClientNpcService - renders the guests the server is simulating.

The server never spawns a character; it sends events (Spawn / Move / Idle / Despawn) for
one plot at a time. This service clones the matching model out of Assets.NPCs, anchors it,
and walks its root along the leg's polyline by clock time. Because a leg carries its own
start time and speed, a guest that was already halfway across the plot when you subscribed
just appears halfway across it - no snapping, no per-frame position traffic.

Followers in a squad share the leader's polyline, trailing it by a stagger and stepping
sideways off it, which reads as a loose clump on open floor and collapses to single file
in a one-cell gap for free.

A client renders exactly one plot: whichever it is standing closest to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ClientNpcService = {}
if not RunService:IsClient() then
	return ClientNpcService
end

local Npc = require(ReplicatedStorage.Config.Npc)
local Signal = require(ReplicatedStorage.Classes.Signal)
local SharedNpcService = require(ReplicatedStorage.Services.SharedNpcService)

local Player = Players.LocalPlayer
local NpcAssets = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("NPCs")
local NpcRemotes = ReplicatedStorage:WaitForChild("Communication"):WaitForChild("Npc")
local watchRemote = NpcRemotes:WaitForChild("Watch") :: RemoteFunction
local updateRemote = NpcRemotes:WaitForChild("Update") :: RemoteEvent

type Leg = {
	Points: { Vector3 },
	StartTime: number,
	Speed: number,
	Total: number,
	Spread: number,
	-- Where this squad is headed to stand, and over how many studs of the approach they
	-- peel off the shared line toward it. Absent on legs that don't end in a stop.
	Spots: { Vector3 }?,
	FanOut: number?,
	-- The blend windows actually used, after allowing for a leg too short for both.
	FanInDistance: number,
	FanOutDistance: number,
}
type Guest = {
	Id: number,
	GroupId: number,
	Model: Model,
	Root: BasePart,
	Height: number, -- root centre height above the ground the guest walks on
	Run: AnimationTrack,
	Idle: AnimationTrack,
	Anim: "Run" | "Idle",
	Slot: number, -- position within its squad; 0 is the leader
	Leg: Leg?,
	From: Vector3?, -- where they were standing when the current leg began
	-- Extra ground this guest covers beyond the shared line, peeling off it at the start
	-- and onto their own place at the end. Spent as time, not speed.
	ExtraIn: number,
	ExtraOut: number,
	Distance: number, -- how far along their own route they have walked
	Pace: number, -- their party's walking speed, kept for moving about while stopped
	Stand: Vector3?, -- assigned place to stand while stopped
	Face: Vector3?,
	Position: Vector3,
	Facing: Vector3,
	Moving: boolean,
	Fading: boolean,
}

-- Crossfade between the run and idle cycles, and how fast the run cycle is played back
-- so its feet match the walking speed.
local ANIM_FADE = 0.18
local RUN_PLAYBACK = Npc.Movement.WalkSpeed / Npc.Render.RunAnimReferenceSpeed
-- Slowest a guest moves while easing off the ends of a walk, as a fraction of their pace.
local MIN_PACE = 0.2
-- Ground per second below which a guest counts as standing still rather than walking.
local WALKING_SPEED = 0.6

local Guests: { [number]: Guest } = {}
local WatchedPlot: number? = nil
local Container: Folder? = nil

ClientNpcService.WatchedPlotChanged = Signal.new()

-- ===== Geometry helpers =====================================================

--[[
Returns the position and travel direction `distance` along a polyline, plus how far the
point is from the nearest corner (the first and last points don't count as corners - a
squad still fans out while setting off and standing around).
]]
local function sample(points: { Vector3 }, distance: number): (Vector3, Vector3, number)
	local travelled = 0
	for i = 2, #points do
		local segment = points[i] - points[i - 1]
		local length = segment.Magnitude
		local direction = if length > 1e-4 then segment / length else Vector3.new(0, 0, 1)
		if travelled + length >= distance then
			local along = distance - travelled
			local toCorner = math.huge
			if i > 2 then
				toCorner = math.min(toCorner, along)
			end
			if i < #points then
				toCorner = math.min(toCorner, length - along)
			end
			return points[i - 1] + direction * along, direction, toCorner
		end
		travelled += length
	end
	local last = points[#points]
	local previous = points[math.max(1, #points - 1)]
	local direction = last - previous
	return last, (if direction.Magnitude > 1e-4 then direction.Unit else Vector3.new(0, 0, 1)), math.huge
end

--[[Where this slot walks relative to the leader. Shared with the server, which uses the
same geometry to work out who will arrive where.]]
local function slotOffset(slot: number, spread: number): (number, number)
	return SharedNpcService:SlotOffset(slot, spread)
end

local function polylineLength(points: { Vector3 }): number
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
	end
	return total
end

--[[Smooth 0..1 ramp, for easing into and out of a standstill.]]
local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
How fast a guest should be going, as a fraction of their walking pace, `distance` into a
route of length `total`. Ramps away from a standstill and back into one.

Walking is INTEGRATED from this rather than derived from the clock, because easing off the
ends while still covering the same ground in the same time is only possible by going
faster in the middle - which is exactly the sprint this is here to avoid. Easing costs
time instead: a guest arrives a beat later rather than making it up with speed.
]]
local function paceAt(distance: number, total: number): number
	local ease = math.min(Npc.Movement.EaseDistance, total / 2)
	if ease <= 0 then
		return 1
	end
	local ramp = math.min(smoothstep(distance / ease), smoothstep((total - distance) / ease))
	-- Never actually zero: a pace of nothing at the start means never setting off at all.
	return math.clamp(ramp, MIN_PACE, 1)
end

--[[Unpacks {x1, z1, x2, z2, ...} into positions at one height.]]
local function unflatten(flat: { number }, y: number): { Vector3 }
	local points = {}
	for i = 1, #flat - 1, 2 do
		table.insert(points, Vector3.new(flat[i], y, flat[i + 1]))
	end
	return points
end

--[[Where a given slot sits on the shared line at some distance along it.]]
local function legPoint(leg: Leg, distance: number, slot: number): Vector3
	local position, direction = sample(leg.Points, distance)
	local offset = slotOffset(slot, leg.Spread)
	return position + Vector3.new(-direction.Z, 0, direction.X) * offset
end

--[[
How much further a guest travels than the line does, peeling off it over a blend window.
Their route across the window is the hypotenuse of the window and the sideways detour, so
this is the difference - the ground the line doesn't account for.

It's added to the distance they have to cover rather than taken out of the time they have,
which is what stops followers breaking into a sprint to reach their place on time.
]]
local function detourCost(onLine: Vector3, target: Vector3?, window: number): number
	if not target or window <= 0 then
		return 0
	end
	local sideways = Vector3.new(target.X - onLine.X, 0, target.Z - onLine.Z).Magnitude
	return math.sqrt(window * window + sideways * sideways) - window
end

-- ===== Guest instances ======================================================

local function getContainer(): Folder
	if not Container then
		local folder = Instance.new("Folder")
		folder.Name = "Guests"
		folder.Parent = Workspace
		Container = folder
	end
	return Container :: Folder
end

--[[Fades a whole model in or out. LocalTransparencyModifier is render-only, so nothing
has to remember the authored transparency of hair, accessories or clothing.]]
local function fade(model: Model, from: number, to: number, duration: number, onDone: (() -> ())?)
	task.spawn(function()
		local elapsed = 0
		while elapsed < duration do
			elapsed += RunService.Heartbeat:Wait()
			-- Switching plots destroys guests mid-fade; there's nothing left to tint.
			if not model.Parent then
				return
			end
			local alpha = math.clamp(elapsed / duration, 0, 1)
			local value = from + (to - from) * alpha
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = value
				end
			end
		end
		if onDone then
			onDone()
		end
	end)
end

--[[Clones a guest model and prepares it for being driven by hand: anchored root, no
collision or raycast interference with the player or the build tools, and its run/idle
tracks pre-loaded. The Animate LocalScript never runs outside a player character, so the
animations it carries are loaded onto the Animator here instead.]]
local function createGuest(id: number, groupId: number, asset: string, position: Vector3, facing: Vector3): Guest?
	local template = NpcAssets:FindFirstChild(asset)
	if not template then
		warn(`[ClientNpcService]: no NPC model named '{asset}'`)
		return nil
	end

	local model = template:Clone()
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.LocalTransparencyModifier = 1
		end
	end
	root.Anchored = true
	humanoid.AutoRotate = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- The root is driven by hand, so park the state machine rather than letting it decide
	-- the guest is falling.
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	-- Rest the model's feet on the walking surface whatever its rig scale or hip height.
	local boundingCFrame, boundingSize = model:GetBoundingBox()
	local height = root.Position.Y - (boundingCFrame.Position.Y - boundingSize.Y / 2)

	model.Name = `Guest_{id}`
	root.CFrame = CFrame.lookAt(position + Vector3.new(0, height, 0), position + Vector3.new(0, height, 0) + facing)
	model.Parent = getContainer()

	-- Tracks have to be loaded once the model is in the world; an Animator that isn't
	-- there yet hands back a track that plays at zero weight forever. The Animate script
	-- is a LocalScript and never runs outside a player character, so the animations it
	-- carries are driven from here instead.
	-- Guests use whichever idle their character shipped with, picked per guest so a crowd
	-- isn't all doing the same one.
	local idles = {}
	for _, animation in model.Animate.idle:GetChildren() do
		if animation:IsA("Animation") then
			table.insert(idles, animation)
		end
	end

	local run = animator:LoadAnimation(model.Animate.run.RunAnim)
	local idle = animator:LoadAnimation(idles[math.random(1, #idles)])
	run.Looped = true
	idle.Looped = true
	idle:Play(ANIM_FADE)
	-- Offset into the cycle, or a whole crowd breathes in unison.
	idle.TimePosition = math.random() * idle.Length
	fade(model, 1, 0, Npc.Render.FadeIn)

	return {
		Id = id,
		GroupId = groupId,
		Model = model,
		Root = root,
		Height = height,
		Run = run,
		Idle = idle,
		Anim = "Idle",
		Slot = 0,
		Leg = nil,
		From = nil,
		ExtraIn = 0,
		ExtraOut = 0,
		Distance = 0,
		Pace = Npc.Movement.WalkSpeed,
		Stand = nil,
		Face = nil,
		Position = position,
		Facing = facing,
		Moving = false,
		Fading = false,
	}
end

local function removeGuest(guest: Guest)
	if guest.Fading then
		return
	end
	guest.Fading = true
	Guests[guest.Id] = nil
	guest.Run:Stop()
	guest.Idle:Stop()
	fade(guest.Model, 0, 1, Npc.Render.FadeOut, function()
		guest.Model:Destroy()
	end)
end

local function clearAll()
	for _, guest in Guests do
		guest.Model:Destroy()
	end
	table.clear(Guests)
end

-- ===== Event handling =======================================================

local function applyEvent(event: { [string]: any })
	if event.Kind == "Spawn" then
		local position = Vector3.new(event.X, event.Y, event.Z)
		local facing = Vector3.new(event.DirX, 0, event.DirZ)
		facing = if facing.Magnitude > 1e-4 then facing.Unit else Vector3.new(0, 0, 1)
		for _, entry in event.Guests do
			if not Guests[entry.Id] then
				Guests[entry.Id] = createGuest(entry.Id, event.GroupId, entry.Asset, position, facing)
			end
		end
		return
	end

	if event.Kind == "Despawn" then
		for _, id in event.Ids do
			local guest = Guests[id]
			if guest then
				removeGuest(guest)
			end
		end
		return
	end

	-- One leg shared by the whole squad; followers differ only by their slot.
	local leg: Leg? = nil
	if event.Kind == "Move" then
		local points = unflatten(event.Points, event.Y)
		local total = polylineLength(points)
		leg = {
			Points = points,
			StartTime = event.StartTime,
			Speed = event.Speed,
			Total = total,
			Spread = event.Spread or Npc.Movement.MemberSpread,
			Spots = event.Spots and unflatten(event.Spots, event.Y),
			FanOut = event.FanOut,
			FanInDistance = math.min(Npc.Formation.FanIn, total / 2),
			FanOutDistance = math.min(event.FanOut or 0, total / 2),
		}
	end

	-- A squad that stopped without anything to look at turns inward on itself, so it reads
	-- as a group talking rather than four people facing off in random directions. Worked
	-- out for walks too, since a guest looks up the moment they arrive.
	local spots = if event.Spots then unflatten(event.Spots, 0) else nil
	local huddle: Vector3? = nil
	if spots and #spots > 1 and not event.FaceX then
		local sum = Vector3.zero
		for _, spot in spots do
			sum += spot
		end
		huddle = sum / #spots
	end

	--[[What a guest looks at once they've stopped: the thing they came to see, or the rest
	of their group.]]
	local function lookTarget(guest: Guest): Vector3?
		if event.FaceX then
			return Vector3.new(event.FaceX, guest.Position.Y, event.FaceZ)
		elseif huddle then
			return Vector3.new(huddle.X, guest.Position.Y, huddle.Z)
		end
		return nil
	end

	-- Move and Idle both re-slot their squad: the order of Ids is the walking order.
	for slot, id in event.Ids do
		local guest = Guests[id]
		if not guest then
			continue
		end
		guest.Slot = slot - 1
		if leg then
			-- Remember where they were stood, so they walk out of the formation onto the
			-- line instead of teleporting onto it.
			guest.From = guest.Position
			guest.Leg = leg
			guest.Pace = leg.Speed
			guest.Stand = nil
			-- Known before they set off, so they can look up as soon as they get there.
			guest.Face = lookTarget(guest)
			guest.ExtraIn = detourCost(legPoint(leg, 0, guest.Slot), guest.Position, leg.FanInDistance)
			guest.ExtraOut = detourCost(
				legPoint(leg, leg.Total, guest.Slot),
				leg.Spots and leg.Spots[guest.Slot + 1],
				leg.FanOutDistance
			)
			-- Legs usually arrive as they begin, but a snapshot can hand over one already
			-- half walked, so start from wherever the clock says they've got to.
			local _, trail = slotOffset(guest.Slot, leg.Spread)
			local elapsed = Workspace:GetServerTimeNow() - leg.StartTime
			local behind = guest.Slot * SharedNpcService:StaggerFor(leg.Spread) + trail / leg.Speed
			guest.Distance = math.clamp((elapsed - behind) * leg.Speed, 0, leg.Total + guest.ExtraIn + guest.ExtraOut)
		else
			guest.Leg = nil
			-- A real stop hands out a place to stand; a brief hold leaves them put. A guest
			-- with no place of their own (a list that doesn't reach them) stays where they
			-- are rather than being sent somewhere meaningless.
			local spot = spots and spots[slot]
			guest.Stand = if spot then Vector3.new(spot.X, guest.Position.Y, spot.Z) else nil
			guest.Face = lookTarget(guest)
		end
	end
end

updateRemote.OnClientEvent:Connect(function(events)
	for _, event in events do
		applyEvent(event)
	end
end)

-- ===== Rendering ============================================================

--[[
Where a guest renders once they have walked `distance` along their own route: the squad's
line, plus peeling off it onto their own place at either end.

Progress maps onto the line, which advances more slowly through a blend because part of
the going is sideways.
]]
local function positionFor(guest: Guest, leg: Leg, distance: number): Vector3
	local fanIn, fanOut = leg.FanInDistance, leg.FanOutDistance
	local inWindow, outWindow = fanIn + guest.ExtraIn, fanOut + guest.ExtraOut
	local outStart = leg.Total - fanOut

	local along
	if inWindow > 0 and distance <= inWindow then
		along = distance * fanIn / inWindow
	elseif outWindow > 0 and distance >= outStart + guest.ExtraIn then
		along = outStart + (distance - guest.ExtraIn - outStart) * fanOut / outWindow
	else
		along = distance - guest.ExtraIn
	end

	local position, direction, toCorner = sample(leg.Points, math.clamp(along, 0, leg.Total))
	-- Fold followers back onto the line through a corner so they don't swing wide through
	-- whatever the line is turning around.
	local ease = math.clamp(toCorner / Npc.Movement.CornerEase, 0, 1)
	local offset = slotOffset(guest.Slot, leg.Spread)
	local result = position + Vector3.new(-direction.Z, 0, direction.X) * offset * ease

	-- Leaving: converge onto the walking line from wherever they were stood.
	if guest.From and inWindow > 0 and distance < inWindow then
		local start = Vector3.new(guest.From.X, result.Y, guest.From.Z)
		result = start:Lerp(result, smoothstep(distance / inWindow))
	end

	-- Arriving: drift off the line toward the place waiting for them, so the squad arrives
	-- already spread out instead of stacking on the destination and sorting itself out.
	local spot = leg.Spots and leg.Spots[guest.Slot + 1]
	if spot and outWindow > 0 then
		local blend = smoothstep((distance - guest.ExtraIn - outStart) / outWindow)
		if blend > 0 then
			result = result:Lerp(Vector3.new(spot.X, result.Y, spot.Z), blend)
		end
	end
	return result
end

local function updateGuest(guest: Guest, timestamp: number, delta: number)
	local facing = guest.Facing
	local was = guest.Position

	if guest.Leg then
		local leg = guest.Leg
		local _, trail = slotOffset(guest.Slot, leg.Spread)
		local total = leg.Total + guest.ExtraIn + guest.ExtraOut

		-- Wait for their turn in the order, then walk. Progress is INTEGRATED, and each
		-- step is scaled to the ground it actually covers, so a stretch that curves or
		-- peels sideways advances along the route more slowly rather than being sprinted.
		-- Whatever the route does, a guest never moves faster than they walk.
		local behind = guest.Slot * SharedNpcService:StaggerFor(leg.Spread) + trail / leg.Speed
		if timestamp - leg.StartTime >= behind and guest.Distance < total then
			local want = leg.Speed * delta * paceAt(guest.Distance, total)
			local step = math.min(want, total - guest.Distance)
			local ahead = positionFor(guest, leg, guest.Distance + step)
			local ground = Vector3.new(ahead.X - guest.Position.X, 0, ahead.Z - guest.Position.Z).Magnitude
			if ground > want and ground > 1e-4 then
				step *= want / ground
			end
			guest.Distance = math.min(total, guest.Distance + step)
		end

		guest.Position = positionFor(guest, leg, guest.Distance)
	else
		-- Stopped. Anyone who walked here has already fanned into their place during the
		-- approach; this walks in whoever was told to stand somewhere while stationary
		-- (waiting out a splinter, or shuffling aside for an arriving group) - at walking
		-- pace, easing to a halt, rather than gliding there.
		if guest.Stand then
			local toSpot = Vector3.new(guest.Stand.X - guest.Position.X, 0, guest.Stand.Z - guest.Position.Z)
			local distance = toSpot.Magnitude
			if distance > 0.05 then
				local pace = guest.Pace * smoothstep(distance / Npc.Movement.EaseDistance)
				guest.Position += toSpot / distance * math.min(distance, pace * delta)
			else
				guest.Position = guest.Stand
			end
		end
	end

	-- Walking is whether they are actually covering ground, not how far through a route
	-- they are: a guest who has reached their place stands and idles even if the rest of
	-- the party is still coming in.
	local moved = Vector3.new(guest.Position.X - was.X, 0, guest.Position.Z - was.Z)
	guest.Moving = moved.Magnitude / math.max(delta, 1e-4) > WALKING_SPEED

	-- Face where they're actually going, whatever is producing the motion - the line, a
	-- fan-out, or the last shuffle into place. Standing still, look at whatever they
	-- stopped for: the tank, or the rest of their group.
	if guest.Moving then
		facing = moved.Unit
	elseif guest.Face then
		local toTarget = Vector3.new(guest.Face.X - guest.Position.X, 0, guest.Face.Z - guest.Position.Z)
		if toTarget.Magnitude > 1e-3 then
			facing = toTarget.Unit
		end
	end

	local blend = 1 - math.exp(-Npc.Movement.TurnSpeed * delta)
	local turned = guest.Facing:Lerp(facing, blend)
	guest.Facing = if turned.Magnitude > 1e-4 then turned.Unit else facing

	local eye = guest.Position + Vector3.new(0, guest.Height, 0)
	guest.Root.CFrame = CFrame.lookAt(eye, eye + guest.Facing)

	-- Switch on the state change only: re-issuing Play every frame restarts the crossfade
	-- and the track never reaches full weight.
	local desired = if guest.Moving then "Run" else "Idle"
	if guest.Anim ~= desired then
		guest.Anim = desired
		if desired == "Run" then
			guest.Idle:Stop(ANIM_FADE)
			guest.Run:Play(ANIM_FADE, 1, RUN_PLAYBACK)
		else
			guest.Run:Stop(ANIM_FADE)
			guest.Idle:Play(ANIM_FADE, 1, 1)
		end
	end
end

RunService.Heartbeat:Connect(function(delta)
	local timestamp = Workspace:GetServerTimeNow()
	for _, guest in Guests do
		updateGuest(guest, timestamp, delta)
	end
end)

-- ===== Plot subscription ====================================================

--[[Returns the plot the local player is standing closest to.]]
local function nearestPlot(): (number?, BasePart?)
	local character = Player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local from = if root then root.Position else Workspace.CurrentCamera.CFrame.Position

	local bestNumber, bestPart, bestDistance = nil, nil, math.huge
	for _, plot in Workspace.Plots:GetChildren() do
		local base = plot:FindFirstChild("Plot") :: BasePart?
		local number = tonumber(plot.Name)
		if base and number then
			local offset = base.Position - from
			local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
			if distance < bestDistance then
				bestNumber, bestPart, bestDistance = number, base, distance
			end
		end
	end
	return bestNumber, bestPart
end

--[[Subscribes to a plot and rebuilds everything currently on it.]]
local function watch(plotNumber: number)
	WatchedPlot = plotNumber
	clearAll()
	local snapshot = watchRemote:InvokeServer(plotNumber)
	-- A plot switch mid-request wins; discard the stale snapshot.
	if not snapshot or WatchedPlot ~= plotNumber then
		return
	end
	for _, event in snapshot.Events do
		applyEvent(event)
	end
	ClientNpcService.WatchedPlotChanged:Fire(plotNumber, snapshot.Popularity)
end

task.spawn(function()
	while true do
		local plotNumber = nearestPlot()
		if plotNumber and plotNumber ~= WatchedPlot then
			watch(plotNumber)
		end
		task.wait(Npc.Render.WatchInterval)
	end
end)

-- ===== Public API ===========================================================

--[[The plot whose guests are currently being rendered.]]
function ClientNpcService:GetWatchedPlot(): number?
	return WatchedPlot
end

--[[Live guest and group counts for the watched plot.]]
function ClientNpcService:GetCounts(): (number, number)
	local guests, groups = 0, 0
	local seen = {}
	for _, guest in Guests do
		guests += 1
		if not seen[guest.GroupId] then
			seen[guest.GroupId] = true
			groups += 1
		end
	end
	return guests, groups
end

--[[Every polyline currently being walked, for debug visualisation.]]
function ClientNpcService:GetActiveLegs(): { { Vector3 } }
	local legs = {}
	for _, guest in Guests do
		if guest.Slot == 0 and guest.Leg then
			table.insert(legs, guest.Leg.Points)
		end
	end
	return legs
end

return ClientNpcService
