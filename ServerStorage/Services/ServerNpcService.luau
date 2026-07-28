--[[
ServerNpcService - the authority for guests. It owns one simulation per owned plot:
scheduling arrivals from that plot's popularity, ticking each NpcGroup's decisions, and
broadcasting the resulting Spawn/Move/Idle/Despawn events.

Nothing is rendered here. Guests exist on the server purely as data (an id, an asset name,
and a path leg with a start time); clients clone the models and interpolate the legs
themselves. Clients subscribe to exactly one plot at a time - the one they're standing
nearest - via the Watch remote, and get a snapshot of it on subscribe.

Remotes are authored in Studio under ReplicatedStorage.Communication.Npc:
  Watch  (RemoteFunction) client -> server, "render this plot", returns a snapshot
  Update (RemoteEvent)    server -> subscribed clients, a batch of events
  Debug  (RemoteFunction) client -> server, the temporary debug panel's controls
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Npc = require(ReplicatedStorage.Config.Npc)
local SharedNpcService = require(ReplicatedStorage.Services.SharedNpcService)
local ServerPlotService = require(ServerStorage.Services.ServerPlotService)
local NpcGroup = require(ServerStorage.Classes.NpcGroup)

local ServerNpcService = {}

type Sim = {
	Plot: any,
	Number: number,
	Popularity: number,
	Groups: { [number]: any },
	NextSpawnAt: number,
	NextGroupId: number,
	Events: { { [string]: any } },
	World: NpcGroup.World,
	Grid: any,
	-- Where each stopped guest is stood, so arriving groups can arrange themselves around
	-- the ones already there instead of on top of them.
	Spots: { [number]: Vector3 },
	-- Those spots as occupied cells, for pathing. Dropped whenever Spots changes.
	Crowd: { [string]: boolean }?,
}

local Sims: { [number]: Sim } = {}
-- plot number a player is currently rendering, from their Watch call.
local Watching: { [Player]: number } = {}
local NextGuestId = 1

local Communication = ReplicatedStorage:WaitForChild("Communication")
local NpcRemotes = Communication:WaitForChild("Npc")
local watchRemote = NpcRemotes:WaitForChild("Watch") :: RemoteFunction
local updateRemote = NpcRemotes:WaitForChild("Update") :: RemoteEvent
local debugRemote = NpcRemotes:WaitForChild("Debug") :: RemoteFunction

local NpcAssets = ReplicatedStorage.Assets.NPCs

local function now(): number
	-- Shared clock: legs are stamped with this so clients can place a guest mid-walk.
	return Workspace:GetServerTimeNow()
end

--[[Maps popularity 0-100 onto one of the configured curves.]]
local function curve(atZero: number, atMax: number, popularity: number): number
	return atZero + (atMax - atZero) * math.clamp(popularity, 0, 100) / 100
end

-- ===== Simulation lifecycle =================================================

--[[Refreshes the cached grid/entrance for a plot. ServerBuildingService swaps the whole
Grid object on load and reset, so the sim re-reads it rather than holding one forever.]]
local function syncWorld(sim: Sim)
	local grid = sim.Plot:GetGrid()
	if grid ~= sim.Grid then
		sim.Grid = grid
		sim.World.Grid = grid
		sim.World.Entrance = SharedNpcService:GetEntrance(grid, sim.Plot.Model.Entrance)
	end
end

local function createSim(plot): Sim
	local sim: Sim = {
		Plot = plot,
		Number = plot.Number,
		Popularity = Npc.Popularity.Default,
		Groups = {},
		NextSpawnAt = 0,
		NextGroupId = 1,
		Events = {},
		Grid = nil,
		Spots = {},
		World = {
			Grid = nil,
			Entrance = nil,
			Emit = function() end,
		} :: any,
	}
	sim.World.Emit = function(event)
		table.insert(sim.Events, event)
	end
	sim.World.SetSpots = function(ids: { number }, spots: { Vector3 })
		for index, id in ids do
			sim.Spots[id] = spots[index]
		end
		sim.Crowd = nil
	end
	sim.World.ClearSpots = function(ids: { number })
		for _, id in ids do
			sim.Spots[id] = nil
		end
		sim.Crowd = nil
	end
	--[[Cells someone is stood in cost more to path through, so guests walk around a crowd
	when there's room. Keyed by level too, so a party upstairs doesn't push guests around
	the empty floor below it. Rebuilt lazily, since spots change far less often than paths
	ask.]]
	sim.World.CrowdCost = function(x: number, z: number, floor: number): number
		local crowd = sim.Crowd
		if not crowd then
			crowd = {}
			for _, spot in sim.Spots do
				local cellX, cellZ = sim.Grid:WorldToCell(spot)
				local level = SharedNpcService:FloorAtHeight(sim.Grid, spot.Y)
				crowd[`{level}:{cellX},{cellZ}`] = true
			end
			sim.Crowd = crowd
		end
		return if crowd[`{floor}:{x},{z}`] then Npc.Nav.CrowdPenalty else 1
	end
	sim.World.SpotFree = function(position: Vector3, exclude: { [number]: boolean })
		for id, spot in sim.Spots do
			if not exclude[id] and (spot - position).Magnitude < Npc.Formation.PersonalSpace then
				return false
			end
		end
		return true
	end
	syncWorld(sim)
	sim.NextSpawnAt = now() + curve(Npc.Popularity.IntervalAt0, Npc.Popularity.IntervalAt100, sim.Popularity)
	return sim
end

--[[Total guests currently on a plot.]]
local function guestCount(sim: Sim): number
	local count = 0
	for _, group in sim.Groups do
		count += group:Count()
	end
	return count
end

--[[Picks a random NPC model name. Characters are interchangeable for now - names,
outfits, wealth classes and the adult/kid split all land later.]]
local function randomAsset(): string
	local assets = NpcAssets:GetChildren()
	return assets[math.random(1, #assets)].Name
end

--[[Rolls a party of 1-4 and walks them in through the entrance.]]
function ServerNpcService:SpawnGroup(sim: Sim): boolean
	local size = 0
	local total = 0
	for _, weight in Npc.Group.SizeWeights do
		total += weight
	end
	local roll = math.random() * total
	for index, weight in Npc.Group.SizeWeights do
		roll -= weight
		if roll <= 0 then
			size = index
			break
		end
	end

	local members = {}
	for _ = 1, math.max(1, size) do
		table.insert(members, { Id = NextGuestId, Asset = randomAsset() })
		NextGuestId += 1
	end

	-- TODO(economy): guests pay an entry fee per person here once money is real.
	local group = NpcGroup.new(sim.NextGroupId, members, sim.World)
	sim.Groups[sim.NextGroupId] = group
	sim.NextGroupId += 1
	group:Spawn(now())
	return true
end

--[[Despawns every guest on a plot (plot released, or the debug Clear button).]]
function ServerNpcService:ClearPlot(sim: Sim)
	for _, group in sim.Groups do
		group:Despawn()
	end
	table.clear(sim.Groups)
	table.clear(sim.Spots)
	sim.Crowd = nil
end

-- ===== Replication ==========================================================

--[[Sends a plot's queued events to everyone rendering that plot.]]
local function flush(sim: Sim)
	if #sim.Events == 0 then
		return
	end
	local events = sim.Events
	sim.Events = {}
	for player, plotNumber in Watching do
		if plotNumber == sim.Number then
			updateRemote:FireClient(player, events)
		end
	end
end

-- ===== Tick =================================================================

local function tick()
	local timestamp = now()
	for _, sim in Sims do
		syncWorld(sim)

		local maxGuests = curve(Npc.Popularity.MaxGuestsAt0, Npc.Popularity.MaxGuestsAt100, sim.Popularity)
		if timestamp >= sim.NextSpawnAt then
			if guestCount(sim) < maxGuests then
				ServerNpcService:SpawnGroup(sim)
			end
			local interval = curve(Npc.Popularity.IntervalAt0, Npc.Popularity.IntervalAt100, sim.Popularity)
			local jitter = 1 + (math.random() * 2 - 1) * Npc.Popularity.IntervalJitter
			sim.NextSpawnAt = timestamp + interval * jitter
		end

		for id, group in sim.Groups do
			group:Tick(timestamp)
			if group.Done then
				sim.Groups[id] = nil
			end
		end

		flush(sim)
	end
end

local accumulator = 0
RunService.Heartbeat:Connect(function(delta)
	accumulator += delta
	local step = 1 / Npc.TICK_RATE
	if accumulator < step then
		return
	end
	accumulator = math.min(accumulator - step, step)
	tick()
end)

-- ===== Plot ownership =======================================================

ServerPlotService.PlotAssigned:Connect(function(_player: Player, plotNumber: number)
	local plot = ServerPlotService:GetPlot(plotNumber)
	if plot then
		Sims[plotNumber] = createSim(plot)
	end
end)

ServerPlotService.PlotReleased:Connect(function(_player: Player, plotNumber: number)
	local sim = Sims[plotNumber]
	if not sim then
		return
	end
	ServerNpcService:ClearPlot(sim)
	flush(sim)
	Sims[plotNumber] = nil
end)

Players.PlayerRemoving:Connect(function(player: Player)
	Watching[player] = nil
end)

-- Plots can already be owned if this service loads after players did.
for _, player in Players:GetPlayers() do
	local plot = ServerPlotService:GetPlayerPlot(player)
	if plot and not Sims[plot.Number] then
		Sims[plot.Number] = createSim(plot)
	end
end

-- ===== Remotes ==============================================================

--[[Subscribes a client to one plot and hands back everything needed to render it as it
stands right now. Legs keep their original start times, so a guest mid-walk is picked up
in progress rather than snapping.]]
watchRemote.OnServerInvoke = function(player: Player, plotNumber: any)
	if type(plotNumber) ~= "number" then
		Watching[player] = nil
		return nil
	end

	Watching[player] = plotNumber
	local sim = Sims[plotNumber]
	if not sim then
		return { Events = {}, Popularity = Npc.Popularity.Default }
	end

	local events = {}
	for _, group in sim.Groups do
		for _, event in group:Snapshot() do
			table.insert(events, event)
		end
	end
	return { Events = events, Popularity = sim.Popularity }
end

--[[
TEMPORARY DEBUG CONTROLS - drives the NpcDebug panel (popularity slider, force spawn,
clear). Popularity is dev-set for now; once aquarium appeal computes it, this whole
handler goes away along with the panel.
]]
debugRemote.OnServerInvoke = function(player: Player, action: any, value: any)
	local sim = Sims[Watching[player] or 0]
	if not sim then
		return nil
	end

	-- Any unrecognised action (the panel sends "Query") just reads current state back.
	if action == "Popularity" and type(value) == "number" then
		sim.Popularity = math.clamp(value, 0, 100)
		-- Re-time the pending arrival so the slider feels immediate.
		sim.NextSpawnAt = math.min(
			sim.NextSpawnAt,
			now() + curve(Npc.Popularity.IntervalAt0, Npc.Popularity.IntervalAt100, sim.Popularity)
		)
	elseif action == "Spawn" then
		ServerNpcService:SpawnGroup(sim)
	elseif action == "Clear" then
		ServerNpcService:ClearPlot(sim)
	elseif action == "Stairs" then
		-- Read straight off the authoritative grid, so this reports what the sim actually
		-- routes on rather than anything the client reconstructed.
		syncWorld(sim)
		return { Stairs = if sim.Grid then SharedNpcService:InspectStairs(sim.Grid) else {} }
	end

	flush(sim)
	return { Popularity = sim.Popularity, Guests = guestCount(sim) }
end

return ServerNpcService
