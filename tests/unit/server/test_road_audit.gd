extends TestCase
## Old worlds (ADR-0038): a road may still run into open water where the way
## now crosses it. The audit names such cells and, with apply, lays a bridge
## deck over clear common water — never on land, deep water, a building, a
## plant, props or something lying there.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry
var _spots: Array = []


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})
	_spots = _water_road_cells()


func after_each() -> void:
	w.close()


## Water cells the current roads cross (the audit's candidates), nearest first.
func _water_road_cells() -> Array:
	var out := []
	var seen := {}
	var s := w.generator.settlements
	var home := s.home_plan()
	var centre: Vector2i = home["centre"]
	var d := s._district_of(0, centre)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for road: Dictionary in s.roads_of(0, d.x + dx, d.y + dy):
				for at: Vector2i in road["cells"]:
					if seen.has(at):
						continue
					if String(w.generator.land_at(at.x, at.y, false).get("what", "")) != "water":
						continue
					seen[at] = true
					out.append(at)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - centre).length_squared() < (b - centre).length_squared())
	return out


## The chunk of a candidate, stored, with the cell turned back into the open
## water an older world may still have there.
func _open_water(at: Vector2i) -> Chunk:
	var cx := floori(float(at.x) / Chunk.SIZE)
	var cy := floori(float(at.y) / Chunk.SIZE)
	var c := w.chunk("surface", cx, cy)
	w.sync()  # the audit reads the chunks kept in the world
	var lx := posmod(at.x, Chunk.SIZE)
	var ly := posmod(at.y, Chunk.SIZE)
	c.set_cell("ground", lx, ly, "base:water")
	for layer: String in ["cover", "structure", "roof", "ceiling"]:
		c.set_cell(layer, lx, ly, "")
	c.set_props(lx, ly, {})
	return c


func _spot(n: int) -> Vector2i:
	return _spots[n] if n < _spots.size() else _spots[0]


func test_a_water_gap_on_a_road_is_named_and_then_bridged() -> void:
	check(not _spots.is_empty(), "seed 11 has roads crossing water")
	if _spots.is_empty():
		return
	var at := _spot(0)
	var c := _open_water(at)
	var lx := posmod(at.x, Chunk.SIZE)
	var ly := posmod(at.y, Chunk.SIZE)
	var dry := w.road_audit(false)
	check((dry["bridged"] as Array).has(at), "the audit names the water on the road")
	eq(c.get_cell("ground", lx, ly), "base:water", "a report changes nothing")
	var done := w.road_audit(true)
	check((done["bridged"] as Array).has(at), "the cell is bridged on apply")
	eq(c.get_cell("ground", lx, ly), "base:bridge", "a bridge deck is laid")
	eq(c.get_cell("cover", lx, ly), "", "and the cell is left clear")
	var again := w.road_audit(true)
	check(not (again["bridged"] as Array).has(at), "a second run finds it bridged")
	# It is kept in the world, not only in memory.
	w.sync()
	w.close()
	w = ServerWorld.open(_db, _content, {})
	var back := w.chunk("surface", floori(float(at.x) / Chunk.SIZE), floori(float(at.y) / Chunk.SIZE))
	eq(back.get_cell("ground", lx, ly), "base:bridge", "the bridge is saved with the chunk")


func test_deep_water_on_a_road_is_named_but_never_bridged() -> void:
	check(not _spots.is_empty(), "seed 11 has roads crossing water")
	if _spots.is_empty():
		return
	var at := _spot(0)
	var c := _open_water(at)
	var lx := posmod(at.x, Chunk.SIZE)
	var ly := posmod(at.y, Chunk.SIZE)
	c.set_cell("ground", lx, ly, "base:deep_water")
	var report := w.road_audit(true)
	check((report["deep"] as Array).has(at), "deep water is named")
	check(not (report["bridged"] as Array).has(at), "and never bridged")
	eq(c.get_cell("ground", lx, ly), "base:deep_water", "deep water stays as it is")


func test_a_building_plant_props_or_item_on_the_water_is_only_named() -> void:
	check(_spots.size() >= 4, "seed 11 has enough water cells for the cases")
	if _spots.size() < 4:
		return
	var cases := [
		["structure", "base:wood_wall"],
		["cover", "base:reeds"],
	]
	for i in cases.size():
		var at := _spot(i)
		var c := _open_water(at)
		var lx := posmod(at.x, Chunk.SIZE)
		var ly := posmod(at.y, Chunk.SIZE)
		c.set_cell(String(cases[i][0]), lx, ly, String(cases[i][1]))
		var report := w.road_audit(true)
		check((report["blocked"] as Array).has(at), "the occupied cell is named: " + str(cases[i]))
		check(not (report["bridged"] as Array).has(at), "and no bridge is laid: " + str(cases[i]))
		eq(c.get_cell("ground", lx, ly), "base:water", "the water stays: " + str(cases[i]))
		eq(c.get_cell(String(cases[i][0]), lx, ly), String(cases[i][1]), "the thing stays: " + str(cases[i]))
	# An item lying on the water.
	var at := _spot(2)
	var c := _open_water(at)
	var id := w.place_item("surface", at * Movement.UNIT + Vector2i(128, 128), "base:log", 1)
	check(id != "", "a thing lies in the water")
	var report := w.road_audit(true)
	check((report["blocked"] as Array).has(at), "the cell with a thing on it is named")
	eq(c.get_cell("ground", posmod(at.x, Chunk.SIZE), posmod(at.y, Chunk.SIZE)), "base:water",
		"and no bridge is laid under it")