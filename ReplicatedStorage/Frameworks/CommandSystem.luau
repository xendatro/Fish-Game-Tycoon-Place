local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

-- Require the user's Signal module
local SignalClass = require(ReplicatedStorage:WaitForChild("Classes"):WaitForChild("Signal"))
local Remote = script:WaitForChild("Remote") :: RemoteEvent

-- // TYPES //

export type CommandArg = {
	Name: string,
	Type: "Player" | "List" | "String" | "Number",
	Options: {string}?,
	HideName: boolean?,
	Optional: boolean? -- New option
}

export type CommandDefinition = {
	Name: string,
	Toggleable: boolean?,
	Args: {CommandArg}
}

export type Suggestion = {
	Text: string,
	Fill: string
}

type ClientState = {
	TextBox: TextBox?,
	ScrollFrame: ScrollingFrame?,
	Template: TextButton?,
	Suggestions: {Suggestion},
	SelectedIndex: number,
	IsVisible: boolean,
	PaddingOffset: number,
	IgnoreUpdate: boolean,
	IsPlayerAdmin: boolean,
	GlobalWarning: TextLabel?,
}

type ConfigType = {
	TextSize: number,
	RowHeight: number,
	MaxMenuHeight: number
}

-- // MODULE SETUP //

local CommandSystem = {}
CommandSystem.Registry = {} :: {[string]: CommandDefinition}
CommandSystem.ActiveStates = {} :: {[string]: boolean}

-- Signal
CommandSystem.CommandToggled = SignalClass.new() 

-- // SHARED METHODS //

function CommandSystem:Parse(text: string): {string}
	local args: {string} = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(args, word)
	end
	return args
end

function CommandSystem:Register(definition: CommandDefinition)
	self.Registry[definition.Name] = definition
	if definition.Toggleable then
		self.ActiveStates[definition.Name] = false
	end
end

function CommandSystem:IsActive(commandName: string): boolean
	return self.ActiveStates[commandName] == true
end

-- // SERVER SIDE //

if RunService:IsServer() then
	local MessagingService = game:GetService("MessagingService")
	local GLOBAL_TOPIC = "GlobalAdminCommand_Bridge"

	CommandSystem.Admins = {} :: {number}

	function CommandSystem:AddAdmin(userId: number)
		if not table.find(self.Admins, userId) then
			table.insert(self.Admins, userId)
		end
	end

	function CommandSystem:IsAdmin(player: Player): boolean
		return table.find(self.Admins, player.UserId) ~= nil
	end

	function CommandSystem:ExecuteRaw(text: string, executor: Player | number)
		local args = self:Parse(text)
		local cmdName = table.remove(args, 1)
		if not cmdName then return end

		local def = self.Registry[cmdName]
		if not def then return end

		-- 1. ARGUMENT TYPE CONVERSION
		if def.Args then
			for i, argDef in ipairs(def.Args) do
				local rawValue = args[i]
				if rawValue then
					if argDef.Type == "Player" then
						args[i] = Players:FindFirstChild(rawValue) :: any 
					elseif argDef.Type == "Number" then
						args[i] = tonumber(rawValue) :: any
					end
				end
			end
		end

		-- 2. HANDLE TOGGLE LOGIC
		local newState: boolean? = nil
		if def.Toggleable then
			local currentState = self.ActiveStates[cmdName] or false
			newState = not currentState
			self.ActiveStates[cmdName] = newState

			self.CommandToggled:Fire(cmdName, newState)
			Remote:FireAllClients("StateUpdate", cmdName, newState)
		end

		-- 3. HANDLE MODULE EXECUTION
		local cmdModule = script:FindFirstChild(cmdName)
		if cmdModule and cmdModule:IsA("ModuleScript") then
			task.spawn(function()
				-- Updated type hint: first arg is now Player | number
				local cmdLogic = require(cmdModule) :: (Player | number, ...any) -> ()

				if newState ~= nil then
					-- Toggleable modules: (executor, newState, ...args)
					cmdLogic(executor, newState, unpack(args))
				else
					-- Standard modules: (executor, ...args)
					cmdLogic(executor, unpack(args))
				end
			end)
		end
	end

	function CommandSystem:InitServer()
		-- Register the built-in global toggle
		self:Register({
			Name = "global",
			Toggleable = true,
			Args = {}
		})

		Remote.OnServerEvent:Connect(function(player: Player, text: unknown)
			if type(text) ~= "string" then return end
			if not self:IsAdmin(player) then return end

			local cleanText = text:gsub("^%s*(.-)%s*$", "%1"):lower()

			-- If global is active and we aren't just toggling the global mode itself
			if self:IsActive("global") and not cleanText:find("^global") then
				MessagingService:PublishAsync(GLOBAL_TOPIC, {
					Text = text,
					UserId = player.UserId,
					SourceJobId = game.JobId -- 1. Tag the message with this server's ID
				})
			end

			-- Always execute locally for the sender immediately (no latency)
			self:ExecuteRaw(text, player)
		end)

		MessagingService:SubscribeAsync(GLOBAL_TOPIC, function(message)
			local data = message.Data

			-- 2. If the message came from THIS server, ignore it (we already ran it)
			if data.SourceJobId == game.JobId then 
				return 
			end

			local player = Players:GetPlayerByUserId(data.UserId)
			local executor = player or data.UserId

			self:ExecuteRaw(data.Text, executor)
		end)

		local function sync(p: Player)
			task.wait(1)
			Remote:FireClient(p, "Init", self.Registry, self:IsAdmin(p), self.ActiveStates)
		end

		Players.PlayerAdded:Connect(sync)
		for _, p in pairs(Players:GetPlayers()) do sync(p) end
	end
