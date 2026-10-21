extends TestCase
## ADR-0056: plants live — what is picked comes back, a felled tree leaves a
## stump, a sapling comes up, a young tree, a tree of its kind again; not
## while it freezes there; a chunk away from everyone catches up when it
## comes back, as if it had grown step by step; a sapling is planted.

var w: ServerWorld
var _content: ContentRegistry
var _db := ""


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	_db = tmp_dir().path_join("world.db")
	_open()
	var c := w.chunk("surface", 0, 0)
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")
	for id: String in w.creatures.in_chunk("surface", 0, 0):
		w.creatures.remove(id)


func _open() -> void:
	w = ServerWorld.open(_db, _content, {"seed": 2})
	w.world_time = Daylight.DAY_MS  # spring: nothing frozen


func after_each() -> void:
	w.close()


func _player() -> String:
	var ch := PortableCharacter.create("Аня", "base:human_m")
	ch.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + ch.character_id, ch)
	w.move_character(ch.character_id, Vector2i(10 * 256 + 128, 10 * 256 + 128))
	return ch.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _work(a: String, x: int, y: int, item := "") -> void:
	for i in 40:
		for t in 25:
			w.tick += 1
			w.combat.step(w.tick)
		var r := {"type": "gather", "location": "surface", "x": x, "y": y, "layer": "cover"}
		if item != "":
			r["item"] = item
		if _req(a, r).has("drops"):
			return


func _cover(x: int, y: int) -> String:
	return w.chunk("surface", 0, 0).get_cell("cover", x, y)


func _hours(h: float) -> void:
	w.world_time += int(h * Daylight.HOUR_MS)
	w.growth.catch_up("surface", 0, 0, w.chunk("surface", 0, 0))


func test_picked_grass_comes_back() -> void:
	var a := _player()
	w.chunk("surface", 0, 0).set_cell("cover", 11, 10, "base:tall_grass")
	_work(a, 11, 10)
	eq(_cover(11, 10), "", "picked")
	_hours(20.0)
	eq(_cover(11, 10), "", "not yet")
	_hours(5.0)
	eq(_cover(11, 10), "base:tall_grass", "back after a day")


func test_a_felled_tree_grows_back_through_its_ages() -> void:
	var a := _player()
	w.grant(a, "base:axe", 1)
	_req(a, {"type": "hold", "item": "base:axe"})
	w.chunk("surface", 0, 0).set_cell("cover", 11, 10, "base:birch")
	_work(a, 11, 10, "base:axe")
	eq(_cover(11, 10), "base:stump", "a stump is left")
	_hours(97.0)
	eq(_cover(11, 10), "base:sapling", "a sapling by it")
	_hours(97.0)
	eq(_cover(11, 10), "base:young_tree", "a young tree")
	_hours(193.0)
	eq(_cover(11, 10), "base:birch", "a birch again: of its own kind")
	eq((w.chunk("surface", 0, 0).get_props(11, 10).get("cover", {}) as Dictionary).has("grow"), false, "grown up")


## A chunk away from everyone (out of memory) catches up when it comes back,
## to the same as one watched all along.
func test_catching_up_comes_to_the_same_as_growing_on() -> void:
	w.world_time = Seasons.SUMMER * Seasons.SEASON_MS  # no frost in the days before nor after
	var c := w.chunk("surface", 0, 0)
	for x in 5:
		c.set_cell("cover", x, 3, "base:stump")
		w.set_cover_props(c, x, 3, {"grow": {"since": w.world_time - x * 40 * Daylight.HOUR_MS, "species": "base:oak"}})
	w.growth.arrived("surface", 0, 0, c)
	var start := w.world_time
	# Step by step, an hour at a time, for 300 hours.
	var stepwise: Array = []
	var copy := Chunk.new()
	copy = c.snapshot()
	for h in 300:
		_hours(1.0)
	for x in 5:
		stepwise.append(_cover(x, 3))
	# The same from the start, at once.
	var c2 := w.chunk("surface", 0, 0)
	for x in 5:
		c2.set_cell("cover", x, 3, copy.get_cell("cover", x, 3))
		w.set_cover_props(c2, x, 3, copy.get_props(x, 3).get("cover", {}))
	w.world_time = start
	_hours(300.0)
	for x in 5:
		eq(_cover(x, 3), stepwise[x], "stump %d: the same either way" % x)
	check(stepwise.has("base:oak") and stepwise.has("base:young_tree"), "grown on: %s" % [stepwise])


func test_kept_through_a_restart_and_nothing_grows_in_frost() -> void:
	var a := _player()
	w.chunk("surface", 0, 0).set_cell("cover", 11, 10, "base:boletus")
	_work(a, 11, 10)
	eq(_cover(11, 10), "", "picked")
	w.world_time = Seasons.WINTER * Seasons.SEASON_MS + Daylight.DAY_MS  # into the frost
	w.handle("nobody", {"request_id": "x", "type": "noop"})
	w.close()
	_open()
	w.world_time = Seasons.WINTER * Seasons.SEASON_MS + 4 * Daylight.DAY_MS
	var climate := w.climate_at("surface", Vector2i(11, 10))
	if Seasons.freezing(w.world_time, climate.x):
		w.growth.catch_up("surface", 0, 0, w.chunk("surface", 0, 0))
		eq(_cover(11, 10), "base:boletus", "it grew before the frost (spring, summer, autumn passed)")
	eq((w.chunk("surface", 0, 0).get_props(11, 10).get("cover", {}) as Dictionary).has("grow"), false, "and is done growing")
	# Picked in the frost: it does not come back until the frost is over.
	if not Seasons.freezing(w.world_time, climate.x):
		return
	var b := _player()
	w.chunk("surface", 0, 0).set_cell("cover", 13, 10, "base:tall_grass")
	w.move_character(b, Vector2i(12 * 256 + 128, 10 * 256 + 128))
	_work(b, 13, 10)
	eq(_cover(13, 10), "", "picked in winter")
	_hours(72.0)
	eq(_cover(13, 10), "", "three winter days: nothing")
	w.world_time = Seasons.YEAR_MS + 2 * Daylight.DAY_MS  # spring again
	w.growth.catch_up("surface", 0, 0, w.chunk("surface", 0, 0))
	eq(_cover(13, 10), "base:tall_grass", "back in the spring")


func test_a_sapling_is_dug_up_and_planted() -> void:
	var a := _player()
	w.chunk("surface", 0, 0).set_cell("cover", 11, 10, "base:sapling")
	_work(a, 11, 10)
	eq(w.inventory(a).count("base:seedling"), 1, "dug up")
	var tree := w.growth.tree_of("surface", 12, 10)
	var r := _req(a, {"type": "plant", "item": "base:seedling", "x": 12, "y": 10})
	if tree == "":
		eq(r.get("reason"), "no_trees_here", "no trees grow here")
		return
	check(r.get("ok", false), "planted: %s" % r)
	eq(_cover(12, 10), "base:sapling")
	_hours(97.0 + 193.0)
	eq(_cover(12, 10), tree, "the tree of the place")
	eq(_req(a, {"type": "plant", "item": "base:seedling", "x": 12, "y": 10}).get("reason"), "not_carried")
