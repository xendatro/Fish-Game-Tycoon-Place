--[[
SharedColorService - everything about placeable colour customisation, used identically
by the client (preview ghosts, UI) and the server (authority + render).

It owns four things:

  1. The slot scan: at init, every placeable model is walked for parts tagged
     `Color1`..`ColorN`. The authored colour of those parts becomes that slot's DEFAULT
     for that asset, and parts sharing a tag but disagreeing on colour are warned about.
  2. Packing: colours travel and persist as packed 24-bit integers, never Color3.
  3. Palettes: each item's own presets, declared in its Config/Items entry and packed
     here at init. A slot number means whatever that object says it means - Color1 is a
     pot on a plant and a bulb on a light - so palettes are never shared between objects
     and an object simply omits presets that don't suit it. The authored colours are the
     always-present implicit default; they are not listed as a palette.
  4. Sanitising: the server's gate on client-supplied colours.

It never renders geometry, mutates the grid, or touches the profile.

Slot tags are read with CollectionService directly rather than through TagService:
TagService binds behaviour to live instances under an ancestor, but colours are applied
to each fresh clone at render time, which is a different job.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Building = require(ReplicatedStorage.Config.Building)
local Materials = require(ReplicatedStorage.Config.Materials)
local SharedBuildingService = require(ReplicatedStorage.Services.SharedBuildingService)

local SharedColorService = {}

local MAX_PACKED = 0xFFFFFF

-- slot number -> packed 24-bit colour
export type SlotMap = { [number]: number }
export type Palette = { Name: string, Colors: SlotMap }

-- Authored defaults per asset name. An asset absent here has no colour slots.
local defaults: { [string]: SlotMap } = {}

-- Config palettes per asset name, with their colours pre-packed.
local palettes: { [string]: { Palette } } = {}

-- ===== Packing ==============================================================

--[[Packs a Color3 into a 24-bit integer.]]
function SharedColorService.Pack(color: Color3): number
	return math.round(color.R * 255) * 65536 + math.round(color.G * 255) * 256 + math.round(color.B * 255)
end

--[[Unpacks a 24-bit integer back into a Color3.]]
function SharedColorService.Unpack(packed: number): Color3
	return Color3.fromRGB(math.floor(packed / 65536) % 256, math.floor(packed / 256) % 256, packed % 256)
end

--[[The CollectionService tag naming one colour slot.]]
local function slotTag(slot: number): string
	return `{Building.COLOR_TAG_PREFIX}{slot}`
end

--[[Returns the slot a part belongs to, or nil if it carries no colour tag.]]
local function partSlot(part: BasePart): number?
	for slot = 1, Building.COLOR_SLOTS do
		if part:HasTag(slotTag(slot)) then
			return slot
		end
	end
	return nil
end

-- ===== Init =================================================================

--[[
Records an asset's authored slot colours. Every part sharing a slot tag must agree;
a disagreement is a modelling mistake, so we warn and keep the first colour seen.
]]
local function scanAsset(name: string, model: Model)
	local slots: SlotMap = {}
	local found = false

	for _, part in model:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local slot = partSlot(part)
		if not slot then
			continue
		end
		local packed = SharedColorService.Pack(part.Color)
		if slots[slot] == nil then
			slots[slot] = packed
			found = true
		elseif slots[slot] ~= packed then
			warn(
				`[SharedColorService]: '{name}' has {slotTag(slot)} parts with different colours `
					.. `({part:GetFullName()}); all parts sharing a slot must match. Keeping the first.`
			)
		end
	end

	if found then
		defaults[name] = slots
	end
end

--[[
Packs an item's configured palettes. A palette naming a slot the model doesn't define is
a config/model mismatch worth surfacing, since that colour would silently do nothing.
]]
local function packPalettes(name: string, entry)
	if not entry.Palettes then
		return
	end
	local slots = defaults[name]
	-- One warning beats one per palette per slot when the model simply isn't tagged yet.
	if not slots then
		warn(`[SharedColorService]: '{name}' configures palettes but its model has no Color tags.`)
		return
	end
	local packed: { Palette } = {}

	for _, palette in entry.Palettes do
		local colors: SlotMap = {}
		for slot, color in palette.Colors do
			if not slots[slot] then
				warn(
					`[SharedColorService]: palette '{palette.Name}' on '{name}' sets {slotTag(slot)}, `
						.. `which that model has no tagged parts for; ignored.`
				)
				continue
			end
			colors[slot] = SharedColorService.Pack(color)
		end
		table.insert(packed, { Name = palette.Name, Colors = colors })
	end

	palettes[name] = packed
end

local function scanCatalog()
	for name, entry in SharedBuildingService:GetCatalog() do
		local model = SharedBuildingService:GetModel(name)
		if model then
			scanAsset(name, model)
		end
		packPalettes(name, entry)
	end
end

-- ===== Queries ==============================================================

--[[Returns an asset's defined slot numbers, ascending. Empty if it isn't colourable.]]
function SharedColorService:GetSlots(name: string): { number }
	local slots = {}
	for slot in defaults[name] or {} do
		table.insert(slots, slot)
	end
	table.sort(slots)
	return slots
end

--[[Returns the UI label for one of an asset's colour slots.]]
function SharedColorService:GetSlotName(name: string, slot: number): string
	local entry = SharedBuildingService:GetEntry(name)
	local names = entry and entry.ColorNames
	return (names and names[slot]) or `Color {slot}`
end

--[[Returns whether the asset has any recolourable slots.]]
function SharedColorService:IsColorable(name: string): boolean
	return defaults[name] ~= nil
end

--[[Returns an asset's own presets (empty when it only offers its authored default).]]
function SharedColorService:GetPalettes(name: string): { Palette }
	return palettes[name] or {}
end

--[[Parses "r,g,b" or "#rrggbb" into a packed colour, or nil if unparseable/empty.]]
function SharedColorService.ParseColor(text: string): number?
	local trimmed = text:gsub("%s", "")
	local hex = trimmed:match("^#?(%x%x%x%x%x%x)$")
	if hex then
		return tonumber(hex, 16)
	end
	local red, green, blue = trimmed:match("^(%d+),(%d+),(%d+)$")
	if not red then
		return nil
	end
	local r, g, b = tonumber(red), tonumber(green), tonumber(blue)
	if r > 255 or g > 255 or b > 255 then
		return nil
	end
	return SharedColorService.Pack(Color3.fromRGB(r, g, b))
end

--[[
The server's gate on a client-supplied colour map: keeps only integer slots the asset
actually defines, carrying in-range packed colours that differ from the authored
default. Returns nil when nothing survives, which is the "all defaults" representation.
]]
function SharedColorService:Sanitize(name: string, colors: any): SlotMap?
	local slots = defaults[name]
	if type(colors) ~= "table" or not slots then
		return nil
	end

	local clean: SlotMap = {}
	local count = 0
	for slot, packed in colors do
		local validSlot = type(slot) == "number" and slot % 1 == 0 and slots[slot] ~= nil
		local validColor = type(packed) == "number"
			and packed % 1 == 0
			and packed >= 0
			and packed <= MAX_PACKED
		if validSlot and validColor and packed ~= slots[slot] then
			clean[slot] = packed
			count += 1
		end
	end
	return if count > 0 then clean else nil
end

--[[
Flattens a slot map to {slot, colour, slot, colour, ...}, sorted. Colour maps are sparse
by nature, and a sparse numeric-keyed table does not survive a datastore round-trip (the
keys come back as strings), so anything persisted or replicated travels in this form.
]]
function SharedColorService.FlattenSlots(colors: SlotMap?): { number }
	local slots = {}
	for slot in colors or {} do
		table.insert(slots, slot)
	end
	table.sort(slots)

	local flat = {}
	for _, slot in slots do
		table.insert(flat, slot)
		table.insert(flat, (colors :: SlotMap)[slot])
	end
	return flat
end

--[[Rebuilds a slot map from the flat form. Tolerates a nil or odd-length array.]]
function SharedColorService.ExpandSlots(flat: { number }?): SlotMap
	local colors: SlotMap = {}
	for i = 1, #(flat or {}) - 1, 2 do
		colors[(flat :: { number })[i]] = (flat :: { number })[i + 1]
	end
	return colors
end

--[[Reads the colours a rendered model is currently wearing, slot by slot.]]
function SharedColorService:ReadColors(model: Model, name: string): SlotMap
	local colors: SlotMap = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local slot = partSlot(part)
			if slot and colors[slot] == nil then
				colors[slot] = SharedColorService.Pack(part.Color)
			end
		end
	end
	return colors
end

--[[Returns whether two colour maps describe the same result.]]
function SharedColorService:Equal(a: SlotMap?, b: SlotMap?): boolean
	for slot, packed in a or {} do
		if not b or b[slot] ~= packed then
			return false
		end
	end
	for slot, packed in b or {} do
		if not a or a[slot] ~= packed then
			return false
		end
	end
	return true
end

-- ===== Floor / ceiling materials ============================================
--[[
Floor and ceiling tiles aren't catalog models - they're parts this codebase generates,
and their tint is per-cell grid data rather than something authored on an instance. So
they get their own small surface here instead of the slot machinery: one colour per
tile, defaulting to the material's `Color` in Config/Materials.
]]

export type MaterialKind = "Floor" | "Ceiling"

--[[Returns a material's authored default tint, packed.]]
function SharedColorService:MaterialDefault(kind: MaterialKind, index: number): number?
	local material = Materials[kind][index]
	return if material then SharedColorService.Pack(material.Color) else nil
end

--[[
The server's gate on a client-supplied tile colour. Returns nil for anything invalid AND
for the material's own default, so an untinted cell stores nothing.
]]
function SharedColorService:SanitizeMaterialColor(kind: MaterialKind, index: number, color: any): number?
	local default = self:MaterialDefault(kind, index)
	if not default or type(color) ~= "number" or color % 1 ~= 0 or color < 0 or color > MAX_PACKED then
		return nil
	end
	return if color == default then nil else color
end

--[[The colour a tile actually renders as: its stored tint, or the material default.]]
function SharedColorService:MaterialColor(kind: MaterialKind, index: number, color: number?): Color3
	local packed = color or self:MaterialDefault(kind, index) or 0
	return SharedColorService.Unpack(packed)
end

-- ===== Application ==========================================================

--[[
Paints a model's tagged parts. Every defined slot is written every time - defaults
first, then the overrides - so re-applying with a slot removed correctly reverts that
slot instead of leaving the previous colour behind.
]]
function SharedColorService:ApplyColors(model: Model, name: string, colors: SlotMap?)
	local slots = defaults[name]
	if not slots then
		return
	end

	local final: SlotMap = table.clone(slots)
	for slot, packed in colors or {} do
		if slots[slot] then
			final[slot] = packed
		end
	end

	for _, part in model:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local slot = partSlot(part)
		if slot and final[slot] then
			part.Color = SharedColorService.Unpack(final[slot])
		end
	end
end

scanCatalog()

return SharedColorService
