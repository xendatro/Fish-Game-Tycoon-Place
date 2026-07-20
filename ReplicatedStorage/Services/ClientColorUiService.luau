--[[
ClientColorUiService - the per-object colour flow, opened by clicking a placeable while no
asset or tool is selected in the build menu.

Four panels share one ScreenGui, swapped in place like the reference flow:
  Item    -> the clicked object, with a Colors button
  Palette -> that object's config palettes, plus the player's saved custom palette
  Custom  -> per-slot colour entry, live preview on the object, save to item or as palette
  Dialog  -> naming the palette, then whether linked objects should follow

Placeholder visuals: an artist is replacing this. It sits on the right so it never overlaps
the build menu.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ClientColorUiService = {}

if not RunService:IsClient() then
	return ClientColorUiService
end

local SharedColorService = require(ReplicatedStorage.Services.SharedColorService)
local ClientBuildingService = require(ReplicatedStorage.Services.ClientBuildingService)
local DataSaveService = require(ReplicatedStorage.Services.DataSaveService)

local player = Players.LocalPlayer

local selectedModel: Model? = nil
local selectedName: string? = nil
-- Colours being edited in the Custom panel, applied live to the selected object.
local draft: SharedColorService.SlotMap = {}
-- What the object wore when it was selected, so backing out can restore it.
local original: SharedColorService.SlotMap? = nil
local originalLinked = false

local highlight = Instance.new("SelectionBox")
highlight.Name = "ColorUiHighlight"
highlight.Color3 = Color3.fromRGB(90, 200, 255)
highlight.LineThickness = 0.06
highlight.SurfaceColor3 = Color3.fromRGB(90, 200, 255)
highlight.SurfaceTransparency = 0.9
highlight.Visible = false

local gui = Instance.new("ScreenGui")
gui.Name = "BuildingColorUi"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")
highlight.Parent = gui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(300, 460)
panel.Position = UDim2.new(1, -312, 0, 12)
panel.BackgroundColor3 = Color3.new(0, 0, 0)
panel.BackgroundTransparency = 0.35
panel.BorderSizePixel = 0
panel.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -8, 0, 32)
title.Position = UDim2.fromOffset(4, 4)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.new(1, 1, 1)
title.TextWrapped = true
title.Parent = panel

local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, -8, 1, -44)
body.Position = UDim2.fromOffset(4, 40)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 6
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = panel

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.Padding = UDim.new(0, 2)
bodyLayout.Parent = body

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -8, 0, 18)
status.Position = UDim2.new(0, 4, 1, -18)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(170, 210, 255)
status.TextScaled = true
status.Text = ""
status.Parent = panel

-- Modal dialogs overlay the panel and block it until answered.
local dialog = Instance.new("Frame")
dialog.Size = UDim2.fromOffset(300, 200)
dialog.Position = UDim2.new(0.5, -150, 0.5, -100)
dialog.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
dialog.BorderSizePixel = 0
dialog.Visible = false
dialog.Parent = gui

local dialogText = Instance.new("TextLabel")
dialogText.Size = UDim2.new(1, -16, 0, 70)
dialogText.Position = UDim2.fromOffset(8, 8)
dialogText.BackgroundTransparency = 1
dialogText.TextColor3 = Color3.new(1, 1, 1)
dialogText.TextWrapped = true
dialogText.Parent = dialog

local dialogInput = Instance.new("TextBox")
dialogInput.Size = UDim2.new(1, -16, 0, 26)
dialogInput.Position = UDim2.fromOffset(8, 82)
dialogInput.BorderSizePixel = 0
dialogInput.ClearTextOnFocus = false
dialogInput.PlaceholderText = "Palette name"
dialogInput.Text = ""
dialogInput.Parent = dialog

local dialogButtons = Instance.new("Frame")
dialogButtons.Size = UDim2.new(1, -16, 0, 84)
dialogButtons.Position = UDim2.fromOffset(8, 112)
dialogButtons.BackgroundTransparency = 1
dialogButtons.Parent = dialog

local dialogLayout = Instance.new("UIListLayout")
dialogLayout.Padding = UDim.new(0, 2)
dialogLayout.Parent = dialogButtons

local function setStatus(text: string?)
	status.Text = text or ""
end

--[[Opens the modal with a message, an optional name field, and a set of choices.]]
local function openDialog(text: string, withInput: boolean, choices: { { Text: string, Run: () -> () } })
	dialogText.Text = text
	dialogInput.Visible = withInput
	if withInput then
		dialogInput.Text = ""
	end
	for _, child in dialogButtons:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	for _, choice in choices do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 26)
		button.Text = choice.Text
		button.Parent = dialogButtons
		button.Activated:Connect(choice.Run)
	end
	dialog.Visible = true
end

local function clearBody()
	for _, child in body:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function addButton(parent: Instance, text: string, onActivate: () -> ()): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 26)
	button.Text = text
	button.Parent = parent
	button.Activated:Connect(onActivate)
	return button
end

