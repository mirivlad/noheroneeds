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
	if d > sight_range(def, world.light_at(location, at)):
		return false
	return line_clear(world, location, eye, at)


## Whether nothing opaque stands between two cells (the cells themselves do
## not count: a creature in a doorway still looks out).
static func line_clear(world: ServerWorld, location: String, a: Vector2i, b: Vector2i) -> bool:
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var p := a
	while p != b:
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			p.x += sx
		if e2 <= dx:
			err += dx
			p.y += sy
		if p != b and world.is_opaque(location, p.x, p.y):
			return false
	return true


## Whether a noise at `at` reaches a creature at `ear`.
static func hears(def: Dictionary, ear: Vector2i, at: Vector2i) -> bool:
	return Vector2(ear).distance_to(Vector2(at)) <= float(def["hearing"])
