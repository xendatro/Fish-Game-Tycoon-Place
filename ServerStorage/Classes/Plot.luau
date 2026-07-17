--[[
Represents a single plot in workspace.Plots. Wraps the plot's Instance and tracks
who currently owns it. Plots are where players build their aquariums, so this class
is intended to grow (placed objects, saved layout, etc.) - see Serialize below.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Grid = require(ReplicatedStorage.Classes.Grid)

local Plot = {}
Plot.__index = Plot

export type Plot = typeof(setmetatable({} :: {
	Number: number,
	Model: Instance,
	Owner: Player?,
	_grid: Grid.Grid?,
}, Plot))

--[[Creates a Plot wrapping the given plot Instance. Number is the plot's id (its name in workspace.Plots).]]
function Plot.new(model: Instance, number: number): Plot
	local self = setmetatable({}, Plot)
	self.Model = model
	self.Number = number
	self.Owner = nil
	return self
end

--[[Returns the SpawnLocation players are teleported to for this plot.]]
function Plot:GetSpawnLocation(): SpawnLocation?
	return self.Model:FindFirstChild("SpawnLocation")
end

--[[Returns whether the plot is currently unowned.]]
function Plot:IsOpen(): boolean
	return self.Owner == nil
end

--[[Returns the player who currently owns this plot, or nil if open.]]
function Plot:GetOwner(): Player?
	return self.Owner
end

--[[Assigns ownership of the plot to a player.]]
function Plot:Assign(player: Player)
	self.Owner = player
	self.Model:SetAttribute("Owner", player.Name) --idk if this will actually be needed, doing it just in case
end

--[[Clears ownership, making the plot open again.]]
function Plot:Release()
	self.Owner = nil
	self.Model:SetAttribute("Owner", nil)
end

--[[
Returns the CFrame a character should be teleported to so its feet rest on the
spawn's top surface. Uses the humanoid's hip height and root part size so the
character isn't clipped into the ground regardless of rig scale. Yields briefly
for the character's parts to load; returns nil if they never do or there is no spawn.
]]
function Plot:GetSpawnCFrame(character: Model): CFrame?
	local spawn = self:GetSpawnLocation()
	if not spawn then return nil end

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not humanoid or not root then return nil end

	local verticalOffset = spawn.Size.Y / 2 + humanoid.HipHeight + root.Size.Y / 2
	return spawn.CFrame * CFrame.new(0, verticalOffset, 0)
end

--[[Teleports a character to this plot's spawn. No-op if a valid spawn CFrame can't be resolved.]]
function Plot:TeleportCharacter(character: Model)
	local cframe = self:GetSpawnCFrame(character)
	if not cframe then return end
	character:PivotTo(cframe)
end

--[[
Returns this plot's build Grid, lazily creating it from the base "Plot" part on
first access. The Grid is the runtime source of truth for what's been built here;
persistence goes through Grid:Compress() into the owner's profile (handled by
ServerBuildingService).
]]
function Plot:GetGrid(): Grid.Grid
	if not self._grid then
		local basePart = self.Model:FindFirstChild("Plot")
		assert(basePart and basePart:IsA("BasePart"), `Plot {self.Number} has no base 'Plot' part`)
		self._grid = Grid.new(basePart)
	end
	return self._grid
end

--[[Replaces the runtime grid after loading or clearing authoritative build data.]]
function Plot:SetGrid(grid: Grid.Grid)
	self._grid = grid
end

--[[Returns the plot's persistent building state.]]
function Plot:Serialize(): Grid.SaveBlob
	return self:GetGrid():Compress()
end

return Plot
