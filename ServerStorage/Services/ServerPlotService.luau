local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Plot = require(ServerStorage.Classes.Plot)

local ServerPlotService = {}

-- All plots in the game, keyed by their number (their name in workspace.Plots).
local plots: {[number]: Plot.Plot} = {}

-- Builds the plot registry from workspace.Plots. Each child is expected to be
-- named with its plot number and contain a Plot part and a SpawnLocation.
local plotsFolder = Workspace:WaitForChild("Plots")
for _, plotModel in plotsFolder:GetChildren() do
	local number = tonumber(plotModel.Name)
	if not number then
		warn(`[ServerPlotService]: Plot '{plotModel.Name}' has a non-numeric name and was skipped`)
		continue
	end
	plots[number] = Plot.new(plotModel, number)
end

--[[Returns the Plot object for the given number, or nil if it doesn't exist.]]
function ServerPlotService:GetPlot(plot: number): Plot.Plot?
	return plots[plot]
end

--[[Returns whether the given plot exists and is currently unowned.]]
function ServerPlotService:IsPlotOpen(plot: number): boolean
	local plotObject = plots[plot]
	return plotObject ~= nil and plotObject:IsOpen()
end

--[[Returns an array of the numbers of every open (unowned) plot.]]
function ServerPlotService:GetOpenPlots(): {number}
	local open = {}
	for number, plotObject in plots do
		if plotObject:IsOpen() then
			table.insert(open, number)
		end
	end
	return open
end

--[[Returns the Plot a player currently owns, or nil if they own none.]]
function ServerPlotService:GetPlayerPlot(player: Player): Plot.Plot?
	for _, plotObject in plots do
		if plotObject:GetOwner() == player then
			return plotObject
		end
	end
	return nil
end

--[[Assigns a specific plot to a player. Warns and no-ops if the plot doesn't exist or is already owned.]]
function ServerPlotService:AssignPlot(player: Player, plot: number)
	local plotObject = plots[plot]
	if not plotObject then
		warn(`[ServerPlotService]: Attempted to assign nonexistent plot {plot} to {player.Name}`)
		return
	end
	if not plotObject:IsOpen() then
		warn(`[ServerPlotService]: Plot {plot} is already owned, cannot assign to {player.Name}`)
		return
	end
	plotObject:Assign(player)
end

--[[Releases whatever plot the player owns, making it open again.]]
function ServerPlotService:ReleasePlot(player: Player)
	local plotObject = ServerPlotService:GetPlayerPlot(player)
	if plotObject then
		plotObject:Release()
	end
end

-- Teleports a player's character to their assigned plot's spawn.
local function teleportToPlot(player: Player, character: Model)
	local plotObject = ServerPlotService:GetPlayerPlot(player)
	if not plotObject then return end
	plotObject:TeleportCharacter(character)
end

local function playerAdded(player: Player)
	local openPlots = ServerPlotService:GetOpenPlots()
	if #openPlots == 0 then
		player:Kick("No plots available - please rejoin.")
		return
	end

	local chosen = openPlots[math.random(1, #openPlots)]
	ServerPlotService:AssignPlot(player, chosen)

	-- Teleport on every spawn (first load and all respawns).
	player.CharacterAdded:Connect(function(character)
		teleportToPlot(player, character)
	end)

	-- Character may already exist if the player loaded before this ran.
	if player.Character then
		task.defer(teleportToPlot, player, player.Character)
	end
end

local function playerRemoving(player: Player)
	ServerPlotService:ReleasePlot(player)
end

for _, player in Players:GetPlayers() do
	task.defer(playerAdded, player)
end
Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(playerRemoving)

return ServerPlotService