local function addSwatchStrip(parent: Instance, colors: SharedColorService.SlotMap?, slots: { number })
	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(1, 0, 0, 22)
	strip.BackgroundTransparency = 1
	strip.Parent = parent

	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(2, 0)
	layout.CellSize = UDim2.new(0, 22, 0, 22)
	layout.Parent = strip

	-- An unset slot shows white, matching the empty custom-palette placeholder.
	for _, slot in slots do
		local packed = colors and colors[slot]
		local swatch = Instance.new("Frame")
		swatch.BackgroundColor3 = if packed then SharedColorService.Unpack(packed) else Color3.new(1, 1, 1)
		swatch.BorderSizePixel = 0
		swatch.Parent = strip
	end
	return strip
end

-- ===== Live preview =========================================================

--[[Paints the selected object locally so the Custom panel updates as you type. The server
still owns the real colours; this is overwritten by replication once something is saved.]]
local function previewDraft()
	if selectedModel and selectedName then
		SharedColorService:ApplyColors(selectedModel, selectedName, draft)
	end
end

local function restoreOriginal()
	if selectedModel and selectedName then
		SharedColorService:ApplyColors(selectedModel, selectedName, original)
	end
end

-- ===== Panels ===============================================================

local showItem, showPalettes, showCustom, askApplyAll
-- Only the palette list is safe to redraw from replication; the others hold typed input.
local showingPalettes = false

--[[Applies colours to the selected object on the server. `linked` marks it as wearing the
saved palette.]]
local function commit(colors: SharedColorService.SlotMap?, linked: boolean)
	local model = selectedModel
	if not model then
		return
	end
	local ok, reason = ClientBuildingService:RecolorPlacement(
		model:GetAttribute("PlacementId") :: number,
		colors,
		linked
	)
	if ok then
		original, originalLinked = colors, linked
	end
	setStatus(if ok then "applied" else `rejected: {reason}`)
end

function showItem()
	clearBody()
	showingPalettes = false
	local name = selectedName :: string
	title.Text = name

	local info = Instance.new("TextLabel")
	info.Size = UDim2.new(1, 0, 0, 28)
	info.BackgroundTransparency = 1
	info.TextColor3 = Color3.fromRGB(200, 200, 200)
	info.Text = if not SharedColorService:IsColorable(name)
		then "No colour slots"
		elseif originalLinked then "Using your palette"
		else "Custom colours"
	info.Parent = body

	if SharedColorService:IsColorable(name) then
		addButton(body, "Colors", showPalettes)
	end
	addButton(body, "Close", function()
		ClientColorUiService:Close()
	end)
end

function showPalettes()
	clearBody()
	showingPalettes = true
	local name = selectedName :: string
	title.Text = "Select a color palette"
	local slots = SharedColorService:GetSlots(name)

	addButton(body, "< Back", showItem)

	for _, palette in SharedColorService:GetPalettes(name) do
		addButton(body, palette.Name, function()
			draft = table.clone(palette.Colors)
			previewDraft()
			commit(SharedColorService:Sanitize(name, draft), false)
			showPalettes()
		end)
		addSwatchStrip(body, palette.Colors, slots)
	end

	local saved, savedName = ClientBuildingService:GetSavedPalette(name)
	addButton(body, if saved then `{savedName} (yours)` else "Custom Palette (empty)", function()
		if not saved then
			setStatus("set custom colours first")
			return
		end
		draft = table.clone(saved)
		previewDraft()
		commit(saved, true)
		showPalettes()
	end)
	addSwatchStrip(body, saved, slots)

	if saved then
		addButton(body, "Apply To All Placed", function()
			askApplyAll(name)
		end)
	end

	addButton(body, "Set Custom Colors", function()
		draft = table.clone(original or {})
		showCustom()
	end)
end

--[[
Saves the draft as the palette. One server call does everything: stores it, decides what
happens to other linked objects, and links the object being edited. Splitting that into a
save plus a follow-up recolour used to report a false failure whenever the sweep had
already brought this object up to date.
]]
local function savePalette(name: string, paletteName: string, propagate: boolean)
	local model = selectedModel
	local ok, reason, updated = ClientBuildingService:SavePalette(
		name,
		draft,
		propagate,
		paletteName,
		model and model:GetAttribute("PlacementId")
	)
	dialog.Visible = false
	if ok then
		original = SharedColorService:Sanitize(name, draft)
		originalLinked = true
	end
	-- Report what the server actually did, so a sweep that touched nothing is visible
	-- rather than looking like success.
	setStatus(if ok then `saved, updated {updated}` else `rejected: {reason}`)
	showPalettes()
end

local function askPropagate(name: string, paletteName: string, linked: number)
	openDialog(`{linked} other placed {name}(s) use your palette. Update them too?`, false, {
		{ Text = `Update All {linked}`, Run = function()
			savePalette(name, paletteName, true)
		end },
		{ Text = "Keep Them As They Are", Run = function()
			savePalette(name, paletteName, false)
		end },
		{ Text = "Cancel", Run = function()
			dialog.Visible = false
		end },
	})
end

