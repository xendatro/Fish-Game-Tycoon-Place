return {
	Money = 0,
	Fish = {
		--[[
		{
			Name = string
			ObjectId = nil/objectId, --objectId is placed tank
			Size = "Tiny"|"Small"|"Medium"|"Large"|"Huge",
			Modifier = string?
		}
		]]
	},
	-- One saved colour palette per placeable, keyed by catalog name. Each is stored as a
	-- FLAT {slot, packedColor, slot, packedColor, ...} array: a sparse {[slot] = colour}
	-- map would come back from the datastore with string keys. See SharedColorService.
	CustomPalettes = {},
	Build = {
		Palette = {},
		ColorSets = {},
		Placements = {},
		Floors = {},
		Ceilings = {},
	},
}
