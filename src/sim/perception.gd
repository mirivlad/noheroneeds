class_name Perception
## What a creature can honestly know (ADR-0018): only what it sees or hears.
##   sight   — in its own location, within its sight, which shrinks in the
##             dark: sight * lerp(dark_sight, 1, light of the target's cell);
##             walls, closed doors and solid plants (trees, bushes) on the
##             line between block it;
##   hearing — noises of the world (building, taking down) within its
##             hearing: where, not who.
## Nothing else: no positions read from the world that it could not perceive.


## How far the creature sees a target standing in light `light` (cells).
static func sight_range(def: Dictionary, light: float) -> float:
	return float(def["sight"]) * lerpf(float(def["dark_sight"]), 1.0, clampf(light, 0.0, 1.0))


## Whether a creature at `eye` sees the cell `at` (same location).
static func sees(world: ServerWorld, location: String, eye: Vector2i, def: Dictionary, at: Vector2i) -> bool:
	var d := Vector2(eye).distance_to(Vector2(at))
	if d > float(def["sight"]):
		return false  # beyond sight even in full light: no need to ask the light
	# The light of the cell is asked only when it matters: no cell is darker
	# than the day indoors (in a location with daylight), so nearer than the
	# sight that leaves, it is seen whatever the light.
	var least := Daylight.outdoor_light(world.world_time) * Daylight.INDOOR_SHARE if world.has_daylight(location) else 0.0
	if d > sight_range(def, least) and d > sight_range(def, world.light_at(location, at)):
		return false
	return world.line_clear(location, eye, at)


## Whether nothing opaque stands between two cells (the cells themselves do
## not count: a creature in a doorway still looks out).
static func line_clear(world: ServerWorld, location: String, a: Vector2i, b: Vector2i) -> bool:
	return world.line_clear(location, a, b)


## Whether a noise at `at` reaches a creature at `ear`.
static func hears(def: Dictionary, ear: Vector2i, at: Vector2i) -> bool:
	return Vector2(ear).distance_to(Vector2(at)) <= float(def["hearing"])