end

-- // CLIENT SIDE //

if RunService:IsClient() then

	local Config: ConfigType = {
		TextSize = 20,
		RowHeight = 28,
		MaxMenuHeight = 200, 
	}

	local ClientState: ClientState = {
		TextBox = nil,
		ScrollFrame = nil,
		Template = nil,
		Suggestions = {},
		SelectedIndex = 1,
		IsVisible = false,
		PaddingOffset = 10,
		IgnoreUpdate = false,
		IsPlayerAdmin = false,
		GlobalWarning = nil,
	}

	function CommandSystem:InitClient()
		local player = Players.LocalPlayer
		if not player then return end

		local playerGui = player:WaitForChild("PlayerGui")
		local screenGui = playerGui:WaitForChild("Admin")
		local textBoxInstance = screenGui:WaitForChild("TextBox")

		if not textBoxInstance:IsA("TextBox") then return end
		local textBox = textBoxInstance :: TextBox

		ClientState.TextBox = textBox
		ClientState.ScrollFrame = textBox:WaitForChild("ScrollingFrame") :: ScrollingFrame
		ClientState.Template = ClientState.ScrollFrame:WaitForChild("AutofillTemplate") :: TextButton

		textBox.Visible = false
		textBox.TextScaled = false
		textBox.TextSize = Config.TextSize 

		local uiPadding = textBox:FindFirstChildOfClass("UIPadding")
		if uiPadding then
			ClientState.PaddingOffset = uiPadding.PaddingLeft.Offset
		end

		local layout = ClientState.ScrollFrame:FindFirstChildOfClass("UIListLayout")
		if not layout then
			layout = Instance.new("UIListLayout")
			layout.Parent = ClientState.ScrollFrame
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(0, 0)
		end

		ClientState.Template.Visible = false
		ClientState.Template.TextSize = Config.TextSize
		ClientState.Template.AutomaticSize = Enum.AutomaticSize.None 
		ClientState.Template.Size = UDim2.new(1, 0, 0, Config.RowHeight)
		ClientState.Template.TextXAlignment = Enum.TextXAlignment.Left

		ClientState.ScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
		ClientState.ScrollFrame.ZIndex = 10
		ClientState.ScrollFrame.AnchorPoint = Vector2.new(0, 0) 

		Remote.OnClientEvent:Connect(function(action: string, ...)
			local args = {...}

			if action == "Init" then
				local reg = args[1]
				local isAdmin = args[2]
				local states = args[3]

				self.Registry = reg
				ClientState.IsPlayerAdmin = isAdmin
				self.ActiveStates = states or {}

			elseif action == "StateUpdate" then
				local cmdName = args[1]
				local newState = args[2]

				self.ActiveStates[cmdName] = newState
				self.CommandToggled:Fire(cmdName, newState)
			end
		end)

		textBox:GetPropertyChangedSignal("Text"):Connect(function()
			self:OnTextChanged()
		end)

		textBox:GetPropertyChangedSignal("CursorPosition"):Connect(function()
			self:UpdatePosition()
		end)

		textBox.FocusLost:Connect(function(enterPressed: boolean)
			if enterPressed then
				local text = textBox.Text
				if text ~= "" then
					Remote:FireServer(text)
					self:ToggleUI(false)
				end
			end
		end)

		UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
			if input.KeyCode == Enum.KeyCode.Semicolon then
				if gpe and UserInputService:GetFocusedTextBox() ~= textBox then 
					return 
				end

				if ClientState.IsPlayerAdmin then
					self:ToggleUI()
				end
				return
			end

			if UserInputService:GetFocusedTextBox() ~= textBox then return end

			if input.KeyCode == Enum.KeyCode.Down then
				self:Navigate(1)
			elseif input.KeyCode == Enum.KeyCode.Up then
				self:Navigate(-1)
			elseif input.KeyCode == Enum.KeyCode.Tab then
				if ClientState.IsVisible and #ClientState.Suggestions > 0 then
					self:SelectSuggestion()
					task.defer(function()
						textBox:CaptureFocus()
						textBox.CursorPosition = #textBox.Text + 1
					end)
				end
			end
		end)
		
		local screenGui = playerGui:WaitForChild("Admin")
		local textBox = screenGui:WaitForChild("TextBox") :: TextBox

		-- CREATE THE WARNING LABEL
		local warning = Instance.new("TextLabel")
		warning.Name = "GlobalWarning"
		warning.TextScaled = true
		warning.BackgroundTransparency = 1
		warning.Size = UDim2.fromScale(0.9, 0.05)
		-- Position it exactly below the TextBox
		warning.Position = UDim2.fromScale(0.5, 0.257)
		warning.AnchorPoint = textBox.AnchorPoint
		warning.ZIndex = 10
		warning.Text = "⚠️ GLOBAL MODE ACTIVE - SENDING TO ALL SERVERS"
		warning.TextColor3 = Color3.fromRGB(255, 80, 80) -- Bright Red
		warning.Font = Enum.Font.SourceSansBold
		warning.TextSize = 14
		warning.Visible = false
		warning.Parent = screenGui

		ClientState.GlobalWarning = warning

		-- ... (rest of your InitClient code)

		-- Update the Remote.OnClientEvent listener to check for "global" updates:
		Remote.OnClientEvent:Connect(function(action: string, ...)
			local args = {...}

			if action == "Init" then
				self.Registry = args[1]
				ClientState.IsPlayerAdmin = args[2]
				self.ActiveStates = args[3] or {}
				self:UpdateWarningVisibility() -- Initial check

			elseif action == "StateUpdate" then
				local cmdName = args[1]
				local newState = args[2]

				self.ActiveStates[cmdName] = newState
				self.CommandToggled:Fire(cmdName, newState)

				if cmdName == "global" then
					self:UpdateWarningVisibility()
				end
			end
		end)
	end
	
	function CommandSystem:UpdateWarningVisibility()
		local warning = ClientState.GlobalWarning
		if not warning then return end

		-- Show only if the TextBox is open AND global mode is enabled
		local isGlobalActive = self:IsActive("global")
		local isUIOpen = ClientState.TextBox and ClientState.TextBox.Visible

		warning.Visible = isGlobalActive and isUIOpen
	end

	function CommandSystem:ToggleUI(forceState: boolean?)
		local tb = ClientState.TextBox
		if not tb then return end

		local newState: boolean
		if forceState ~= nil then
			newState = forceState
		else
			newState = not tb.Visible
		end

		if newState then
			tb.Visible = true
			tb.Text = "" 

			task.defer(function()
				tb:CaptureFocus()
				task.wait() 
				if tb.Text == ";" then tb.Text = "" end 
			end)
		else
			tb.Visible = false
			tb:ReleaseFocus()
			if ClientState.ScrollFrame then
				ClientState.ScrollFrame.Visible = false
			end
			ClientState.IsVisible = false
		end
		
		self:UpdateWarningVisibility()
	end

	function CommandSystem:GetSuggestionsInternal(text: string): {Suggestion}
		local args = self:Parse(text)

		if text:sub(-1) == " " then 
			table.insert(args, "") 
		end 

		if #args == 0 then
			table.insert(args, "")
		end

		local currentArgIndex = #args
		if currentArgIndex == 0 then return {} end

		local cmdName = args[1]
		local suggestions: {Suggestion} = {}

		if currentArgIndex == 1 then
			for name, def in pairs(self.Registry) do
				if name:lower():sub(1, #cmdName) == cmdName:lower() then
					local displayText = name
					if def.Toggleable then
						local status = if self:IsActive(name) then "[ENABLED]" else "[DISABLED]"
						displayText = name .. " " .. status
					end
					table.insert(suggestions, {Text = displayText, Fill = name .. " "})
				end
			end
		else
			local cmdDef = self.Registry[cmdName]
			if cmdDef then
				local paramDef = cmdDef.Args and cmdDef.Args[currentArgIndex - 1]
				if paramDef then
					local currentInput = args[currentArgIndex] or ""

					-- FORMATTING HELPER: Handles HideName and Optional visual indicators
					local function formatLabel(val: string)
						if paramDef.HideName then
							return val
						end

						local nameStr = paramDef.Name
						if paramDef.Optional then
							nameStr = nameStr .. "?" -- Add ? if optional
						end

						local suffix = "(" .. nameStr .. ")"

						-- Add type to suffix for String/Number
						if paramDef.Type == "String" or paramDef.Type == "Number" then
							suffix = "(" .. nameStr .. ": " .. paramDef.Type .. ")"
						end

						return val .. " " .. suffix
					end

					if paramDef.Type == "Player" then
						for _, p in pairs(Players:GetPlayers()) do 
							if p.Name:lower():sub(1, #currentInput) == currentInput:lower() then
								local newArgs = table.clone(args)
								newArgs[currentArgIndex] = p.Name
								table.insert(suggestions, {
									Text = formatLabel(p.Name),
									Fill = table.concat(newArgs, " ") .. " "
								})
							end
						end
					elseif paramDef.Type == "List" and paramDef.Options then
						for _, opt in pairs(paramDef.Options) do
							if opt:lower():sub(1, #currentInput) == currentInput:lower() then
								local newArgs = table.clone(args)
								newArgs[currentArgIndex] = opt
								table.insert(suggestions, {
									Text = formatLabel(opt),
									Fill = table.concat(newArgs, " ") .. " "
								})
							end
						end
					elseif paramDef.Type == "String" or paramDef.Type == "Number" then
						local display = currentInput
						if display == "" then
							local typeLabel = paramDef.Type
							if paramDef.Optional then typeLabel = typeLabel .. "?" end
							display = "<" .. typeLabel .. ">"
						end

						local newArgs = table.clone(args)
						newArgs[currentArgIndex] = currentInput

						table.insert(suggestions, {
							Text = formatLabel(display),
							Fill = table.concat(newArgs, " ") .. " "
						})
					end
				end
			end
		end
		return suggestions
	end

	local function MeasureTextWidth(text: string, fontFace: Font, textSize: number): number
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = fontFace
		params.Size = textSize
		params.Width = 10000
		local success, bounds = pcall(function()
			return TextService:GetTextBoundsAsync(params)
		end)
		return success and bounds.X or 0
	end

	function CommandSystem:OnTextChanged()
		if ClientState.IgnoreUpdate then return end
		if not ClientState.TextBox then return end

		local rawText = ClientState.TextBox.Text
		local cleanText = rawText:gsub("[\t\n\r;]", "") 

		if rawText ~= cleanText then
			ClientState.IgnoreUpdate = true
			ClientState.TextBox.Text = cleanText
			ClientState.TextBox.CursorPosition = #cleanText + 1
			ClientState.IgnoreUpdate = false
		end

		self:UpdateSuggestions(cleanText)
	end

	function CommandSystem:UpdateSuggestions(text: string)
		local frame = ClientState.ScrollFrame
		local template = ClientState.Template
		if not frame or not template then return end

		for _, c in pairs(frame:GetChildren()) do
			if c:IsA("TextButton") and c ~= template then c:Destroy() end
		end

		ClientState.Suggestions = self:GetSuggestionsInternal(text)
		ClientState.SelectedIndex = 1

		if #ClientState.Suggestions == 0 then
			frame.Visible = false
			ClientState.IsVisible = false
			return
		end

		ClientState.IsVisible = true
		frame.Visible = true

		local maxTextWidth = 0
		for _, item in ipairs(ClientState.Suggestions) do
			local w = MeasureTextWidth(item.Text, template.FontFace, template.TextSize)
			if w > maxTextWidth then maxTextWidth = w end
		end

		local finalWidth = maxTextWidth + 30 
		local totalHeight = #ClientState.Suggestions * Config.RowHeight

		frame.Size = UDim2.new(0, finalWidth, 0, math.min(Config.MaxMenuHeight, totalHeight))
		frame.CanvasSize = UDim2.new(0, 0, 0, totalHeight)

		for i, item in ipairs(ClientState.Suggestions) do
			local btn = template:Clone()
			btn.Name = tostring(i)
			btn.Text = item.Text 
			btn.LayoutOrder = i
			btn.Visible = true
			btn.Parent = frame

			btn.MouseButton1Click:Connect(function()
				ClientState.SelectedIndex = i
				self:SelectSuggestion()
			end)
		end

		self:UpdatePosition()
		self:UpdateVisualSelection()
	end

	function CommandSystem:UpdatePosition()
		if not ClientState.IsVisible then return end
		if not ClientState.TextBox or not ClientState.ScrollFrame then return end

		local tb = ClientState.TextBox
		local cursorPos = tb.CursorPosition
		local textBeforeCursor = tb.Text:sub(1, cursorPos - 1)

		local cursorX = MeasureTextWidth(textBeforeCursor, tb.FontFace, tb.TextSize)
		local finalX = cursorX + ClientState.PaddingOffset

		ClientState.ScrollFrame.Position = UDim2.new(0, finalX, 1, 0)
	end

	function CommandSystem:Navigate(direction: number)
		if not ClientState.IsVisible then return end
		local count = #ClientState.Suggestions
		if count == 0 then return end

		ClientState.SelectedIndex = ClientState.SelectedIndex + direction
		if ClientState.SelectedIndex > count then ClientState.SelectedIndex = 1 end
		if ClientState.SelectedIndex < 1 then ClientState.SelectedIndex = count end

		self:UpdateVisualSelection()
	end

	function CommandSystem:UpdateVisualSelection()
		local frame = ClientState.ScrollFrame
		local template = ClientState.Template
		if not frame or not template then return end

		for i, child in pairs(frame:GetChildren()) do
			if child:IsA("TextButton") then
				local idx = tonumber(child.Name)
				if idx == ClientState.SelectedIndex then
					child.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
					child.TextColor3 = Color3.fromRGB(255, 255, 255)
					child.BackgroundTransparency = 0
				else
					child.BackgroundColor3 = template.BackgroundColor3
					child.TextColor3 = template.TextColor3
					child.BackgroundTransparency = template.BackgroundTransparency
				end
			end
		end

		local selectionTop = (ClientState.SelectedIndex - 1) * Config.RowHeight
		local currentScroll = frame.CanvasPosition.Y

		if selectionTop < currentScroll then
			frame.CanvasPosition = Vector2.new(0, selectionTop)
		elseif selectionTop + Config.RowHeight > currentScroll + frame.AbsoluteSize.Y then
			frame.CanvasPosition = Vector2.new(0, (selectionTop + Config.RowHeight) - frame.AbsoluteSize.Y)
		end
	end

	function CommandSystem:SelectSuggestion()
		local item = ClientState.Suggestions[ClientState.SelectedIndex]
		if item and ClientState.TextBox then
			ClientState.IgnoreUpdate = true
			ClientState.TextBox.Text = item.Fill
			ClientState.TextBox.CursorPosition = #item.Fill + 1
			ClientState.IgnoreUpdate = false
			self:OnTextChanged()
		end
	end
end

return CommandSystem