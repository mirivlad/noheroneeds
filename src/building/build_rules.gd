class_name BuildRules
## Whether a part may be built on a cell (ADR-0007, ADR-0013, ADR-0017,
## ADR-0021): one set of rules for the server, which decides, and for the
## client, which shows a blueprint's cells as allowed or not before the
## button is let go. Each asks through its own view of the world:
##   view.build_chunk(location, cx, cy) -> Chunk (null: not known here)
##   view.build_kind(location) -> Levels kind
##   view.build_z(location) -> level label
##   view.build_max_levels() -> the server's height limit
##   view.build_someone_on(location, x, y) -> someone stands on the cell
## Reach and materials are asked apart (reaches(), and the costs), and what
## only the server sees (the depth below a shaft) stays with the server.

const NO_CELL := Vector2i(1 << 30, 1 << 30)


## "" if `part` may stand at (x, y) of `location` turned to `facing`, else
## the reason (the server's words); "unknown" where the view lacks the chunk.
## `actor`: who builds ("" — not asked: whose ceiling stairs would open).
static func check(view: Object, content: ContentRegistry, part: String, location: String, x: int, y: int,
		facing: String, actor := "") -> String:
	if content.kind_of(part) != "structure":
		return "unknown_part"
	var def := content.get_def(part)
	var role := String(def["role"])
	var kind := String(view.build_kind(location))
	if kind != Levels.SURFACE and kind != Levels.BUILDING_LEVEL and kind != Levels.DEPTH:
		return "no_such_place"
	if def.get("natural", false):
		return "not_buildable"
	if kind == Levels.DEPTH and role in ["ceiling", "roof", "stairs"]:
		return "underground"  # up is the depth above (ADR-0017)
	if def.get("surface_only", false) and kind != Levels.SURFACE or def.get("underground_only", false) and kind != Levels.DEPTH:
		return "wrong_place"
	var c: Chunk = view.build_chunk(location, x >> 5, y >> 5)
	if c == null:
		return "unknown"
	var lx := x & 31  # Chunk.SIZE is 32
	var ly := y & 31
	var on_level := kind != Levels.SURFACE
	if on_level and c.get_cell("ground", lx, ly) == "":
		return "no_floor"  # the contour of the level below
	if c.get_cell(Terrain.layer_for_role(role), lx, ly) != "":
		return "occupied"
	match role:
		"ceiling", "roof":
			if Terrain.is_covered(c, lx, ly):
				return "occupied"
			var under := c.get_cell("structure", lx, ly)
			if under != "" and content.get_def(under).get("role") == "stairs":
				return "stairs_here"  # stairs need the opening over them
			if not on_level and bool(content.get_def(c.get_cell("ground", lx, ly)).get("solid", false)):
				return "blocked"
			if role == "ceiling" and int(view.build_z(location)) + 1 > int(view.build_max_levels()):
				return "too_high"  # a server setting (ADR-0007)
		"stairs":
			# Stairs come up through an opening over themselves and lead onto
			# the floor their top faces (ADR-0007, ADR-0013). A ceiling over
			# them is taken away to make the opening — the builder's own only:
			# someone else's is broken, not taken apart (ADR-0016).
			if stairs_arrival(view, location, x, y, facing) == NO_CELL:
				return "no_landing"
			if c.get_cell("roof", lx, ly) != "":
				return "roof_above"
			if c.get_cell("ceiling", lx, ly) != "" and actor != "" \
					and String((c.get_props(lx, ly).get("ceiling", {}) as Dictionary).get("owner", "")) != actor:
				return "ceiling_not_yours"
			if Terrain.is_solid(c, lx, ly, content, on_level):
				return "blocked"
		_:
			if Terrain.is_solid(c, lx, ly, content, on_level):
				return "blocked"  # water, a tree...
			if view.build_someone_on(location, x, y):
				return "someone_there"
	return ""


## Within building reach of `pos` (movement units).
static func reaches(pos: Vector2i, x: int, y: int) -> bool:
	var centre := Vector2(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2)
	return Vector2(pos).distance_to(centre) <= ServerWorld.BUILD_REACH


## Whether a body at `pos` (movement units) covers any of cell (x, y).
static func stands_on(pos: Vector2i, x: int, y: int) -> bool:
	return pos.x + Movement.HALF_X > x * Movement.UNIT and pos.x - Movement.HALF_X < (x + 1) * Movement.UNIT \
		and pos.y + Movement.HALF_Y > y * Movement.UNIT and pos.y - Movement.HALF_Y < (y + 1) * Movement.UNIT


## The facing a part is built in: the one wanted if the part allows it, else
## its default (the first it lists); "" for parts that do not turn.
static func facing_of(def: Dictionary, wanted: String) -> String:
	var turns: Array = def.get("rotations", [])
	if turns.is_empty():
		return ""
	return wanted if turns.has(wanted) else String(turns[0])


## Where stairs at (x, y) facing `facing` would lead on the level above: the
## cell their top faces, if a ceiling there makes it a floor above (a
## landing); NO_CELL if not. Never their own cell: over the stairs is the
## opening they come up through, not a floor to stand on.
static func stairs_arrival(view: Object, location: String, x: int, y: int, facing: String) -> Vector2i:
	var top: Vector2i = Vector2i(x, y) + (ContentRegistry.FACINGS.get(facing, Vector2i(0, -1)) as Vector2i)
	if _ceiling_at(view, location, top.x, top.y):
		return top
	return NO_CELL


static func _ceiling_at(view: Object, location: String, x: int, y: int) -> bool:
	var c: Chunk = view.build_chunk(location, x >> 5, y >> 5)
	return c != null and c.get_cell("ceiling", x & 31, y & 31) != ""
