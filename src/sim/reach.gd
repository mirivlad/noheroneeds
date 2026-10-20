class_name Reach
## What a digging or felling tool reaches (the author, 20.10.2026): not what
## the cursor is over but the first solid thing from the one who digs toward
## it, at most CELLS away — nothing behind something in the way. The client
## picks by it, the server checks by it, with the same rule.

const CELLS := 3
const NONE := Vector2i(1 << 30, 1 << 30)


## The first solid cell (`solid.call(x, y)`) on the line from `from`
## (movement units) toward `toward`, within CELLS cells; NONE if none.
static func first_solid(from: Vector2i, toward: Vector2, solid: Callable, cells := CELLS) -> Vector2i:
	var dir := toward - Vector2(from)
	if dir.length() < 1.0:
		return NONE
	dir = dir.normalized()
	var start := Movement.cell_of(from)
	var step := Movement.UNIT / 8.0
	var d := 0.0
	while d <= cells * Movement.UNIT:
		var cell := Movement.cell_of(Vector2i(Vector2(from) + dir * d))
		if cell != start and solid.call(cell.x, cell.y):
			return cell
		d += step
	return NONE


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
