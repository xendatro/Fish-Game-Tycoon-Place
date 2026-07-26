--[[
SharedNpcService - the navigation rules for guests, shared so the client can predict or
visualise exactly what the server simulated.

It answers questions about a plot's Grid:
  1. Can a guest stand here?       (cell occupancy, walls, bounds)
  2. How much does this cell cost?  (floor material weight from Config/Materials)
  3. What line gets me from A to B?  (weighted 8-way A*, then string-pulled to a polyline)
  4. Where is there anything worth walking to? (candidate stops - see PickAttraction)

Like the Grid itself this is a pure function of build data: it renders nothing and owns no
state. It offers candidates but never decides anything - whether a guest goes, when, and
who with is NpcGroup's call.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local Npc = require(ReplicatedStorage.Config.Npc)
local Grid = require(ReplicatedStorage.Classes.Grid)
local SharedBuildingService = require(ReplicatedStorage.Services.SharedBuildingService)

local SharedNpcService = {}

export type Cell = { X: number, Z: number }
-- Multiplier (>= 1) on the cost of entering a cell, used to steer guests around others.
export type CrowdCost = (x: number, z: number) -> number
-- Where guests appear from and vanish to, derived from a plot's Entrance part.
export type Entrance = { Cell: Cell, Outside: Vector3, Inward: Vector3 }

-- The best weight any material declares, used to keep the A* heuristic admissible (it
-- must never overestimate, so it assumes the whole route is paved in the best surface).
local BestWeight = Npc.Nav.DefaultWeight
for _, entry in Materials.Floor do
	BestWeight = math.max(BestWeight, entry.Weight or Npc.Nav.DefaultWeight)
end

-- ===== Cell queries =========================================================

--[[Returns the floor material index a cell renders, following the same inheritance the
build system uses: an explicit painted entry, else grass on the base level, else the
material supplied by the ceiling holding this floor up.]]
local function materialAt(grid: Grid.Grid, x: number, z: number, floor: number): number?
	local entry = grid:GetFloorEntry(x, z, floor)
	if entry then
		return entry.Material
	end
	if floor <= 1 then
		return 1
	end
	local ceiling = grid:GetCeiling(x, z, floor - 1)
	if not ceiling then
		return nil
	end
	local ceilingEntry = Materials.Ceiling[ceiling.Material]
	return ceilingEntry and ceilingEntry.FloorMaterial
end

--[[Returns how strongly guests prefer this cell's surface (higher = more attractive).]]
function SharedNpcService:GetCellWeight(grid: Grid.Grid, x: number, z: number, floor: number): number
	local material = materialAt(grid, x, z, floor)
	local entry = material and Materials.Floor[material]
	return (entry and entry.Weight) or Npc.Nav.DefaultWeight
end

--[[
How a placement treats guests, from its Config/Items entry:
  "Solid"    blocks them.
  "Doorway"  CanWalkThrough - they may pass, but only straight through it (see CanStep).
  "Ignored"  NpcNoCollision - not there as far as guests are concerned. Hangers hang from
             the ceiling, so they never block the floor they happen to be indexed on.
]]
local function collision(name: string): "Solid" | "Doorway" | "Ignored"
	local entry = SharedBuildingService:GetEntry(name)
	if not entry or entry.NpcNoCollision == true or entry.Type == "Hanger" then
		return "Ignored"
	elseif entry.CanWalkThrough == true then
		return "Doorway"
	end
	return "Solid"
end

--[[Returns how the placement occupying a key (if any) treats guests.]]
local function occupantCollision(grid: Grid.Grid, id: number?): "Solid" | "Doorway" | "Ignored"
	if not id then
		return "Ignored"
	end
	local placement = grid:GetPlacement(id)
	if not placement then
		return "Ignored"
	end
	return collision(placement.Name)
end

--[[Returns whether a guest can stand in a cell: inside the plot, standing on something,
and not filled by a placement.]]
function SharedNpcService:IsCellWalkable(grid: Grid.Grid, x: number, z: number, floor: number): boolean
	if not grid:IsInBounds(x, z) then
		return false
	end
	-- Upper levels only exist where a ceiling below supplies a floor to walk on.
	if floor > 1 and not materialAt(grid, x, z, floor) then
		return false
	end
	return occupantCollision(grid, grid:GetCellOccupant(x, z, floor)) ~= "Solid"
end

--[[Returns how the wall edge between two orthogonally adjacent cells treats guests.
Edges are keyed by the higher-coordinate cell, matching Grid.edgeKey.]]
local function edgeCollision(
	grid: Grid.Grid,
	x: number,
	z: number,
	dx: number,
	dz: number,
	floor: number
): "Solid" | "Doorway" | "Ignored"
	local key
	if dx ~= 0 then
		key = Grid.edgeKey("V", if dx > 0 then x + 1 else x, z, floor)
	else
		key = Grid.edgeKey("H", x, if dz > 0 then z + 1 else z, floor)
	end
	return occupantCollision(grid, grid:GetEdgeOccupant(key))
end

--[[Returns whether stepping between two adjacent cells passes through a doorway.]]
function SharedNpcService:IsDoorway(grid: Grid.Grid, from: Cell, to: Cell, floor: number): boolean
	return edgeCollision(grid, from.X, from.Z, to.X - from.X, to.Z - from.Z, floor) == "Doorway"
end

-- ===== Query memo ===========================================================

--[[
A scratch table of answers for one query.

Every Grid lookup builds a string key, and a single search asks the same question about
the same cell or edge a dozen times over (each cell is a neighbour of eight others, and
every diagonal re-checks its two corners), so the answers are memoised. A View lives only
for the duration of one call, which is why it can never go stale against a plot someone
is building on.
]]
type View = {
	Grid: Grid.Grid,
	Floor: number,
	Stride: number,
	Cells: { [number]: boolean },
	Weights: { [number]: number },
	Edges: { [number]: string },
}

local function makeView(grid: Grid.Grid, floor: number): View
	return { Grid = grid, Floor = floor, Stride = grid.Width + 2, Cells = {}, Weights = {}, Edges = {} }
end

local function viewCell(view: View, x: number, z: number): boolean
	if not view.Grid:IsInBounds(x, z) then
		return false
	end
	local key = z * view.Stride + x
	local cached = view.Cells[key]
	if cached == nil then
		cached = SharedNpcService:IsCellWalkable(view.Grid, x, z, view.Floor)
		view.Cells[key] = cached
	end
	return cached
end

local function viewWeight(view: View, x: number, z: number): number
	local key = z * view.Stride + x
	local cached = view.Weights[key]
	if not cached then
		cached = SharedNpcService:GetCellWeight(view.Grid, x, z, view.Floor)
		view.Weights[key] = cached
	end
	return cached
end

--[[Both cells sharing an edge resolve to the same slot, so an edge is only ever read once.]]
local function viewEdge(view: View, x: number, z: number, dx: number, dz: number): string
	local vertical = dx ~= 0
	local ex = if vertical then (if dx > 0 then x + 1 else x) else x
	local ez = if vertical then z else (if dz > 0 then z + 1 else z)
	local key = ((if vertical then 1 else 0) * (view.Grid.Depth + 2) + ez) * view.Stride + ex

	local cached = view.Edges[key]
	if not cached then
		local edgeKey = Grid.edgeKey(if vertical then "V" else "H", ex, ez, view.Floor)
		cached = occupantCollision(view.Grid, view.Grid:GetEdgeOccupant(edgeKey))
		view.Edges[key] = cached
	end
	return cached
end

--[[CanStep against a memo. See CanStep below for the rules.]]
local function viewStep(view: View, x: number, z: number, dx: number, dz: number): boolean
	if not viewCell(view, x + dx, z + dz) then
		return false
	end
	if dx == 0 or dz == 0 then
		return viewEdge(view, x, z, dx, dz) ~= "Solid"
	end

	local function corner(midX: number, midZ: number): boolean
		return viewCell(view, midX, midZ)
			and viewEdge(view, x, z, midX - x, midZ - z) == "Ignored"
			and viewEdge(view, midX, midZ, (x + dx) - midX, (z + dz) - midZ) == "Ignored"
	end

	return corner(x + dx, z) and corner(x, z + dz)
end

--[[
Returns whether a guest can step from one cell to an adjacent one.

Diagonals need BOTH of their orthogonal "corners" to be legal in turn, so a guest can't
squeeze through the gap where two walls meet or clip the corner of a placed object. A
doorway may only be crossed head-on: no diagonal may touch one, so guests line up on the
cell in front of a door and step straight through to the cell behind instead of clipping
the frame at an angle. Anything flagged NpcNoCollision imposes neither restriction - as
far as guests are concerned it isn't there.
]]
function SharedNpcService:CanStep(grid: Grid.Grid, x: number, z: number, dx: number, dz: number, floor: number): boolean
	return viewStep(makeView(grid, floor), x, z, dx, dz)
end

--[[Returns the world position a guest stands at for a cell, on the floor surface.]]
function SharedNpcService:CellToWorld(grid: Grid.Grid, x: number, z: number, floor: number): Vector3
	local centre = grid:GetCellCenter(x, z)
	return Vector3.new(centre.X, grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(floor), centre.Z)
end

--[[Returns the cell a world position falls in, clamped into the plot.]]
function SharedNpcService:WorldToCell(grid: Grid.Grid, position: Vector3): Cell
	local x, z = grid:WorldToCell(position)
	return { X = math.clamp(x, 0, grid.Width - 1), Z = math.clamp(z, 0, grid.Depth - 1) }
end

-- ===== Pathfinding ==========================================================

local NEIGHBOURS = {
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

--[[Octile distance in cells - the shortest possible 8-way route ignoring obstacles.]]
local function octile(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = math.abs(ax - bx), math.abs(az - bz)
	return math.max(dx, dz) + (Npc.Nav.DiagonalCost - 1) * math.min(dx, dz)
end

-- Binary min-heap of open A* nodes, ordered on F. Superseded entries are left in place
-- and skipped when popped (cheaper than finding and re-sorting them).
type Node = { Index: number, X: number, Z: number, F: number }

local function heapPush(heap: { Node }, node: Node)
	table.insert(heap, node)
	local child = #heap
	while child > 1 do
		local parent = child // 2
		if heap[parent].F <= heap[child].F then
			break
		end
		heap[parent], heap[child] = heap[child], heap[parent]
		child = parent
	end
end

local function heapPop(heap: { Node }): Node?
	local count = #heap
	if count == 0 then
		return nil
	end
	local top = heap[1]
	heap[1] = heap[count]
	heap[count] = nil
	count -= 1

	local parent = 1
	while true do
		local left, right = parent * 2, parent * 2 + 1
		local smallest = parent
		if left <= count and heap[left].F < heap[smallest].F then
			smallest = left
		end
		if right <= count and heap[right].F < heap[smallest].F then
			smallest = right
		end
		if smallest == parent then
			break
		end
		heap[parent], heap[smallest] = heap[smallest], heap[parent]
		parent = smallest
	end
	return top
end

--[[
Weighted 8-way A* over walkable cells. Entering a cell costs its step length divided by
the cell's material weight, so guests drift onto nicer flooring without it ever becoming
a hard wall. Returns the cell list from start to goal inclusive, or nil if unreachable.
]]
local function findPath(view: View, from: Cell, to: Cell, crowd: CrowdCost?): { Cell }?
	if not viewCell(view, to.X, to.Z) or not viewCell(view, from.X, from.Z) then
		return nil
	end

	local width = view.Grid.Width
	local function index(x: number, z: number): number
		return z * width + x
	end

	local startIndex, goalIndex = index(from.X, from.Z), index(to.X, to.Z)
	if startIndex == goalIndex then
		return { { X = from.X, Z = from.Z } }
	end

	local cameFrom: { [number]: number } = {}
	local gScore: { [number]: number } = { [startIndex] = 0 }
	local closed: { [number]: boolean } = {}
	local open: { Node } = {}
	heapPush(open, { Index = startIndex, X = from.X, Z = from.Z, F = octile(from.X, from.Z, to.X, to.Z) / BestWeight })
	local expanded = 0

	while #open > 0 do
		local current = heapPop(open) :: Node
		-- A cell can sit in the heap more than once; only its cheapest visit counts.
		if closed[current.Index] then
			continue
		end

		if current.Index == goalIndex then
			local cells = {}
			local at = current.Index
			while at do
				table.insert(cells, 1, { X = at % width, Z = math.floor(at / width) })
				at = cameFrom[at]
			end
			return cells
		end

		closed[current.Index] = true
		expanded += 1
		if expanded > Npc.Nav.MaxNodes then
			return nil
		end

		for _, offset in NEIGHBOURS do
			local dx, dz = offset[1], offset[2]
			local nx, nz = current.X + dx, current.Z + dz
			local neighbourIndex = index(nx, nz)
			if closed[neighbourIndex] or not viewStep(view, current.X, current.Z, dx, dz) then
				continue
			end

			local step = if dx ~= 0 and dz ~= 0 then Npc.Nav.DiagonalCost else 1
			-- Standing on someone is legal, just expensive, so a crowd gets walked around
			-- when there's room and squeezed past when there isn't.
			local occupied = if crowd then crowd(nx, nz) else 1
			local tentative = gScore[current.Index] + step / viewWeight(view, nx, nz) * occupied
			if gScore[neighbourIndex] and tentative >= gScore[neighbourIndex] then
				continue
			end

			cameFrom[neighbourIndex] = current.Index
			gScore[neighbourIndex] = tentative
			heapPush(open, {
				Index = neighbourIndex,
				X = nx,
				Z = nz,
				F = tentative + octile(nx, nz, to.X, to.Z) / BestWeight,
			})
		end
	end

	return nil
end

--[[
Returns whether a guest can walk the straight line between two world positions.

The line is sampled, and at every sample both the cell transitions it crosses AND the
guest's shoulders (`clearance` studs either side of the line) have to be legal. Checking
the centre alone is what let a corner-cutting shortcut pass validation while the guest's
body ploughed through the wall it was cutting past.

The plot boundary is not a wall - guests hug the edge and spawn outside it - so probes
that land off the grid are ignored rather than treated as solid.
]]
local function lineWalkable(view: View, from: Vector3, to: Vector3, clearance: number?): boolean
	local grid = view.Grid
	local cell = Building.CELL_SIZE
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local distance = delta.Magnitude
	local current = SharedNpcService:WorldToCell(grid, from)

	-- A line that begins inside something solid is not walkable, however it ends. This
	-- matters for the offset lines followers walk, whose start can land in a wall.
	if not viewCell(view, current.X, current.Z) then
		return false
	end

	local width = clearance or Npc.Nav.BodyRadius
	local side = Vector3.zero
	if distance > 1e-4 then
		side = Vector3.new(-delta.Z, 0, delta.X) / distance * width
	end

	local steps = math.max(1, math.ceil(distance / (cell * Npc.Nav.SmoothSampleStep)))
	for i = 0, steps do
		local sample = from + delta * (i / steps)
		local x, z = grid:WorldToCell(sample)
		local dx, dz = x - current.X, z - current.Z
		-- Sampling can skip a cell on a shallow diagonal; walk the difference one axis at
		-- a time so every transition is actually validated.
		while dx ~= 0 or dz ~= 0 do
			local stepX, stepZ = math.sign(dx), math.sign(dz)
			if not viewStep(view, current.X, current.Z, stepX, stepZ) then
				return false
			end
			current = { X = current.X + stepX, Z = current.Z + stepZ }
			dx -= stepX
			dz -= stepZ
		end

		-- Both shoulders have to be somewhere the guest could have stepped to.
		for _, probe in { sample + side, sample - side } do
			local px, pz = grid:WorldToCell(probe)
			if (px ~= current.X or pz ~= current.Z) and grid:IsInBounds(px, pz) then
				if not viewStep(view, current.X, current.Z, px - current.X, pz - current.Z) then
					return false
				end
			end
		end
	end
	return true
end

--[[
Turns an A* cell list into the polyline a guest actually walks. Cell centres alone read
as obviously grid-locked, so this string-pulls them: each point is extended to the
furthest later point still reachable in a straight line.

Doorways are hard anchors. A shortcut may run up to the cell in front of a door and
resume from the cell behind it, but never across it, so guests square up and walk straight
through rather than skimming the frame diagonally.
]]
local function smoothPath(view: View, cells: { Cell }, start: Vector3?): { Vector3 }
	local grid, floor = view.Grid, view.Floor
	local points = {}
	for _, cell in cells do
		table.insert(points, SharedNpcService:CellToWorld(grid, cell.X, cell.Z, floor))
	end
	-- Guests are mid-cell when they re-path, so the line starts where they actually stand.
	if start then
		points[1] = Vector3.new(start.X, points[1].Y, start.Z)
	end

	local anchored: { [number]: boolean } = {}
	for i = 2, #cells do
		if SharedNpcService:IsDoorway(grid, cells[i - 1], cells[i], floor) then
			anchored[i - 1] = true
			anchored[i] = true
		end
	end

	local smoothed = { points[1] }
	local anchor = 1
	while anchor < #points do
		-- A shortcut can reach the lookahead cap, or the next doorway, whichever is first.
		local limit = math.min(#points, anchor + Npc.Nav.SmoothLookahead)
		for i = anchor + 1, limit do
			if anchored[i] then
				limit = i
				break
			end
		end

		local furthest = anchor + 1
		for candidate = limit, anchor + 2, -1 do
			if lineWalkable(view, points[anchor], points[candidate]) then
				furthest = candidate
				break
			end
		end
		table.insert(smoothed, points[furthest])
		anchor = furthest
	end
	return smoothed
end

--[[
Returns how far to either side of a walked line its followers can spread without walking
through anything. The whole leg has to fit, so one pinch point puts the party in single
file for the length of it, which is what should happen in a one-cell corridor.
]]
local function measureSpread(view: View, points: { Vector3 }): number
	for _, fraction in Npc.Movement.SpreadSteps do
		local spread = Npc.Movement.MemberSpread * fraction
		local fits = true
		for i = 2, #points do
			local from, to = points[i - 1], points[i]
			local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
			local length = delta.Magnitude
			if length > 1e-4 then
				-- Test the lines the followers actually walk, not the leader's with a
				-- wider margin: a follower stepped sideways crosses a wall in a DIFFERENT
				-- cell than the leader does, which is how they were slipping past the
				-- frame of a door the leader went cleanly through.
				local side = Vector3.new(-delta.Z, 0, delta.X) / length * spread
				local left = lineWalkable(view, from + side, to + side, Npc.Nav.BodyRadius)
				local right = lineWalkable(view, from - side, to - side, Npc.Nav.BodyRadius)
				if not (left and right) then
					fits = false
					break
				end
			end
		end
		if fits then
			return spread
		end
	end
	return 0
end

-- ===== Public query entry points ============================================
-- Each builds one memo and hands it to the internals above; FindWalk shares a single memo
-- across the search and the smoothing, which is the common path.

function SharedNpcService:FindPath(grid: Grid.Grid, from: Cell, to: Cell, floor: number, crowd: CrowdCost?): { Cell }?
	return findPath(makeView(grid, floor), from, to, crowd)
end

function SharedNpcService:SmoothPath(grid: Grid.Grid, cells: { Cell }, floor: number, start: Vector3?): { Vector3 }
	return smoothPath(makeView(grid, floor), cells, start)
end

function SharedNpcService:IsLineWalkable(
	grid: Grid.Grid,
	from: Vector3,
	to: Vector3,
	floor: number,
	clearance: number?
): boolean
	return lineWalkable(makeView(grid, floor), from, to, clearance)
end

function SharedNpcService:MeasureSpread(grid: Grid.Grid, points: { Vector3 }, floor: number): number
	return measureSpread(makeView(grid, floor), points)
end

--[[Convenience: path between two cells and return the walkable polyline, or nil.]]
function SharedNpcService:FindWalk(
	grid: Grid.Grid,
	from: Cell,
	to: Cell,
	floor: number,
	start: Vector3?,
	crowd: CrowdCost?
): { Vector3 }?
	local view = makeView(grid, floor)
	local cells = findPath(view, from, to, crowd)
	if not cells then
		return nil
	end
	return smoothPath(view, cells, start)
end

-- ===== Somewhere to go ======================================================

--[[
Picks a placed object worth looking at, skipping any id in `visited`, and returns a free
cell beside it plus the point to face while there (and the placement's id, so the caller
can mark it seen).

Placeables carry no interaction data yet, so every content placement counts as something
worth looking at. Once tanks, shops and info centers declare real interaction points -
with their own capacities and durations - this is the function that learns to read them.
]]
function SharedNpcService:PickAttraction(
	grid: Grid.Grid,
	visited: { [number]: boolean }
): (Cell?, Vector3?, number?)
	local candidates = {}
	for id, placement in grid:GetPlacements() do
		local entry = SharedBuildingService:GetEntry(placement.Name)
		if placement.Floor == Npc.FLOOR and entry and entry.Type == "Content" and not visited[id] then
			table.insert(candidates, placement)
		end
	end
	if #candidates == 0 then
		return nil
	end

	local placement = candidates[math.random(1, #candidates)]
	local coords = SharedBuildingService:GetFootprintCoords(placement.Name, placement.X, placement.Z, placement.Rotation)
	local spots = {}
	for _, coord in coords do
		for _, offset in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local x, z = coord[1] + offset[1], coord[2] + offset[2]
			if self:IsCellWalkable(grid, x, z, Npc.FLOOR) then
				table.insert(spots, { X = x, Z = z })
			end
		end
	end
	if #spots == 0 then
		return nil
	end

	return spots[math.random(1, #spots)],
		self:CellToWorld(grid, placement.X, placement.Z, Npc.FLOOR),
		placement.Id
end

--[[
Picks an open cell to stop at, sampling a handful and keeping the most attractive surface,
so guests gravitate toward laid flooring instead of stopping on bare grass. `near` plus the
cell-distance bounds restrict the search to a ring, which is how a splinter keeps its
detour inside its chosen distance band.
]]
function SharedNpcService:PickWander(grid: Grid.Grid, near: Cell?, minCells: number?, maxCells: number?): Cell?
	local best, bestScore = nil, -1
	for _ = 1, Npc.Actions.WanderAttempts do
		local x, z = math.random(0, grid.Width - 1), math.random(0, grid.Depth - 1)
		if not self:IsCellWalkable(grid, x, z, Npc.FLOOR) then
			continue
		end
		if near then
			local distance = math.max(math.abs(x - near.X), math.abs(z - near.Z))
			if distance < (minCells or 0) or distance > (maxCells or math.huge) then
				continue
			end
		end
		local score = self:GetCellWeight(grid, x, z, Npc.FLOOR) * (0.5 + math.random())
		if score > bestScore then
			best, bestScore = { X = x, Z = z }, score
		end
	end
	return best
end

-- ===== Walking order ========================================================

--[[
Where a follower walks relative to the leader: how far to the side of the line, and how far
back along it. Sideways room is measured per leg (see MeasureSpread), so a corridor puts
the party in single file.

Only three abreast, then the next row trails a body's length behind. The server uses this
to work out who arrives where, the client to actually place them.
]]
function SharedNpcService:SlotOffset(slot: number, spread: number): (number, number)
	local column = slot % 3
	local sideways = if column == 0 then 0 else (if column == 1 then 1 else -1) * spread
	return sideways, math.floor(slot / 3) * Npc.Formation.PersonalSpace
end

--[[
How long each member waits behind the one ahead before setting off.

The less room a route has to walk abreast, the longer the gap: a party that has to go
single file needs its spacing front-to-back, since it has none side-to-side. Both sides
compute this from the leg's measured spread so their timing agrees.
]]
function SharedNpcService:StaggerFor(spread: number): number
	local narrow = 1 - math.clamp(spread / Npc.Movement.MemberSpread, 0, 1)
	return Npc.Movement.MemberStagger * (1 + narrow)
end

-- ===== Standing around ======================================================

-- Where to look for room, in degrees off the direction the group is facing: beside first,
-- then behind, then in front (which is usually into whatever they came to look at, so it
-- rarely survives validation), then directly behind.
local FORMATION_ANGLES = { 90, -90, 140, -140, 55, -55, 180 }

--[[
Lays out where each member of a group stands when it stops.

"Viewing" is for a group that came to look at something: the first spot is the place
itself and the rest fan out beside and behind it, so nobody stands between the group and
what they came to see. "Talking" is for a group stopping for no particular reason: they
ring the spot and (client-side) turn inward, which reads as a conversation instead of four
people staring off in different directions.

Every place is checked to be standable, reachable from the anchor without clipping a wall,
and clear of both the spots already handed out here and - through `isFree` - the ones other
groups are stood in. If nothing legal is left a guest doubles up on the anchor rather than
standing in scenery.
]]
function SharedNpcService:FindStandingSpots(
	grid: Grid.Grid,
	anchor: Vector3,
	facing: Vector3,
	count: number,
	floor: number,
	isFree: ((Vector3) -> boolean)?,
	style: ("Viewing" | "Talking")?
): { Vector3 }
	local forward = if facing.Magnitude > 1e-4 then facing.Unit else Vector3.xAxis
	local view = makeView(grid, floor)
	local taken: { Vector3 } = {}

	local function acceptable(position: Vector3, spacing: number): boolean
		local x, z = grid:WorldToCell(position)
		if not viewCell(view, x, z) then
			return false
		end
		if not lineWalkable(view, anchor, position, Npc.Formation.Clearance) then
			return false
		end
		for _, other in taken do
			if (other - position).Magnitude < spacing then
				return false
			end
		end
		return isFree == nil or isFree(position)
	end

	-- A conversation wants a ring with a gap in the middle; anything else starts from the
	-- spot itself. The ideal ring place is tried first and the generic search below picks
	-- up whoever couldn't have theirs.
	local ideal: { Vector3 } = {}
	if style == "Talking" and count > 1 then
		local base = math.atan2(forward.Z, forward.X)
		local radius = math.max(Npc.Formation.TalkRadius, Npc.Formation.PersonalSpace / (2 * math.sin(math.pi / count)))
		for index = 1, count do
			local angle = base + (index - 1) / count * math.pi * 2
			table.insert(ideal, anchor + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius)
		end
	end

	local spots = {}
	for member = 1, count do
		local chosen = nil
		local preferred = ideal[member]
		if preferred and acceptable(preferred, Npc.Formation.PersonalSpace) then
			chosen = preferred
		elseif #taken == 0 and not preferred and acceptable(anchor, Npc.Formation.PersonalSpace) then
			chosen = anchor
		end

		-- Somewhere with elbow room first; if the place is that busy, settle for standing
		-- closer to each other rather than doubling up on one spot.
		for _, spacing in { Npc.Formation.PersonalSpace, Npc.Formation.PersonalSpace * 0.6 } do
			for ring = 1, Npc.Formation.Rings do
				if chosen then
					break
				end
				local radius = Npc.Formation.Radius * ring
				for _, degrees in FORMATION_ANGLES do
					local direction = CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(forward)
					local candidate = anchor + direction * radius
					if acceptable(candidate, spacing) then
						chosen = candidate
						break
					end
				end
			end
		end

		chosen = chosen or anchor
		table.insert(taken, chosen)
		table.insert(spots, chosen)
	end
	return spots
end

-- ===== Entrance =============================================================

--[[
Resolves a plot's Entrance part into the cell guests walk in through, the off-plot point
they appear at, and the direction that faces into the plot. The facing is derived from
where the part sits relative to the plot rather than its rotation, so the part can be
moved to any edge (or re-modelled) without the sim caring.
]]
function SharedNpcService:GetEntrance(grid: Grid.Grid, entrance: BasePart): Entrance
	local centre = grid.Origin + Vector3.new(grid.Width * Building.CELL_SIZE / 2, 0, grid.Depth * Building.CELL_SIZE / 2)
	local outward = Vector3.new(entrance.Position.X - centre.X, 0, entrance.Position.Z - centre.Z)
	outward = if math.abs(outward.X) >= math.abs(outward.Z)
		then Vector3.new(math.sign(outward.X), 0, 0)
		else Vector3.new(0, 0, math.sign(outward.Z))

	local cell = self:WorldToCell(grid, entrance.Position)
	local floorY = grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(Npc.FLOOR)
	local doorway = self:CellToWorld(grid, cell.X, cell.Z, Npc.FLOOR)

	return {
		Cell = cell,
		Outside = Vector3.new(
			doorway.X + outward.X * Npc.Movement.ApproachStuds,
			floorY,
			doorway.Z + outward.Z * Npc.Movement.ApproachStuds
		),
		Inward = -outward,
	}
end

return SharedNpcService
