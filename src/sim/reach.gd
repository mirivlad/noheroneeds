class_name Reach
## What a digging or felling tool reaches (the author, 20.10.2026): not what
## the cursor is over but the nearest solid thing from the one who digs in the
## direction of it (within ARC degrees either way, the author, 28.10.2026), at
## most CELLS away — nothing behind something in the way. The client picks by
## it, the server checks by it, with the same rule.

const CELLS := 3
const NONE := Vector2i(1 << 30, 1 << 30)
## Degrees either side of the aim a blow still finds its mark, and the lines looked along.
const ARC := 40.0
const LINES := 9


## The nearest solid cell (`solid.call(x, y)`) from `from` (movement units) in
## the direction of `toward`: the first one on each line within ARC of it, the
## nearest of those (the straighter on a tie), within CELLS cells; NONE if none.
static func first_solid(from: Vector2i, toward: Vector2, solid: Callable, cells := CELLS) -> Vector2i:
	var dir := toward - Vector2(from)
	if dir.length() < 1.0:
		return NONE
	dir = dir.normalized()
	var best := NONE
	var best_d := INF
	for i in LINES:
		var turn := deg_to_rad(ARC) * (float(i) / (LINES - 1) * 2.0 - 1.0)
		var d := _along(from, dir.rotated(turn), solid, cells)
		var hit: Vector2i = d[0]
		var key := float(d[1]) + absf(turn) * 0.01  # the straighter of two as near
		if hit != NONE and key < best_d:
			best = hit
			best_d = key
	return best


## [the first solid cell on a line, how far along it] ([NONE, INF] if none).
static func _along(from: Vector2i, dir: Vector2, solid: Callable, cells: int) -> Array:
	var start := Movement.cell_of(from)
	var step := Movement.UNIT / 8.0
	var d := 0.0
	while d <= cells * Movement.UNIT:
		var cell := Movement.cell_of(Vector2i(Vector2(from) + dir * d))
		if cell != start and solid.call(cell.x, cell.y):
			return [cell, d]
		d += step
	return [NONE, INF]


## Whether a held thing digs or fells by this rule: its tools gather solid
## parts or plants (a pick, an axe; not a hoe, a rod, a sickle on grass).
static func digs(content: ContentRegistry, item: String) -> bool:
	if item == "":
		return false
	var tools: Array = content.get_def(item).get("tools", [])
	if tools.is_empty():
		return false
	for kind: String in _solid_tools(content):
		if tools.has(kind):
			return true
	return false


static var _tools_of := {}


static func _solid_tools(content: ContentRegistry) -> Dictionary:
	var key := content.get_instance_id()
	if not _tools_of.has(key):
		var kinds := {}
		for id: String in content.defs:
			var d := content.get_def(id)
			var k := content.kind_of(id)
			if (k == "structure" or k == "plant") and d.has("gather") and d.get("solid", k == "structure") \
					and String(d["gather"].get("tool", "")) != "":
				kinds[String(d["gather"]["tool"])] = true
		_tools_of = {key: kinds}
	return _tools_of[key]
