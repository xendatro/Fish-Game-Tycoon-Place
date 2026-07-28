--[[
Tuning for the guest (NPC) system. Everything about how often guests show up, how they
move, how long they linger, and how they wander off is a number in here - the services
themselves hold no balance values.

Only "guests" exist for now. Staff, and the adult/kid split, get their own sections here
when they land.
]]

local Npc = {}

-- Simulation ticks per second on the server. Guests move along server-issued path legs,
-- so this only controls how quickly a squad picks its NEXT thing to do, not smoothness.
Npc.TICK_RATE = 5

-- The build level the entrance sits on. Guests arrive and leave here; anywhere else in the
-- plot is reached by pathing, stairs included (see SharedNpcService's stair portals).
Npc.ENTRY_FLOOR = 1

--[[
Popularity is one 0-100 number per plot driving both arrival cadence and crowd size.
Today the debug slider sets it directly; later it's computed from the aquarium's appeal
(fish, decor, cleanliness) and the slider becomes a dev override of that value.
Both curves interpolate linearly from the At0 value to the At100 value.
]]
Npc.Popularity = {
	Default = 50,
	IntervalAt0 = 26, -- seconds between group arrivals
	IntervalAt100 = 3.5,
	IntervalJitter = 0.35, -- +/- fraction randomly applied to each wait
	MaxGuestsAt0 = 4, -- concurrent guests allowed on one plot
	MaxGuestsAt100 = 42,
}

-- Party size is rolled per arrival; index = number of guests, value = relative weight.
Npc.Group = {
	SizeWeights = { 8, 6, 3, 2 },
}

Npc.Movement = {
	WalkSpeed = 9, -- studs/second
	MemberStagger = 0.3, -- seconds each follower trails the one ahead of it
	-- Studs a follower steps to the side of the leader's line. This is the MOST they
	-- spread; each leg is measured for how much room it actually has (see MeasureSpread)
	-- and narrow routes cut it down, so a party in a one-cell corridor walks single file.
	MemberSpread = 1.5,
	-- Fractions of MemberSpread tried, widest first, when measuring a leg's room.
	SpreadSteps = { 1, 0.5 },
	-- Studs either side of a corner over which followers fold back onto the leader's line.
	-- Their offset is perpendicular to the segment they're on, so at a turn it would
	-- otherwise snap to the new heading and swing them wide through the corner they're
	-- rounding. Folding in also matches how people actually take a corner.
	CornerEase = 2,
	TurnSpeed = 12, -- rendered rotation lerp toward the travel direction
	-- Each party walks at its own slightly different pace (+/- this fraction), so a plot
	-- full of guests doesn't move in lockstep.
	SpeedVariance = 0.12,
	-- Studs over which a squad eases out of a standstill and back into one. Setting off
	-- and stopping at full speed is the tell that something is on rails.
	EaseDistance = 2.5,
	-- How far outside their Entrance part guests appear/vanish.
	ApproachStuds = 16,
}

--[[
Action budget per visit: a guaranteed count, then repeated rolls whose chance decays, so
a long visit is possible but rare. Targets are unique per group (the doc's "3 UNIQUE
things") - a repeat target is only chosen once everything nearby is used up.
]]
Npc.Actions = {
	Guaranteed = 3,
	ExtraChance = 0.55,
	ExtraChanceDecay = 0.55,
	MaxExtra = 5,
	DurationRange = { 4, 9 }, -- seconds spent at one action
	-- Chance to pick a placed object over a random open cell. Placeables have no
	-- interaction data yet, so "attraction" currently means any content placement; real
	-- tanks/shops/info centers will register proper interaction points instead.
	AttractionBias = 0.75,
	-- A wander stop still needs somewhere to stand; give up after this many tries.
	WanderAttempts = 12,
}

--[[
Splintering: occasionally a member or two peels off, does their own thing for a while,
then rejoins. The group cannot leave until everyone is back together.

Distance bands weight HOW FAR the splinter strays - wandering a few cells away is common,
crossing the whole plot is rare.
]]
Npc.Splinter = {
	Chance = 0.12, -- rolled each time the main squad finishes an action
	MinGroupSize = 3, -- below this, splitting would leave someone alone
	MaxSplinterSize = 2,
	DurationRange = { 12, 30 }, -- seconds before they head back
	DistanceBands = {
		{ Weight = 6, MinCells = 2, MaxCells = 6 },
		{ Weight = 3, MinCells = 6, MaxCells = 14 },
		{ Weight = 1, MinCells = 14, MaxCells = 64 },
	},
	-- Splinters keep acting like a mini group while away.
	ActionDurationRange = { 3, 7 },
}

-- Client-side presentation. None of this reaches the simulation.
Npc.Render = {
	FadeIn = 0.35, -- seconds a guest takes to appear
	FadeOut = 0.5, -- ...and to vanish, including when they give up on a blocked path
	-- The stock R15 run animation is authored for roughly this speed; guests' run cycle
	-- is rescaled by WalkSpeed / this so their feet match their pace.
	RunAnimReferenceSpeed = 16,
	-- How often the client re-checks which plot it is standing nearest to.
	WatchInterval = 1,
}

--[[
Where guests stand once they stop somewhere. Walking they follow one line, but standing
around they arrange themselves: the first one takes the spot itself and the rest fan out
beside and behind it, facing the same thing.

Spots are reserved plot-wide while they're stood in, so a second group arriving at the
same tank fills in around the first instead of standing inside it. A party may end up
spanning a couple of tiles - that's fine, as long as nobody is inside the scenery.
]]
Npc.Formation = {
	-- Idles shorter than this keep everyone where they are; only real stops re-arrange.
	-- Low enough that a party reuniting after a split spreads out straight away, high
	-- enough that the momentary holds used to re-slot a squad don't churn the layout.
	MinIdle = 0.3,
	PersonalSpace = 2, -- studs between two guests standing around (bodies just clear)
	Radius = 2.6, -- distance from the spot to the first ring of places beside it
	Rings = 3, -- how far out to keep looking when the good places are taken
	-- Standing still needs less room than walking does, so a guest can stand closer to
	-- the tank they're looking at than a path would ever be planned.
	Clearance = 1,
	-- Places are worked out before the walk and travel with it, so over the last stretch
	-- of the approach each guest peels off the shared line toward their own place. Without
	-- this they all pile onto the destination and then redistribute, which reads as a
	-- stutter on arrival.
	FanOut = 4,
	-- The same thing at the other end: a squad setting off is stood in a formation, not on
	-- the line it's about to walk, so it converges onto it over the first few studs rather
	-- than snapping into single file the instant the leg begins.
	FanIn = 3,
	-- A group stopping for no reason in particular stands in a ring this wide and looks
	-- inward at each other, rather than lining up beside one another facing nothing.
	-- Radius, not gap: a pair ends up twice this far apart, and bigger rings space out
	-- further still if PersonalSpace demands it. Tight spots fall back to standing beside
	-- each other, since every place still has to be somewhere they can actually stand.
	TalkRadius = 2.4,
}

Npc.Nav = {
	-- Cost of entering a cell is StepLength / Materials weight, so an unweighted cell
	-- (and any material that forgets to declare a weight) costs its raw length.
	DefaultWeight = 1,
	DiagonalCost = math.sqrt(2),
	-- Safety valve so a pathological plot can't hang the tick.
	MaxNodes = 3000,
	-- Walked lines are string-pulled after A*; this is the sampling step (in cells) used
	-- to check a straight shortcut stays legal.
	SmoothSampleStep = 0.25,
	-- Guests are not a point: a planned line keeps both shoulders this many studs clear of
	-- anything solid, which is what stops a corner-cutting shortcut clipping a wall. At
	-- 1.4 a party in a one-cell corridor (2 studs of room either side of the centre line)
	-- has no room to walk abreast and falls into single file, which is the intent.
	BodyRadius = 1.4,
	-- The looser radius a leg already being walked is re-checked against. Planning with
	-- the wider one and rejecting with this one stops a guest who ends up slightly close
	-- to a new wall from re-pathing every half second.
	BlockedRadius = 0.5,
	-- Cap on how many cells ahead a shortcut may skip. Keeps string-pulling cheap and
	-- stops one long line check from having to be perfect over half the plot.
	SmoothLookahead = 12,
	-- Cheap re-check of a squad's remaining line, so building a wall across it re-paths.
	RevalidateInterval = 0.5,
	-- Multiplier on the cost of entering a cell someone is already stood in. Heavy enough
	-- that guests noticeably route around a crowd, but it is only a cost - if the only way
	-- through is occupied, they still take it rather than giving up.
	CrowdPenalty = 5,
	-- Walled-in guests idle and retry, then give up and fade out rather than piling up.
	StuckRetry = 2,
	StuckGiveUp = 20,
	-- Multiplier on the ground a stair covers (its run plus the cell either end). Above 1 so
	-- a guest with a choice keeps to the floor they're on, but low enough that anything
	-- genuinely upstairs is still worth the climb.
	StairCost = 1.2,
}

return Npc
