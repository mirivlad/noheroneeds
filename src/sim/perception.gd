class_name Perception
## What a creature can honestly know (ADR-0018): only what it sees or hears.
##   sight   — within its sight, which shrinks in the dark: sight *
##             lerp(dark_sight, 1, light of the target's cell); what stands
##             in the way blocks it (Sight: walls, closed doors, plants by
##             their height, levels of buildings, windows but for one at them);
##   hearing — noises of the world (building, taking down) within its
##             hearing: where, not who.
## Nothing else: no positions read from the world that it could not perceive.


## How far the creature sees a target standing in light `light` (cells).
static func sight_range(def: Dictionary, light: float) -> float:
	return float(def["sight"]) * lerpf(float(def["dark_sight"]), 1.0, clampf(light, 0.0, 1.0))


## Whether a creature at `eye` in `location` sees the cell `at` of
## `at_location` (by default the same): within its sight in the light there,
## with nothing in the way (Sight: walls, plants, levels, openings).
## target_body: the height (storeys) of what is looked at (BodySize "body").
static func sees(world: ServerWorld, location: String, eye: Vector2i, def: Dictionary, at: Vector2i,
		at_location := "", target_body := Sight.BODY) -> bool:
	var there := location if at_location == "" else at_location
	# The same place named on the observer's side of the seam: what is a step
	# away across the seam is a step away, not a world.
	var near := world.near_cell(at, eye)
	var d := world.cell_distance(eye, near)
	var most := float(def["sight"])
	if world.has_daylight(there):  # rain and fog shorten it outdoors (ADR-0033)
		most *= world.sight_at(there, eye)
	if d > most:
		return false  # beyond sight even in full light: no need to ask the light
	# The light of the cell is asked only when it matters: no cell is darker
	# than the day indoors (in a location with daylight), so nearer than the
	# sight that leaves, it is seen whatever the light.
	var least := Daylight.outdoor_light(world.world_time) * Daylight.INDOOR_SHARE if world.has_daylight(there) else 0.0
	if d > sight_range(def, least) and d > sight_range(def, world.light_at(there, near)):
		return false
	var size := BodySize.of(def)
	return Sight.clear(world, location, eye, there, near, float(size["eye"]), target_body)


## Whether a noise at `at` reaches a creature at `ear`.
static func hears(world: ServerWorld, def: Dictionary, ear: Vector2i, at: Vector2i) -> bool:
	return world.distance(ear, at) <= float(def["hearing"])
