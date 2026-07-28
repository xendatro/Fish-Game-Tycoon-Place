--[[
Stairs link one build level to the next. A stair occupies a run of cells on its own floor
and climbs a full Building.WALL_HEIGHT over that run, so the model's LENGTH is what sets
the slope - two cells of run against 8 studs of rise is 45 degrees.

Footprints are measured from the model like everything else in the catalog. A stair climbs
along its longer axis (see SharedBuildingService:GetStairRun), so it can be modelled facing
either way; only which END is the bottom step matters, and a stair that comes out facing
downhill is a 180-degree turn on the model in Studio.

A stair may not have a ceiling over any cell it occupies - that hole is what guests climb
through, and CanPlace rejects the placement (and FillCeilings the ceiling) either way
round. Guests approach from the cell in front of the bottom step and step off onto the
cell beyond the top one, a level up; see SharedNpcService's stair portals.
]]

return {
	TestStair = {
		Type = "Stair",
		-- A staircase carries itself: it can hang off the edge of an upper level with
		-- nothing under it, which is how you build one down into an open space.
		Floating = true,
	},
}
