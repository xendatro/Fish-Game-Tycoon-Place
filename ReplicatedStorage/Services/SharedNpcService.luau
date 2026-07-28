--[[
SharedNpcService - the navigation rules for guests, shared so the client can predict or
visualise exactly what the server simulated.

It answers questions about a plot's Grid:
  1. Can a guest stand here?       (cell occupancy, walls, bounds)
  2. How much does this cell cost?  (floor material weight from Config/Materials)
  3. What line gets me from A to B?  (weighted 8-way A*, then string-pulled to a polyline)
  4. Where is there anything worth walking to? (candidate stops - see PickAttraction)

Guests move in three dimensions: the search runs over (x, z, level) nodes, and placed
stairs are PORTALS joining the cell in front of a stair's bottom step to the cell beyond
its top one, a level up. A stair's own cells are never walkable - you can't walk into the
side of a staircase - so a portal spans them rather than routing through them, and the
polyline it contributes is the sloped line guests actually climb.

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
-- A cell on a specific build level. Everything routing-related speaks in these.
export type Node = { X: number, Z: number, Floor: number }
--[[
One step of a found route. `Via` is the polyline walked to REACH this node from the
previous one and is present only where that step was a stair - flat steps are just their
cell centre and need no line of their own.
]]
export type Step = { X: number, Z: number, Floor: number, Via: Climb? }
-- A stair run, as the line walked up it and the level each of its points sits on. A segment
-- whose two ends differ in level is the slope itself.
export type Climb = { Points: { Vector3 }, Floors: { number } }
--[[
A walkable route: the polyline, the level each point sits on, and which segments are inside
a staircase.

`Climbing[i]` covers the segment from point i to point i+1. It is NOT the same question as
"do these two points differ in level" - a climb's line runs cell centre to cell centre
through the stair, so its first and last segments are level while still lying inside the
staircase. Those segments cross the stair's own cells, which are deliberately unwalkable,
so anything re-checking the route against the floor has to skip them or it will reject a
route the guest is walking perfectly well.
]]
export type Route = { Points: { Vector3 }, Floors: { number }, Climbing: { boolean } }
-- Multiplier (>= 1) on the cost of entering a cell, used to steer guests around others.
export type CrowdCost = (x: number, z: number, floor: number) -> number
-- Where guests appear from and vanish to, derived from a plot's Entrance part.
export type Entrance = { Cell: Node, Outside: Vector3, Inward: Vector3 }

-- The best weight any material declares, used to keep the A* heuristic admissible (it
-- must never overestimate, so it assumes the whole route is paved in the best surface).
local BestWeight = Npc.Nav.DefaultWeight
for _, entry in Materials.Floor do
	BestWeight = math.max(BestWeight, entry.Weight or Npc.Nav.DefaultWeight)
end

-- Cheapest a level change can possibly cost, for the same reason: the shortest stair
-- anyone could build runs one cell, and a portal also covers the cell either end of it.
local MinStairCost = 2 * Npc.Nav.StairCost

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

--[[Returns the build level a world height sits on. Levels are fixed-height, so this is
exact for anything standing on one; a guest mid-stair reads as the level below.]]
function SharedNpcService:FloorAtHeight(grid: Grid.Grid, y: number): number
	return math.max(1, math.floor((y - grid.Origin.Y) / Building.WALL_HEIGHT + 1e-4) + 1)
end

--[[
How a placement treats guests, from its Config/Items entry:
  "Solid"    blocks them. Stairs are solid too: their cells are climbed via a portal, not
             walked into from the side.
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

The stair portals are built the first time a query actually asks for one, so the flat
queries (line checks, standing spots) never pay to scan the plot's placements.
]]
type Portal = { To: Node, Via: Climb, Cost: number }
type View = {
	Grid: Grid.Grid,
	Stride: number,
	Band: number,
	Cells: { [number]: boolean },
	Weights: { [number]: number },
	Edges: { [number]: string },
	Portals: { [number]: { Portal } }?,
}

local function makeView(grid: Grid.Grid): View
	return {
		Grid = grid,
		Stride = grid.Width + 2,
		Band = grid.Depth + 2,
		Cells = {},
		Weights = {},
		Edges = {},
	}
end

--[[A single integer identifying one (x, z, level). Edge lookups reach one cell outside the
plot on each axis, which is what the +2 on both strides is for.]]
local function slot(view: View, x: number, z: number, floor: number): number
	return (floor * view.Band + z) * view.Stride + x
end

local function viewCell(view: View, x: number, z: number, floor: number): boolean
	if not view.Grid:IsInBounds(x, z) then
		return false
	end
	local key = slot(view, x, z, floor)
	local cached = view.Cells[key]
	if cached == nil then
		cached = SharedNpcService:IsCellWalkable(view.Grid, x, z, floor)
		view.Cells[key] = cached
	end
	return cached
end

local function viewWeight(view: View, x: number, z: number, floor: number): number
	local key = slot(view, x, z, floor)
	local cached = view.Weights[key]
	if not cached then
		cached = SharedNpcService:GetCellWeight(view.Grid, x, z, floor)
		view.Weights[key] = cached
	end
	return cached
end

--[[Both cells sharing an edge resolve to the same key, so an edge is only ever read once.]]
local function viewEdge(view: View, x: number, z: number, dx: number, dz: number, floor: number): string
	local vertical = dx ~= 0
	local ex = if vertical then (if dx > 0 then x + 1 else x) else x
	local ez = if vertical then z else (if dz > 0 then z + 1 else z)
	local key = slot(view, ex, ez, floor) * 2 + (if vertical then 1 else 0)

	local cached = view.Edges[key]
	if not cached then
		local edgeKey = Grid.edgeKey(if vertical then "V" else "H", ex, ez, floor)
		cached = occupantCollision(view.Grid, view.Grid:GetEdgeOccupant(edgeKey))
		view.Edges[key] = cached
	end
	return cached
end

--[[CanStep against a memo. See CanStep below for the rules.]]
local function viewStep(view: View, x: number, z: number, floor: number, dx: number, dz: number): boolean
	if not viewCell(view, x + dx, z + dz, floor) then
		return false
	end
	if dx == 0 or dz == 0 then
		return viewEdge(view, x, z, dx, dz, floor) ~= "Solid"
	end

	local function corner(midX: number, midZ: number): boolean
		return viewCell(view, midX, midZ, floor)
			and viewEdge(view, x, z, midX - x, midZ - z, floor) == "Ignored"
			and viewEdge(view, midX, midZ, (x + dx) - midX, (z + dz) - midZ, floor) == "Ignored"
	end

	return corner(x + dx, z) and corner(x, z + dz)
end

--[[
Returns whether a guest can step from one cell to an adjacent one ON THE SAME LEVEL.

Diagonals need BOTH of their orthogonal "corners" to be legal in turn, so a guest can't
squeeze through the gap where two walls meet or clip the corner of a placed object. A
doorway may only be crossed head-on: no diagonal may touch one, so guests line up on the
cell in front of a door and step straight through to the cell behind instead of clipping
the frame at an angle. Anything flagged NpcNoCollision imposes neither restriction - as
far as guests are concerned it isn't there.
]]
function SharedNpcService:CanStep(grid: Grid.Grid, x: number, z: number, dx: number, dz: number, floor: number): boolean
	return viewStep(makeView(grid), x, z, floor, dx, dz)
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

-- ===== Stair portals ========================================================

--[[
One placed stair, as geometry.

`Anchor` is its bottom cell and `Last` its top one; `Foot` is the cell in FRONT of the
bottom step and `Head` the cell BEYOND the top one, a level up - the two places a guest
stands either side of it. The line is four points, the two cell centres and the two step
edges between them, because every point on the slope in between lies on the straight line
joining those edges.
]]
type Stair = {
	Anchor: Node,
	Last: Node,
	Foot: Node,
	Head: Node,
	Points: { Vector3 },
	Floors: { number },
	Cost: number,
}

local function stairGeometry(grid: Grid.Grid, placement: any): Stair
	local dx, dz, run = SharedBuildingService:GetStairRun(placement.Name, placement.Rotation)
	local lower = placement.Floor
	local upper = lower + 1

	local footCentre = SharedNpcService:CellToWorld(grid, placement.X - dx, placement.Z - dz, lower)
	local headCentre = SharedNpcService:CellToWorld(grid, placement.X + run * dx, placement.Z + run * dz, upper)
	local half = Vector3.new(dx, 0, dz) * (Building.CELL_SIZE / 2)

	return {
		Anchor = { X = placement.X, Z = placement.Z, Floor = lower },
		Last = { X = placement.X + (run - 1) * dx, Z = placement.Z + (run - 1) * dz, Floor = lower },
		Foot = { X = placement.X - dx, Z = placement.Z - dz, Floor = lower },
		Head = { X = placement.X + run * dx, Z = placement.Z + run * dz, Floor = upper },
		Points = { footCentre, footCentre + half, headCentre - half, headCentre },
		Floors = { lower, lower, upper, upper },
		-- Ground covered is the run plus the half-cell either end of it.
		Cost = (run + 1) * Npc.Nav.StairCost,
	}
end

--[[
Every complete FLIGHT of stairs on a plot: the cell it is entered from, the cell it lets
out onto, and the line climbed between them.

Stairs stacked directly on one another are one flight, not two. That isn't a nicety - it is
the only way a run can climb more than one level: where two of them meet, the cell is the
upper stair's own body and the cell below it carries no ceiling (a stair forbids one), so
the join is nowhere a guest could ever stand. Left as separate portals both ends die and
neither stair is ever walked. Coalescing them is what makes a straight multi-level run work.

A run built with a proper landing between its flights is a different shape and stays two
flights, each with a real cell to arrive on - which is also the only way to get OFF at the
intermediate level.
]]
type Flight = { Foot: Node, Head: Node, Points: { Vector3 }, Floors: { number }, Cost: number }

local function collectFlights(view: View): { Flight }
	local grid = view.Grid
	local stairs: { Stair } = {}
	local byAnchor: { [number]: Stair } = {}

	for _, placement in grid:GetPlacements() do
		local entry = SharedBuildingService:GetEntry(placement.Name)
		if entry and entry.Type == "Stair" then
			local stair = stairGeometry(grid, placement)
			table.insert(stairs, stair)
			byAnchor[slot(view, stair.Anchor.X, stair.Anchor.Z, stair.Anchor.Floor)] = stair
		end
	end

	--[[The stair continuing directly above this one, if any. It has to BEGIN in the very
	cell this one lands in and step off from this one's top cell, which together put its
	first step edge exactly on this one's last - a flush join rather than a near miss.]]
	local function continuation(stair: Stair): Stair?
		local above = byAnchor[slot(view, stair.Head.X, stair.Head.Z, stair.Head.Floor)]
		if above and above.Foot.X == stair.Last.X and above.Foot.Z == stair.Last.Z then
			return above
		end
		return nil
	end

	local continues: { [Stair]: boolean } = {}
	for _, stair in stairs do
		local above = continuation(stair)
		if above then
			continues[above] = true
		end
	end

	local flights: { Flight } = {}
	for _, start in stairs do
		-- Only the bottom of a run starts a flight; the rest are folded into it below.
		if continues[start] then
			continue
		end

		local points = { start.Points[1] }
		local floors = { start.Floors[1] }
		local cost = 0
		local last = start
		local guard = 0

		while true do
			-- Each stair contributes its two step edges. Consecutive stairs meet ON one of
			-- them, so the shared point is written once and the whole run reads as one climb.
			for i = 2, 3 do
				if (points[#points] - last.Points[i]).Magnitude > 1e-3 then
					table.insert(points, last.Points[i])
					table.insert(floors, last.Floors[i])
				end
			end
			cost += last.Cost

			local above = continuation(last)
			guard += 1
			if not above or guard >= #stairs then
				break
			end
			last = above
		end

		table.insert(points, last.Points[4])
		table.insert(floors, last.Floors[4])
		table.insert(flights, { Foot = start.Foot, Head = last.Head, Points = points, Floors = floors, Cost = cost })
	end

	return flights
end

local function reversed<T>(list: { T }): { T }
	local out = {}
	for i = #list, 1, -1 do
		table.insert(out, list[i])
	end
	return out
end

local function buildPortals(view: View): { [number]: { Portal } }
	local portals: { [number]: { Portal } } = {}

	local function connect(from: Node, to: Node, via: Climb, cost: number)
		local key = slot(view, from.X, from.Z, from.Floor)
		local list = portals[key]
		if not list then
			list = {}
			portals[key] = list
		end
		table.insert(list, { To = to, Via = via, Cost = cost })
	end

	for _, flight in collectFlights(view) do
		local foot, head = flight.Foot, flight.Head
		if
			viewCell(view, foot.X, foot.Z, foot.Floor)
			and viewCell(view, head.X, head.Z, head.Floor)
		then
			connect(foot, head, { Points = flight.Points, Floors = flight.Floors }, flight.Cost)
			connect(
				head,
				foot,
				{ Points = reversed(flight.Points), Floors = reversed(flight.Floors) },
				flight.Cost
			)
		end
	end

	return portals
end

--[[
Every flight on a plot and whether guests can actually walk it, for the debug overlay.

A flight that yields no portal is otherwise silent - its stairs render perfectly and are
simply never routed to - and there are only two ways for that to happen, so this names
which. Stacked stairs report as the single flight they are.
]]
export type StairReport = {
	Foot: Node,
	Head: Node,
	Points: { Vector3 },
	Live: boolean,
	Reason: string?,
}

function SharedNpcService:InspectStairs(grid: Grid.Grid): { StairReport }
	local view = makeView(grid)
	local reports: { StairReport } = {}

	for _, flight in collectFlights(view) do
		local foot, head = flight.Foot, flight.Head
		local footOk = viewCell(view, foot.X, foot.Z, foot.Floor)
		local headOk = viewCell(view, head.X, head.Z, head.Floor)

		local reason: string? = nil
		if not footOk and not headOk then
			reason = "neither end is standable - the flight is probably facing the wrong way"
		elseif not footOk then
			reason = "nothing to stand on at the bottom, in front of the first step"
		elseif not headOk then
			reason = "nothing to step off onto at the top: the cell past the last step needs a "
				.. "ceiling below it to walk on, and if that cell is where the BOTTOM is, the "
				.. "model is climbing backwards"
		end

		table.insert(reports, {
			Foot = foot,
			Head = head,
			Points = flight.Points,
			Live = reason == nil,
			Reason = reason,
		})
	end

	return reports
end

--[[The portals leading out of one node, building them on first use.]]
local function viewPortals(view: View, x: number, z: number, floor: number): { Portal }?
	local portals = view.Portals
	if not portals then
		portals = buildPortals(view)
		view.Portals = portals
	end
	return portals[slot(view, x, z, floor)]
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

--[[
Lower bound on the cost of getting from one node to another: the flat distance as if the
whole route were paved in the best surface there is, plus the cheapest possible stair for
each level still to be climbed. Both terms under-estimate, which is what A* needs.
]]
local function heuristic(x: number, z: number, floor: number, to: Node): number
	return octile(x, z, to.X, to.Z) / BestWeight + math.abs(floor - to.Floor) * MinStairCost
end

-- Binary min-heap of open A* nodes, ordered on F. Superseded entries are left in place
-- and skipped when popped (cheaper than finding and re-sorting them).
type HeapNode = { Index: number, X: number, Z: number, Floor: number, F: number }

local function heapPush(heap: { HeapNode }, node: HeapNode)
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

local function heapPop(heap: { HeapNode }): HeapNode?
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
Weighted 8-way A* over walkable cells, plus stair portals between levels. Entering a cell
costs its step length divided by the cell's material weight, so guests drift onto nicer
flooring without it ever becoming a hard wall; a portal costs the ground its stair covers
and is not weighted, since what it crosses is the stair rather than the floor.

Returns the steps from start to goal inclusive, or nil if unreachable.
]]
local function findPath(view: View, from: Node, to: Node, crowd: CrowdCost?): { Step }?
	if not viewCell(view, to.X, to.Z, to.Floor) or not viewCell(view, from.X, from.Z, from.Floor) then
		return nil
	end

	local startIndex = slot(view, from.X, from.Z, from.Floor)
	local goalIndex = slot(view, to.X, to.Z, to.Floor)
	if startIndex == goalIndex then
		return { { X = from.X, Z = from.Z, Floor = from.Floor } }
	end

	-- Indexes are hashes, so the node behind one is remembered rather than unpacked.
	local coords: { [number]: Node } = { [startIndex] = from }
	local cameFrom: { [number]: number } = {}
	local cameVia: { [number]: Climb } = {}
	local gScore: { [number]: number } = { [startIndex] = 0 }
	local closed: { [number]: boolean } = {}
	local open: { HeapNode } = {}
	heapPush(open, {
		Index = startIndex,
		X = from.X,
		Z = from.Z,
		Floor = from.Floor,
		F = heuristic(from.X, from.Z, from.Floor, to),
	})
	local expanded = 0

	--[[Offers one node reachable from `current` at a cost, recording how it was reached.]]
	local function relax(current: HeapNode, node: Node, index: number, cost: number, via: Climb?)
		local tentative = gScore[current.Index] + cost
		if gScore[index] and tentative >= gScore[index] then
			return
		end
		coords[index] = node
		cameFrom[index] = current.Index
		cameVia[index] = via
		gScore[index] = tentative
		heapPush(open, {
			Index = index,
			X = node.X,
			Z = node.Z,
			Floor = node.Floor,
			F = tentative + heuristic(node.X, node.Z, node.Floor, to),
		})
	end

	while #open > 0 do
		local current = heapPop(open) :: HeapNode
		-- A cell can sit in the heap more than once; only its cheapest visit counts.
		if closed[current.Index] then
			continue
		end

		if current.Index == goalIndex then
			local steps: { Step } = {}
			local at = current.Index
			while at do
				local node = coords[at]
				table.insert(steps, 1, { X = node.X, Z = node.Z, Floor = node.Floor, Via = cameVia[at] })
				at = cameFrom[at]
			end
			return steps
		end

		closed[current.Index] = true
		expanded += 1
		if expanded > Npc.Nav.MaxNodes then
			return nil
		end

		for _, offset in NEIGHBOURS do
			local dx, dz = offset[1], offset[2]
			local nx, nz = current.X + dx, current.Z + dz
			local neighbourIndex = slot(view, nx, nz, current.Floor)
			if closed[neighbourIndex] or not viewStep(view, current.X, current.Z, current.Floor, dx, dz) then
				continue
			end

			local step = if dx ~= 0 and dz ~= 0 then Npc.Nav.DiagonalCost else 1
			-- Standing on someone is legal, just expensive, so a crowd gets walked around
			-- when there's room and squeezed past when there isn't.
			local occupied = if crowd then crowd(nx, nz, current.Floor) else 1
			relax(
				current,
				{ X = nx, Z = nz, Floor = current.Floor },
				neighbourIndex,
				step / viewWeight(view, nx, nz, current.Floor) * occupied
			)
		end

		for _, portal in viewPortals(view, current.X, current.Z, current.Floor) or {} do
			local landing = portal.To
			local index = slot(view, landing.X, landing.Z, landing.Floor)
			-- The far end may have been built over since the stair went in.
			if closed[index] or not viewCell(view, landing.X, landing.Z, landing.Floor) then
				continue
			end
			local occupied = if crowd then crowd(landing.X, landing.Z, landing.Floor) else 1
			relax(current, landing, index, portal.Cost * occupied, portal.Via)
		end
	end

	return nil
end

--[[
Returns whether a guest can walk the straight line between two world positions on one
level.

The line is sampled, and at every sample both the cell transitions it crosses AND the
guest's shoulders (`clearance` studs either side of the line) have to be legal. Checking
the centre alone is what let a corner-cutting shortcut pass validation while the guest's
body ploughed through the wall it was cutting past.

The plot boundary is not a wall - guests hug the edge and spawn outside it - so probes
that land off the grid are ignored rather than treated as solid.
]]
local function lineWalkable(
	view: View,
	from: Vector3,
	to: Vector3,
	floor: number,
	clearance: number?
): boolean
	local grid = view.Grid
	local cell = Building.CELL_SIZE
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local distance = delta.Magnitude
	local current = SharedNpcService:WorldToCell(grid, from)

	-- A line that begins inside something solid is not walkable, however it ends. This
	-- matters for the offset lines followers walk, whose start can land in a wall.
	if not viewCell(view, current.X, current.Z, floor) then
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
			if not viewStep(view, current.X, current.Z, floor, stepX, stepZ) then
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
				if not viewStep(view, current.X, current.Z, floor, px - current.X, pz - current.Z) then
					return false
				end
			end
		end
	end
	return true
end

--[[
Turns a route into the polyline a guest actually walks, plus the level each point sits on.
Cell centres alone read as obviously grid-locked, so the flat stretches are string-pulled:
each point is extended to the furthest later point still reachable in a straight line.

Doorways are hard anchors. A shortcut may run up to the cell in front of a door and resume
from the cell behind it, but never across it, so guests square up and walk straight through
rather than skimming the frame diagonally.

Stairs are harder anchors still: a route is CUT at every stair, each flat stretch either
side is pulled on its own level, and the stair's own sloped line is spliced in whole. That
keeps a shortcut from cutting the corner off a staircase, and means a segment whose two
ends report different levels is exactly a climb - which is how everything downstream tells
the two apart.
]]
local function smoothPath(view: View, steps: { Step }, start: Vector3?): Route
	local grid = view.Grid
	local points: { Vector3 } = {}
	local floors: { number } = {}
	local climbing: { boolean } = {}

	local function push(position: Vector3, floor: number)
		local last = points[#points]
		if last and floors[#floors] == floor and (last - position).Magnitude < 1e-3 then
			return
		end
		table.insert(points, position)
		table.insert(floors, floor)
	end

	--[[String-pulls one flat stretch and appends it. `entry` is where the guest actually
	enters the stretch, which is mid-cell when they re-path and the top of a stair when they
	have just climbed one.]]
	local function pull(stretch: { Step }, entry: Vector3?)
		if #stretch == 0 then
			return
		end
		local floor = stretch[1].Floor
		local flat = {}
		for _, step in stretch do
			table.insert(flat, SharedNpcService:CellToWorld(grid, step.X, step.Z, floor))
		end
		if entry then
			flat[1] = Vector3.new(entry.X, flat[1].Y, entry.Z)
		end

		local anchored: { [number]: boolean } = {}
		for i = 2, #stretch do
			if SharedNpcService:IsDoorway(grid, stretch[i - 1], stretch[i], floor) then
				anchored[i - 1] = true
				anchored[i] = true
			end
		end

		push(flat[1], floor)
		local anchor = 1
		while anchor < #flat do
			-- A shortcut can reach the lookahead cap, or the next doorway, whichever is first.
			local limit = math.min(#flat, anchor + Npc.Nav.SmoothLookahead)
			for i = anchor + 1, limit do
				if anchored[i] then
					limit = i
					break
				end
			end

			local furthest = anchor + 1
			for candidate = limit, anchor + 2, -1 do
				if lineWalkable(view, flat[anchor], flat[candidate], floor) then
					furthest = candidate
					break
				end
			end
			push(flat[furthest], floor)
			anchor = furthest
		end
	end

	-- Guests are mid-cell when they re-path, so the very first stretch starts where they
	-- actually stand; later ones start where the stair before them let them off.
	local entry = start
	local stretch: { Step } = {}
	for index = 1, #steps + 1 do
		local via = if index <= #steps then steps[index].Via else nil
		if index > #steps or via then
			pull(stretch, entry)
			stretch = {}
		end
		if via then
			-- The climb's own line, levels and all: its first point is where the flat stretch
			-- just ended and its last is the cell the guest steps off onto, so push dedupes
			-- both joins. A flight spanning several levels simply carries more points.
			local from = math.max(1, #points)
			for i, point in via.Points do
				push(point, via.Floors[i])
			end
			-- Everything from the join into the stairs to the join out of them is inside the
			-- staircase, the level stretches at each end included.
			for i = from, #points - 1 do
				climbing[i] = true
			end
			entry = via.Points[#via.Points]
		end
		if index <= #steps then
			table.insert(stretch, steps[index])
		end
	end

	for i = 1, #points - 1 do
		climbing[i] = climbing[i] == true
	end
	return { Points = points, Floors = floors, Climbing = climbing }
end

--[[
Returns how far to either side of a walked line its followers can spread without walking
through anything. The whole leg has to fit, so one pinch point puts the party in single
file for the length of it, which is what should happen in a one-cell corridor.

A leg with a climb in it is single file outright: a staircase is one model wide, and
nobody walks up one abreast.
]]
local function measureSpread(view: View, points: { Vector3 }, floors: { number }): number
	for i = 2, #points do
		if floors[i] ~= floors[i - 1] then
			return 0
		end
	end

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
				local floor = floors[i - 1]
				local left = lineWalkable(view, from + side, to + side, floor, Npc.Nav.BodyRadius)
				local right = lineWalkable(view, from - side, to - side, floor, Npc.Nav.BodyRadius)
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

function SharedNpcService:FindPath(grid: Grid.Grid, from: Node, to: Node, crowd: CrowdCost?): { Step }?
	return findPath(makeView(grid), from, to, crowd)
end

function SharedNpcService:SmoothPath(grid: Grid.Grid, steps: { Step }, start: Vector3?): Route
	return smoothPath(makeView(grid), steps, start)
end

function SharedNpcService:IsLineWalkable(
	grid: Grid.Grid,
	from: Vector3,
	to: Vector3,
	floor: number,
	clearance: number?
): boolean
	return lineWalkable(makeView(grid), from, to, floor, clearance)
end

function SharedNpcService:MeasureSpread(grid: Grid.Grid, points: { Vector3 }, floors: { number }): number
	return measureSpread(makeView(grid), points, floors)
end

--[[Convenience: path between two nodes and return the route to walk, or nil.]]
function SharedNpcService:FindWalk(
	grid: Grid.Grid,
	from: Node,
	to: Node,
	start: Vector3?,
	crowd: CrowdCost?
): Route?
	local view = makeView(grid)
	local steps = findPath(view, from, to, crowd)
	if not steps then
		return nil
	end
	return smoothPath(view, steps, start)
end

-- ===== Somewhere to go ======================================================

--[[
Picks a placed object worth looking at, skipping any id in `visited`, and returns a free
cell beside it (on its own level) plus the point to face while there, and the placement's
id so the caller can mark it seen.

Placeables carry no interaction data yet, so every content placement counts as something
worth looking at. Once tanks, shops and info centers declare real interaction points -
with their own capacities and durations - this is the function that learns to read them.
]]
function SharedNpcService:PickAttraction(
	grid: Grid.Grid,
	visited: { [number]: boolean }
): (Node?, Vector3?, number?)
	local candidates = {}
	for id, placement in grid:GetPlacements() do
		local entry = SharedBuildingService:GetEntry(placement.Name)
		if entry and entry.Type == "Content" and not visited[id] then
			table.insert(candidates, placement)
		end
	end
	if #candidates == 0 then
		return nil
	end

	local placement = candidates[math.random(1, #candidates)]
	local floor = placement.Floor
	local coords = SharedBuildingService:GetFootprintCoords(placement.Name, placement.X, placement.Z, placement.Rotation)
	local spots = {}
	for _, coord in coords do
		for _, offset in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local x, z = coord[1] + offset[1], coord[2] + offset[2]
			if self:IsCellWalkable(grid, x, z, floor) then
				table.insert(spots, { X = x, Z = z, Floor = floor })
			end
		end
	end
	if #spots == 0 then
		return nil
	end

	return spots[math.random(1, #spots)],
		self:CellToWorld(grid, placement.X, placement.Z, floor),
		placement.Id
end

--[[
Roughly how much walkable area each build level has. The base level is the whole plot;
every level above it exists only where a ceiling below supplies a floor, so its slabs are
its area. Used to weight which level a wander stop is looked for on, so a plot with a small
mezzanine doesn't send half its guests up there.
]]
local function floorAreas(grid: Grid.Grid): { [number]: number }
	local areas: { [number]: number } = { [1] = grid.Width * grid.Depth }
	for _, ceiling in grid:GetCeilings() do
		local floor = ceiling.Floor + 1
		areas[floor] = (areas[floor] or 0) + 1
	end
	return areas
end

--[[Picks a level in proportion to how much of the plot it covers.]]
local function pickFloor(areas: { [number]: number }): number
	local total = 0
	for _, area in areas do
		total += area
	end
	local roll = math.random() * total
	for floor, area in areas do
		roll -= area
		if roll <= 0 then
			return floor
		end
	end
	return 1
end

--[[
Picks an open cell to stop at, sampling a handful and keeping the most attractive surface,
so guests gravitate toward laid flooring instead of stopping on bare grass. `near` plus the
cell-distance bounds restrict the search to a ring (measured across the floorplan, so a
splinter may take its detour upstairs), which is how a splinter keeps its detour inside its
chosen distance band.
]]
function SharedNpcService:PickWander(grid: Grid.Grid, near: Cell?, minCells: number?, maxCells: number?): Node?
	local areas = floorAreas(grid)
	local best, bestScore = nil, -1
	for _ = 1, Npc.Actions.WanderAttempts do
		local floor = pickFloor(areas)
		local x, z = math.random(0, grid.Width - 1), math.random(0, grid.Depth - 1)
		if not self:IsCellWalkable(grid, x, z, floor) then
			continue
		end
		if near then
			local distance = math.max(math.abs(x - near.X), math.abs(z - near.Z))
			if distance < (minCells or 0) or distance > (maxCells or math.huge) then
				continue
			end
		end
		local score = self:GetCellWeight(grid, x, z, floor) * (0.5 + math.random())
		if score > bestScore then
			best, bestScore = { X = x, Z = z, Floor = floor }, score
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
function SharedNpcService:SlotOffset(slotIndex: number, spread: number): (number, number)
	local column = slotIndex % 3
	local sideways = if column == 0 then 0 else (if column == 1 then 1 else -1) * spread
	return sideways, math.floor(slotIndex / 3) * Npc.Formation.PersonalSpace
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
	local flat = Vector3.new(facing.X, 0, facing.Z)
	local forward = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.xAxis
	local view = makeView(grid)
	local taken: { Vector3 } = {}

	local function acceptable(position: Vector3, spacing: number): boolean
		local x, z = grid:WorldToCell(position)
		if not viewCell(view, x, z, floor) then
			return false
		end
		if not lineWalkable(view, anchor, position, floor, Npc.Formation.Clearance) then
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

	local floor = Npc.ENTRY_FLOOR
	local cell = self:WorldToCell(grid, entrance.Position)
	local floorY = grid.Origin.Y + SharedBuildingService:GetLevelBaseOffset(floor)
	local doorway = self:CellToWorld(grid, cell.X, cell.Z, floor)

	return {
		Cell = { X = cell.X, Z = cell.Z, Floor = floor },
		Outside = Vector3.new(
			doorway.X + outward.X * Npc.Movement.ApproachStuds,
			floorY,
			doorway.Z + outward.Z * Npc.Movement.ApproachStuds
		),
		Inward = -outward,
	}
end

return SharedNpcService