local function askPaletteName(name: string)
	local existing = ClientBuildingService:GetSavedPalette(name)
	local prompt = if existing
		then "Your current custom palette will be replaced if you continue."
		else "Name this palette."

	openDialog(prompt, true, {
		{ Text = "Confirm", Run = function()
			local paletteName = if #dialogInput.Text > 0 then dialogInput.Text else "Custom"
			local model = selectedModel
			local _, linked = ClientBuildingService:PaletteInfo(name)
			-- The object being edited adopts the palette either way, so it doesn't count
			-- toward "would this change anything else".
			if model and model:GetAttribute("PaletteLinked") then
				linked -= 1
			end
			local changing = existing
				and not SharedColorService:Equal(existing, SharedColorService:Sanitize(name, draft))
			if changing and linked > 0 then
				askPropagate(name, paletteName, linked)
				return
			end
			savePalette(name, paletteName, true)
		end },
		{ Text = "Cancel", Run = function()
			dialog.Visible = false
		end },
	})
end

function askApplyAll(name: string)
	local total, linked = ClientBuildingService:PaletteInfo(name)
	if total == 0 then
		setStatus(`no placed {name}`)
		return
	end
	openDialog(
		`Apply your palette to all {total} placed {name}(s)? {linked} already use it.`,
		false,
		{
			{ Text = `Apply To All {total}`, Run = function()
				local changed, reason = ClientBuildingService:ApplyPalette(name)
				dialog.Visible = false
				setStatus(if changed > 0 then `relinked {changed}` else reason)
				showPalettes()
			end },
			{ Text = "Cancel", Run = function()
				dialog.Visible = false
			end },
		}
	)
end

function showCustom()
	clearBody()
	showingPalettes = false
	local name = selectedName :: string
	title.Text = "Custom Colors"
	local slots = SharedColorService:GetSlots(name)

	addButton(body, "< Back", function()
		restoreOriginal()
		showPalettes()
	end)

	for _, slot in slots do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 26)
		row.BackgroundTransparency = 1
		row.Parent = body

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0.4, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = SharedColorService:GetSlotName(name, slot)
		label.Parent = row

		local box = Instance.new("TextBox")
		box.Size = UDim2.new(0.6, 0, 1, 0)
		box.Position = UDim2.new(0.4, 0, 0, 0)
		box.BorderSizePixel = 0
		box.ClearTextOnFocus = false
		box.PlaceholderText = "#rrggbb"
		box.Text = ""
		box.Parent = row

		local packed = draft[slot]
		if packed then
			box.BackgroundColor3 = SharedColorService.Unpack(packed)
		end

		box.FocusLost:Connect(function()
			local value = SharedColorService.ParseColor(box.Text)
			draft[slot] = value
			box.BackgroundColor3 = if value
				then SharedColorService.Unpack(value)
				else Color3.fromRGB(45, 45, 45)
			if not value then
				box.Text = ""
			end
			previewDraft()
		end)
	end

	local savedLabel = Instance.new("TextLabel")
	savedLabel.Size = UDim2.new(1, 0, 0, 20)
	savedLabel.BackgroundTransparency = 1
	savedLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	savedLabel.Text = "Your Custom Palette"
	savedLabel.Parent = body
	addSwatchStrip(body, (ClientBuildingService:GetSavedPalette(name)), slots)

	addButton(body, "Save To Item", function()
		commit(SharedColorService:Sanitize(name, draft), false)
	end)
	addButton(body, "Save As Custom Palette", function()
		askPaletteName(name)
	end)
end

-- ===== Open / close =========================================================

function ClientColorUiService:Close()
	restoreOriginal()
	selectedModel, selectedName, original = nil, nil, nil
	highlight.Adornee = nil
	highlight.Visible = false
	dialog.Visible = false
	gui.Enabled = false
end

function ClientColorUiService:Open(model: Model)
	local name = model:GetAttribute("AssetName")
	if type(name) ~= "string" then
		return
	end
	selectedModel, selectedName = model, name
	originalLinked = model:GetAttribute("PaletteLinked") == true

	-- Start from what's actually on screen rather than from the asset defaults.
	original = SharedColorService:Sanitize(name, SharedColorService:ReadColors(model, name))
	draft = table.clone(original or {})

	highlight.Adornee = model
	highlight.Visible = true
	gui.Enabled = true
	setStatus(nil)
	showItem()
end

ClientBuildingService.PlacementSelected:Connect(function(model: Model?)
	if model then
		ClientColorUiService:Open(model)
	else
		ClientColorUiService:Close()
	end
end)

--[[
A saved palette arrives by replication, not in the remote's return value, so the palette
list has to redraw when the profile catches up or it keeps showing the old swatches.
Data.Changed also fires on every build save, hence the signature comparison.
]]
task.spawn(function()
	local profile = DataSaveService:WaitForProfile()
	if not profile then
		return
	end
	local function signature(): string
		local saved = if selectedName then (ClientBuildingService:GetSavedPalette(selectedName)) else nil
		return table.concat(SharedColorService.FlattenSlots(saved), ",")
	end
	local last = signature()
	profile.Data.Changed:Connect(function()
		local current = signature()
		if current ~= last then
			last = current
			if showingPalettes and selectedName then
				showPalettes()
			end
		end
	end)
end)

return ClientColorUiService
