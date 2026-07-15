local RunService = game:GetService("RunService")

-- Types
export type NumberSequence2D = {
	X: NumberSequence,
	Y: NumberSequence
}

export type Particle = {
	Element: GuiObject,
	Speed: Vector2,
	Position: Vector2,
	SpreadAngle: number,
	RotSpeed: number,
	Acceleration: Vector2,
	Size: NumberSequence2D,
	Transparency: NumberSequence,
	Color: ColorSequence,
	Age: number,
	maxAge: number,
	isDead: boolean,
	Canvas: CanvasGroup,
	Update: (self: Particle, delta: number) -> (),
	Destroy: (self: Particle) -> ()
}

-- Utility Functions
local function Rotate(v: Vector2, degrees: number)
	local sin = math.sin(math.rad(degrees))
	local cos = math.cos(math.rad(degrees))
	return Vector2.new((cos * v.X) - (sin * v.Y), (sin * v.X) + (cos * v.Y))
end

local function evalCS(cs, t)
	if typeof(cs) ~= "ColorSequence" then return cs end
	if t <= 0 then return cs.Keypoints[1].Value end
	if t >= 1 then return cs.Keypoints[#cs.Keypoints].Value end
	for i = 1, #cs.Keypoints - 1 do
		local this = cs.Keypoints[i]
		local next = cs.Keypoints[i + 1]
		if t >= this.Time and t < next.Time then
			local alpha = (t - this.Time) / (next.Time - this.Time)
			return this.Value:Lerp(next.Value, alpha)
		end
	end
end

local function evalNS(ns, t)
	if typeof(ns) ~= "NumberSequence" then return ns end
	if t <= 0 then return ns.Keypoints[1].Value end
	if t >= 1 then return ns.Keypoints[#ns.Keypoints].Value end
	for i = 1, #ns.Keypoints - 1 do
		local this = ns.Keypoints[i]
		local next = ns.Keypoints[i + 1]
		if t >= this.Time and t < next.Time then
			local alpha = (t - this.Time) / (next.Time - this.Time)
			return (next.Value - this.Value) * alpha + this.Value
		end
	end
end

local function evalNR(range)
	if typeof(range) ~= "NumberRange" then return range end
	return math.random() * (range.Max - range.Min) + range.Min
end

-- Particle Class
local ParticleClass = {}
ParticleClass.__index = ParticleClass

function ParticleClass.new(emitter)
	local self = setmetatable({}, ParticleClass)

	-- Setup Visuals
	self.Element = emitter.Element:Clone()
	self.Color = emitter.Color
	self.Transparency = emitter.Transparency
	self.Size = emitter.Size

	-- Calculate Initial Size (Fix for invisible particles)
	local templateSize = emitter.Element.AbsoluteSize
	if templateSize.X <= 0 then
		templateSize = Vector2.new(emitter.Element.Size.X.Offset, emitter.Element.Size.Y.Offset)
		if templateSize.X <= 0 then templateSize = Vector2.new(50, 50) end -- Final fallback
	end
	self.StartSize = templateSize

	-- Setup Canvas
	self.Canvas = Instance.new("CanvasGroup")
	self.Canvas.BackgroundTransparency = 1
	self.Canvas.BorderSizePixel = 0
	self.Canvas.Size = UDim2.fromOffset(self.StartSize.X, self.StartSize.Y)
	self.Canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	self.Canvas.ZIndex = (emitter.Hook.ZIndex or 1) + (emitter.ZOffset or 0)

	-- Parent finding
	local root = emitter.Hook:FindFirstAncestorWhichIsA("LayerCollector")
	self.Canvas.Parent = root

	self.Element.Size = UDim2.fromScale(1, 1)
	self.Element.Position = UDim2.fromScale(0.5, 0.5)
	self.Element.AnchorPoint = Vector2.new(0.5, 0.5)
	self.Element.Visible = true
	self.Element.Parent = self.Canvas

	-- Positioning
	local spawnPos = emitter.Hook.AbsolutePosition
	local hookSize = emitter.Hook.AbsoluteSize
	if emitter.EmitterMode == "Point" then
		spawnPos += (hookSize / 2)
	else
		spawnPos += Vector2.new(math.random(0, hookSize.X), math.random(0, hookSize.Y))
	end

	self.Position = spawnPos
	self.Canvas.Position = UDim2.fromOffset(spawnPos.X, spawnPos.Y)

	-- Physics
	self.Speed = Vector2.new(evalNR(emitter.xSpeed), evalNR(emitter.ySpeed))
	self.SpreadAngle = evalNR(emitter.SpreadAngle)
	self.RotSpeed = evalNR(emitter.RotSpeed)
	self.Acceleration = Rotate(emitter.Acceleration, -self.SpreadAngle)

	self.Age = 0
	self.maxAge = evalNR(emitter.Lifetime)
	self.isDead = false

	emitter.preSpawn(self.Element)

	return self
end

function ParticleClass:Update(delta)
	if self.isDead then return end

	self.Age += delta
	local alpha = math.clamp(self.Age / self.maxAge, 0, 1)

	if alpha >= 1 then
		self:Destroy()
		return
	end

	-- Update Visuals
	local xS = evalNS(self.Size.X, alpha)
	local yS = evalNS(self.Size.Y, alpha)
	self.Canvas.Size = UDim2.fromOffset(self.StartSize.X * xS, self.StartSize.Y * yS)
	self.Canvas.GroupColor3 = evalCS(self.Color, alpha)
	self.Canvas.GroupTransparency = evalNS(self.Transparency, alpha)

	-- Update Physics
	local moveDir = Rotate(self.Speed, self.SpreadAngle) * Vector2.new(1, -1)
	self.Speed += (self.Acceleration * delta)
	self.Position += (moveDir * delta)

	self.Canvas.Position = UDim2.fromOffset(self.Position.X, self.Position.Y)
	self.Canvas.Rotation += self.RotSpeed * delta
end

function ParticleClass:Destroy()
	if self.isDead then return end
	self.isDead = true
	self.Canvas:Destroy()
end

-- Emitter Class
local ParticleEmitterClass = {}
ParticleEmitterClass.__index = ParticleEmitterClass

function ParticleEmitterClass.new(hook: GuiObject, particleElement: GuiObject)
	local self = setmetatable({}, ParticleEmitterClass)

	self.particles = {}
	self.Enabled = false
	self.Element = particleElement
	self.Hook = hook
	self.preSpawn = function(p) end

	-- Properties
	self.Rate = 20
	self.Color = ColorSequence.new(Color3.new(1,1,1))
	self.Size = {X = NumberSequence.new(1), Y = NumberSequence.new(1)}
	self.Transparency = NumberSequence.new(0)
	self.ZOffset = 0
	self.xSpeed = NumberRange.new(0,0)
	self.ySpeed = NumberRange.new(150,500)
	self.SpreadAngle = NumberRange.new(-15,15)
	self.RotSpeed = NumberRange.new(0)
	self.Lifetime = NumberRange.new(5,10)
	self.Acceleration = Vector2.new(0,-500)
	self.EmitterMode = "Point"

	self.__dead = false
	self.__elapsedTime = 0

	self.__runServiceConnection = RunService.Heartbeat:Connect(function(delta)
		-- Update existing particles (BACKWARDS LOOP FIXES MEMORY LEAK)
		for i = #self.particles, 1, -1 do
			local p = self.particles[i]
			p:Update(delta)
			if p.isDead then
				table.remove(self.particles, i)
			end
		end

		-- Handle Continuous Emission
		if self.Enabled and self.Rate > 0 and not self.__dead then
			self.__elapsedTime += delta
			local interval = 1 / self.Rate
			while self.__elapsedTime >= interval do
				self.__elapsedTime -= interval
				table.insert(self.particles, ParticleClass.new(self))
			end
		end
	end)

	return self
end

function ParticleEmitterClass:Emit(count: number)
	if self.__dead then return end
	for i = 1, count do
		table.insert(self.particles, ParticleClass.new(self))
	end
end

function ParticleEmitterClass:Destroy()
	if self.__dead then return end
	self.__dead = true
	self.__runServiceConnection:Disconnect()
	for _, p in ipairs(self.particles) do
		p:Destroy()
	end
	table.clear(self.particles)
end

return ParticleEmitterClass