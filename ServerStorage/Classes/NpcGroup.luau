--[[
NpcGroup - one arriving party of guests and everything it decides to do.

A group is made of SQUADS. Normally there is exactly one (everybody walks together), but
a group can splinter: a member or two peel off, wander on their own for a while, then
rejoin. A group can never leave while it is still split - reuniting is a precondition of
the exit step, per the design doc.

The class owns decisions and timing only. It never touches Instances: it emits events
(Spawn / Move / Idle / Despawn) that ServerNpcService forwards to whichever clients are
watching this plot, and those clients do all the rendering. Positions here are therefore
"where the sim believes the leader is", derived from the current leg and the clock.

Everything it can decide is a number in Config/Npc.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Npc = require(ReplicatedStorage.Config.Npc)
local SharedNpcService = require(ReplicatedStorage.Services.SharedNpcService)

local NpcGroup = {}
NpcGroup.__index = NpcGroup

export type Member = { Id: number, Asset: string }
--[[
What a squad is currently doing, and therefore what finishing it means:
  Enter     walking in from outside        Wander    splinter walking to its own stop
  Action    walking to something to see    Wandering splinter lingering there
  Acting    lingering at it (counts!)      Rejoin    splinter walking back to the group
  Wait      neutral hold (never counts)    Leave     walking to the exit door
                                           Exit      walking out of the approach lane
]]
type Goal = "Enter" | "Action" | "Acting" | "Wait" | "Wander" | "Wandering" | "Rejoin" | "Leave" | "Exit"

type Squad = {
	Members: { Member },
	State: "Move" | "Idle" | "Stuck",
	Goal: Goal,
	Points: { Vector3 }?,
	Spread: number?,
	Spots: { Vector3 }?, -- where each member stands while stopped
	StartTime: number,
	EndTime: number,
	Position: Vector3,
	Target: SharedNpcService.Cell?,
	Face: Vector3?,
	StuckSince: number?,
	RetryAt: number?,
	RevalidateAt: number?,
	RejoinAt: number?, -- splinter squads only
}

-- The plot-side context a group needs. Supplied by ServerNpcService. The spot registry is
-- shared by every group on the plot, which is what keeps two of them from standing in the
-- same place.
export type World = {
	Grid: any,
	Entrance: SharedNpcService.Entrance,
	Emit: (event: { [string]: any }) -> (),
	SetSpots: (ids: { number }, spots: { Vector3 }) -> (),
	ClearSpots: (ids: { number }) -> (),
	SpotFree: (position: Vector3, exclude: { [number]: boolean }) -> boolean,
	CrowdCost: SharedNpcService.CrowdCost,
}

-- ===== Small helpers ========================================================

local function randomRange(range: { number }): number
	return range[1] + math.random() * (range[2] - range[1])
end

--[[Picks an index from a list of relative weights.]]
local function weightedIndex(weights: { number }): number
	local total = 0
	for _, weight in weights do
		total += weight
	end
	local roll = math.random() * total
	for index, weight in weights do
		roll -= weight
		if roll <= 0 then
			return index
		end
	end
	return #weights
end

--[[Total ground length of a polyline.]]
local function polylineLength(points: { Vector3 }): number
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
	end
	return total
end

--[[Returns the position `distance` along a polyline (clamped at both ends).]]
local function sampleAt(points: { Vector3 }, distance: number): Vector3
	if distance <= 0 then
		return points[1]
	end
	local travelled = 0
	for i = 2, #points do
		local segment = (points[i] - points[i - 1]).Magnitude
		if travelled + segment >= distance then
			return points[i - 1]:Lerp(points[i], (distance - travelled) / math.max(segment, 1e-4))
		end
		travelled += segment
	end
	return points[#points]
end

local function idsOf(squad: Squad): { number }
	local ids = {}
	for _, member in squad.Members do
		table.insert(ids, member.Id)
	end
	return ids
end

--[[Flattens a polyline to the {x1, z1, x2, z2, ...} pairs sent over the wire. Y is
constant for a leg (guests stay on one build level), so it travels separately.]]
local function flatten(points: { Vector3 }): { number }
	local flat = {}
	for _, point in points do
		table.insert(flat, point.X)
		table.insert(flat, point.Z)
	end
	return flat
end

--[[
Pairs up two sets of points so that nobody has to cross anybody else to get from their one
to their other, returning for each `from` the index of the `to` it was given.

It picks the pairing with the shortest total distance. For points in a plane that is never
one where two paths cross - swapping a crossing pair is always shorter by the triangle
inequality - so "shortest" and "nobody walks through anybody" are the same answer. Parties
are at most four, so every pairing is simply tried.
]]
local function bestMatching(from: { Vector3 }, to: { Vector3 }): { number }
	local order, best, bestCost = {}, nil, math.huge
	for index = 1, #from do
		order[index] = index
	end

	local function search(depth: number)
		if depth > #order then
			local cost = 0
			for index, target in order do
				cost += (from[index] - to[target]).Magnitude
			end
			if cost < bestCost then
				bestCost, best = cost, table.clone(order)
			end
			return
		end
		for index = depth, #order do
			order[depth], order[index] = order[index], order[depth]
			search(depth + 1)
			order[depth], order[index] = order[index], order[depth]
		end
	end
	search(1)
	return best :: { number }
end

--[[Where each walking slot of a squad sits, relative to a point on its line.]]
local function walkingPositions(squad: Squad, at: Vector3, direction: Vector3): { Vector3 }
	local side = Vector3.new(-direction.Z, 0, direction.X)
	local positions = {}
	for member = 1, #squad.Members do
		local sideways, trail = SharedNpcService:SlotOffset(member - 1, squad.Spread or Npc.Movement.MemberSpread)
		table.insert(positions, at + side * sideways - direction * trail)
	end
	return positions
end

-- ===== Construction =========================================================

--[[Creates a group of members standing outside the plot's entrance, ready to walk in.]]
function NpcGroup.new(id: number, members: { Member }, world: World)
	local self = setmetatable({}, NpcGroup)
	self.Id = id
	self.Members = members
	self.Done = false
	self._world = world
	self._leaving = false
	self._visited = {} :: { [number]: boolean } -- placement ids already seen this visit
	-- Each party walks at its own pace, so the plot isn't a metronome.
	local variance = Npc.Movement.SpeedVariance
	self._speed = Npc.Movement.WalkSpeed * (1 + (math.random() * 2 - 1) * variance)

	-- A guaranteed count plus decaying rolls for extras (design doc's action budget).
	local actions = Npc.Actions.Guaranteed
	local chance = Npc.Actions.ExtraChance
	for _ = 1, Npc.Actions.MaxExtra do
		if math.random() > chance then
			break
		end
		actions += 1
		chance *= Npc.Actions.ExtraChanceDecay
	end
	self._actionsLeft = actions

	self._squads = {
		{
			Members = members,
			State = "Idle",
			Goal = "Enter",
			StartTime = 0,
			EndTime = 0,
			Position = world.Entrance.Outside,
		} :: Squad,
	}

	return self
end

export type NpcGroup = typeof(NpcGroup.new(0, {}, nil :: any))

--[[Emits the arrival of every member, standing outside the entrance and facing in.]]
function NpcGroup:Spawn(now: number)
	local entrance = self._world.Entrance
	local guests = {}
	for _, member in self.Members do
		table.insert(guests, { Id = member.Id, Asset = member.Asset })
	end
	self._world.Emit({
		Kind = "Spawn",
		GroupId = self.Id,
		Guests = guests,
		X = entrance.Outside.X,
		Y = entrance.Outside.Y,
		Z = entrance.Outside.Z,
		DirX = entrance.Inward.X,
		DirZ = entrance.Inward.Z,
	})
	-- Walking in is a plain straight line: the approach lane is off-grid, so there's
	-- nothing to path around until they're through the door.
	local doorway = SharedNpcService:CellToWorld(
		self._world.Grid,
		entrance.Cell.X,
		entrance.Cell.Z,
		Npc.FLOOR
	)
	self:_move(self._squads[1], { entrance.Outside, doorway }, "Enter", now)
end

-- ===== Leg emission =========================================================

--[[
Puts a squad into the order it should walk in: whoever is stood nearest the front of the
line leads, and whoever is stood on one side keeps to that side. Walking order is the
member order, so setting off is just everyone stepping forward rather than the party
swapping places through each other first.
]]
function NpcGroup:_orderForWalk(squad: Squad, points: { Vector3 })
	local standing = squad.Spots
	if not standing or #standing ~= #squad.Members or #points < 2 then
		return
	end
	local direction = points[2] - points[1]
	if direction.Magnitude < 1e-3 then
		return
	end

	local slots = walkingPositions(squad, points[1], direction.Unit)
	local matched = bestMatching(slots, standing)
	local members, spots = {}, {}
	for slot, member in matched do
		members[slot] = squad.Members[member]
		spots[slot] = standing[member]
	end
	squad.Members = members
	squad.Spots = spots
end

--[[Starts a squad walking a polyline. The slowest member trails the leader by the group
stagger, so the whole squad has landed by EndTime.]]
function NpcGroup:_move(squad: Squad, points: { Vector3 }, goal: Goal, now: number)
	local distance = polylineLength(points)
	squad.State = "Move"
	squad.Goal = goal
	squad.Points = points
	squad.StartTime = now
	-- Cleared here and re-set by _walkTo, so an off-grid leg never inherits the previous
	-- leg's destination (which would make it look re-pathable when it isn't).
	squad.Target = nil
	-- Guests ease away from a standstill and back into one rather than making the time up
	-- with speed, so a leg takes a little longer to walk than its length suggests. Without
	-- that allowance the squad is told to stop while it's still visibly arriving.
	local easing = 2 * Npc.Movement.EaseDistance / self._speed
	squad.EndTime = now
		+ distance / self._speed
		+ (#squad.Members - 1) * SharedNpcService:StaggerFor(squad.Spread or Npc.Movement.MemberSpread)
		+ easing
	squad.StuckSince = nil
	-- On the move, so whatever they were stood in is free for anyone else.
	self._world.ClearSpots(idsOf(squad))
	-- How much room this route has for followers to walk beside the leader; a corridor
	-- squeezes them onto the line itself.
	squad.Spread = SharedNpcService:MeasureSpread(self._world.Grid, points, Npc.FLOOR)
	self:_orderForWalk(squad, points)
	-- Legs that end in a stop hand out standing places up front, so the squad peels off
	-- toward them over the last stretch instead of bunching up and then sorting itself out.
	squad.Spots = if goal == "Action" or goal == "Wander"
		then self:_stand(squad, points[#points], goal)
		else nil

	self._world.Emit({
		Kind = "Move",
		GroupId = self.Id,
		Ids = idsOf(squad),
		Points = flatten(points),
		Y = points[1].Y,
		StartTime = now,
		Speed = self._speed,
		Spread = squad.Spread,
		Spots = squad.Spots and flatten(squad.Spots),
		FanOut = squad.Spots and Npc.Formation.FanOut,
		-- Sent with the walk, not just the stop, so each guest turns to what they came to
		-- see the moment they personally arrive instead of waiting for the whole party.
		FaceX = squad.Spots and squad.Face and squad.Face.X,
		FaceZ = squad.Spots and squad.Face and squad.Face.Z,
	})
end

--[[
Works out where each member of a squad stands around `anchor`, and reserves those places so
other groups arrange themselves around this one rather than inside it.

A squad that walked somewhere to look at something lines up facing it; one that just
stopped rings the spot and talks. Called before the walk that ends there, so the places
travel with the leg and the squad arrives already spread out.
]]
function NpcGroup:_stand(squad: Squad, anchor: Vector3, goal: Goal): { Vector3 }
	-- Face is only set when there's something worth looking at.
	local looking = squad.Face ~= nil
	local facing = if looking then (squad.Face :: Vector3) - anchor else nil
	if (not facing or facing.Magnitude < 1e-3) and squad.Points and #squad.Points > 1 then
		facing = squad.Points[#squad.Points] - squad.Points[#squad.Points - 1]
	end

	local ids = idsOf(squad)
	local mine = {}
	for _, id in ids do
		mine[id] = true
	end

	local world = self._world
	local spots = SharedNpcService:FindStandingSpots(
		world.Grid,
		anchor,
		facing or Vector3.xAxis,
		#squad.Members,
		Npc.FLOOR,
		function(position: Vector3)
			return world.SpotFree(position, mine)
		end,
		if looking then "Viewing" else "Talking"
	)

	-- Match places to members by where each of them will actually walk in, so the party
	-- fans out into the formation rather than swapping past one another to reach it.
	local approach = if squad.Points and #squad.Points > 1
		then squad.Points[#squad.Points] - squad.Points[#squad.Points - 1]
		else facing
	if approach and approach.Magnitude > 1e-3 then
		local arrivals = walkingPositions(squad, anchor, approach.Unit)
		local matched = bestMatching(arrivals, spots)
		local assigned = {}
		for member, index in matched do
			assigned[member] = spots[index]
		end
		spots = assigned
	end

	world.SetSpots(ids, spots)
	return spots
end

--[[Holds a squad in place - performing an action, waiting for a splinter, or stuck.]]
function NpcGroup:_idle(squad: Squad, duration: number, goal: Goal, now: number, face: Vector3?)
	squad.State = "Idle"
	squad.Goal = goal
	squad.StartTime = now
	squad.EndTime = now + duration
	squad.Face = face

	-- Arriving legs already handed out places and the squad walked straight into them, so
	-- there's nothing to re-arrange. Anything else that stops for a real length of time
	-- (waiting out a splinter, stuck) spreads out where it stands. A squad that has gained
	-- or lost members since its places were worked out needs new ones either way - the
	-- list is positional, so a stale one leaves somebody without a place at all.
	local stale = squad.Spots ~= nil and #(squad.Spots :: { Vector3 }) ~= #squad.Members
	if (not squad.Spots or stale) and duration >= Npc.Formation.MinIdle then
		squad.Spots = self:_stand(squad, squad.Position, goal)
	elseif stale then
		squad.Spots = nil
	end

	self._world.Emit({
		Kind = "Idle",
		GroupId = self.Id,
		Ids = idsOf(squad),
		StartTime = now,
		Duration = duration,
		FaceX = face and face.X,
		FaceZ = face and face.Z,
		Spots = squad.Spots and flatten(squad.Spots),
	})
end

--[[Marks a squad as unable to reach anything, so it idles and retries. Guests trapped by
new walls stand around rather than clipping through, and eventually give up (the group
fades out) so they can't accumulate.]]
function NpcGroup:_stall(squad: Squad, now: number)
	if squad.State ~= "Stuck" then
		squad.StuckSince = now
		self:_idle(squad, Npc.Nav.StuckGiveUp, "Wait", now)
		squad.State = "Stuck"
	end
	squad.RetryAt = now + Npc.Nav.StuckRetry
	if now - (squad.StuckSince or now) >= Npc.Nav.StuckGiveUp then
		self:Despawn()
	end
end

-- ===== Target selection =====================================================

--[[Returns the cell a squad currently stands in.]]
function NpcGroup:_cellOf(squad: Squad): SharedNpcService.Cell
	return SharedNpcService:WorldToCell(self._world.Grid, squad.Position)
end

--[[Walks a squad to a destination cell, stalling it if nothing legal connects them.]]
function NpcGroup:_walkTo(squad: Squad, target: SharedNpcService.Cell, goal: Goal, now: number, face: Vector3?): boolean
	local points = SharedNpcService:FindWalk(
		self._world.Grid,
		self:_cellOf(squad),
		target,
		Npc.FLOOR,
		squad.Position,
		self._world.CrowdCost
	)
	if not points or #points < 2 then
		self:_stall(squad, now)
		return false
	end
	squad.Face = face
	self:_move(squad, points, goal, now)
	squad.Target = target
	return true
end

--[[Sends a squad off to its next stop: a placed object if there's one worth seeing,
otherwise somewhere pleasant to stand. Targets are unique per visit - an object this group
has already been to isn't offered again until nothing else is left.]]
function NpcGroup:_beginAction(squad: Squad, now: number)
	local target, face
	if math.random() < Npc.Actions.AttractionBias then
		local placementId
		target, face, placementId = SharedNpcService:PickAttraction(self._world.Grid, self._visited)
		if placementId then
			self._visited[placementId] = true
		end
	end
	target = target or SharedNpcService:PickWander(self._world.Grid)
	if not target then
		self:_stall(squad, now)
		return
	end
	self:_walkTo(squad, target, "Action", now, face)
end

-- ===== Splintering ==========================================================

--[[
Whether this group contains someone who could lead a splinter off on their own.

There is no adult/kid distinction yet, so every guest qualifies. When guests gain ages,
this becomes "at least one adult stays in each half" - a splinter of only kids should
never happen, and neither should leaving kids behind unattended.
]]
local function hasResponsibleMember(_members: { Member }): boolean
	return true
end

--[[Rolls whether a member or two wander off, and sends them on their way if so.]]
function NpcGroup:_maybeSplinter(now: number)
	local main = self._squads[1]
	if #self._squads > 1 or #main.Members < Npc.Splinter.MinGroupSize then
		return
	end
	if not hasResponsibleMember(main.Members) or math.random() >= Npc.Splinter.Chance then
		return
	end

	-- Never take so many that the main squad is left empty.
	local count = math.random(1, math.min(Npc.Splinter.MaxSplinterSize, #main.Members - 1))
	local leaving = {}
	for _ = 1, count do
		table.insert(leaving, table.remove(main.Members, math.random(1, #main.Members)))
	end

	local squad: Squad = {
		Members = leaving,
		State = "Idle",
		Goal = "Wandering",
		StartTime = now,
		EndTime = now,
		Position = main.Position,
		RejoinAt = now + randomRange(Npc.Splinter.DurationRange),
	}
	table.insert(self._squads, squad)
	-- The main squad shrank, so its remaining members need a leg of their own to re-slot
	-- into (the client keys stagger/offset off the id list it was last given), and its
	-- standing places no longer match who is left.
	main.Spots = nil
	self:_idle(main, 0.1, "Wait", now, main.Face)
end

--[[Sends a splinter somewhere inside a randomly chosen distance band - usually just a
few cells away, occasionally right across the plot.]]
function NpcGroup:_wanderSplinter(squad: Squad, now: number)
	local bands = Npc.Splinter.DistanceBands
	local weights = {}
	for _, band in bands do
		table.insert(weights, band.Weight)
	end
	local band = bands[weightedIndex(weights)]

	local grid = self._world.Grid
	local here = self:_cellOf(squad)
	local target = SharedNpcService:PickWander(grid, here, band.MinCells, band.MaxCells)
		or SharedNpcService:PickWander(grid)
	if not target then
		self:_stall(squad, now)
		return
	end
	self:_walkTo(squad, target, "Wander", now)
end

--[[Folds a splinter back into the main squad once it's caught up.]]
function NpcGroup:_merge(squadIndex: number, now: number)
	local main, squad = self._squads[1], self._squads[squadIndex]
	for _, member in squad.Members do
		table.insert(main.Members, member)
	end
	table.remove(self._squads, squadIndex)
	-- The party is a different size now, so its old places no longer describe it.
	main.Spots = nil
	-- One combined leg so the client re-slots everyone into a single clump.
	self:_idle(main, 0.6, "Wait", now)
end

-- ===== Tick =================================================================

--[[Advances a splinter squad: wander on its own, then head back when its timer is up.]]
function NpcGroup:_decideSplinter(squad: Squad, index: number, now: number)
	if squad.Goal == "Rejoin" then
		self:_merge(index, now)
	elseif squad.Goal == "Wander" then
		self:_idle(squad, randomRange(Npc.Splinter.ActionDurationRange), "Wandering", now)
	elseif now >= (squad.RejoinAt or 0) then
		self:_walkTo(squad, self:_cellOf(self._squads[1]), "Rejoin", now)
	else
		self:_wanderSplinter(squad, now)
	end
end

--[[Advances a squad that has just finished whatever it was doing.]]
function NpcGroup:_decide(squad: Squad, index: number, now: number)
	if index > 1 then
		self:_decideSplinter(squad, index, now)
		return
	end

	if squad.Goal == "Exit" then
		self:Despawn()
		return
	end

	-- Finishing a lingering-at-something idle is what actually spends an action, and is
	-- the only moment the group might split up.
	if squad.Goal == "Acting" then
		self._actionsLeft -= 1
		self:_maybeSplinter(now)
	end

	local splinter = self._squads[2]
	if self._actionsLeft <= 0 then
		self._leaving = true
		-- The group can't leave split up, so anyone off on their own is called back now.
		if splinter then
			splinter.RejoinAt = math.min(splinter.RejoinAt or now, now)
		end
	end

	-- Stand still while someone is walking back, so their target doesn't keep moving.
	if splinter and (self._leaving or splinter.Goal == "Rejoin") then
		self:_idle(squad, 1, "Wait", now)
		return
	end

	if self._leaving then
		local entrance = self._world.Entrance
		if squad.Goal == "Leave" then
			-- Through the door and back out of the approach lane, then gone.
			self:_move(squad, { squad.Position, entrance.Outside }, "Exit", now)
		else
			self:_walkTo(squad, entrance.Cell, "Leave", now)
		end
		return
	end

	if squad.Goal == "Action" then
		-- Arrived at the thing: look at it for a while.
		self:_idle(squad, randomRange(Npc.Actions.DurationRange), "Acting", now, squad.Face)
		return
	end

	self:_beginAction(squad, now)
end

--[[Re-checks the line a moving squad is walking, so a wall built across it re-routes
instead of being walked through.]]
function NpcGroup:_revalidate(squad: Squad, now: number)
	if squad.State ~= "Move" or not squad.Points or now < (squad.RevalidateAt or 0) then
		return
	end
	-- Walking in and walking out run down the off-plot approach lane, which has no cells
	-- to be blocked and no target to re-path to. Only grid routes are re-checked.
	if not squad.Target then
		return
	end
	squad.RevalidateAt = now + Npc.Nav.RevalidateInterval

	local remaining = { squad.Position }
	local travelled = (now - squad.StartTime) * Npc.Movement.WalkSpeed
	local covered = 0
	for i = 2, #squad.Points do
		covered += (squad.Points[i] - squad.Points[i - 1]).Magnitude
		if covered > travelled then
			table.insert(remaining, squad.Points[i])
		end
	end

	-- Checked against the tighter radius the line was planned with, so a guest who merely
	-- ends up near a new wall keeps walking instead of re-pathing every half second.
	for i = 2, #remaining do
		local clear = SharedNpcService:IsLineWalkable(
			self._world.Grid,
			remaining[i - 1],
			remaining[i],
			Npc.FLOOR,
			Npc.Nav.BlockedRadius
		)
		if not clear then
			local target = squad.Target
			if target and self:_walkTo(squad, target, squad.Goal, now) then
				return
			end
			-- The approach lane and the exit run off-grid, so they can never be blocked;
			-- anything else with no route left waits it out.
			self:_stall(squad, now)
			return
		end
	end
end

--[[Advances the whole group one simulation tick.]]
function NpcGroup:Tick(now: number)
	if self.Done then
		return
	end

	for index = #self._squads, 1, -1 do
		local squad = self._squads[index]
		if squad.State == "Move" then
			local travelled = (now - squad.StartTime) * Npc.Movement.WalkSpeed
			squad.Position = sampleAt(squad.Points :: { Vector3 }, travelled)
		end

		if squad.State == "Stuck" then
			-- Stay "Stuck" through the retry so the give-up clock keeps running; a
			-- successful re-path is what clears the state (see _move).
			if now >= (squad.RetryAt or 0) then
				if squad.Target then
					self:_walkTo(squad, squad.Target, squad.Goal, now)
				else
					-- Nowhere to retry to (nothing was reachable when they last chose);
					-- pick a fresh destination instead.
					self:_decide(squad, index, now)
				end
			end
		elseif now >= squad.EndTime then
			if squad.State == "Move" and squad.Points then
				squad.Position = squad.Points[#squad.Points]
			end
			self:_decide(squad, index, now)
		else
			self:_revalidate(squad, now)
		end

		if self.Done then
			return
		end
	end
end

--[[Removes every member of the group (fading out client-side).]]
function NpcGroup:Despawn()
	if self.Done then
		return
	end
	self.Done = true
	local ids = {}
	for _, squad in self._squads do
		for _, member in squad.Members do
			table.insert(ids, member.Id)
		end
	end
	self._world.ClearSpots(ids)
	self._world.Emit({ Kind = "Despawn", GroupId = self.Id, Ids = ids })
end

--[[Returns the events a client needs to render this group as it stands right now. Legs
carry their original start time, so a client that joins mid-walk picks it up in progress.]]
function NpcGroup:Snapshot(): { { [string]: any } }
	local events = {}
	for _, squad in self._squads do
		local guests = {}
		for _, member in squad.Members do
			table.insert(guests, { Id = member.Id, Asset = member.Asset })
		end
		table.insert(events, {
			Kind = "Spawn",
			GroupId = self.Id,
			Guests = guests,
			X = squad.Position.X,
			Y = squad.Position.Y,
			Z = squad.Position.Z,
			DirX = self._world.Entrance.Inward.X,
			DirZ = self._world.Entrance.Inward.Z,
		})
		if squad.State == "Move" and squad.Points then
			table.insert(events, {
				Kind = "Move",
				GroupId = self.Id,
				Ids = idsOf(squad),
				Points = flatten(squad.Points),
				Y = squad.Points[1].Y,
				StartTime = squad.StartTime,
				Speed = self._speed,
				Spread = squad.Spread,
				Spots = squad.Spots and flatten(squad.Spots),
				FanOut = squad.Spots and Npc.Formation.FanOut,
			})
		else
			table.insert(events, {
				Kind = "Idle",
				GroupId = self.Id,
				Ids = idsOf(squad),
				StartTime = squad.StartTime,
				Duration = squad.EndTime - squad.StartTime,
				FaceX = squad.Face and squad.Face.X,
				FaceZ = squad.Face and squad.Face.Z,
				Spots = squad.Spots and flatten(squad.Spots),
			})
		end
	end
	return events
end

--[[Total guests still in this group.]]
function NpcGroup:Count(): number
	local count = 0
	for _, squad in self._squads do
		count += #squad.Members
	end
	return count
end

return NpcGroup
