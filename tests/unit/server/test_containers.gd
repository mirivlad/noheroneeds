extends TestCase
## ADR-0021: chests keep things (an inventory of their own, saved with the
## moves), hold so many cells, open for their owner, are taken apart empty.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 5})
	var c := w.chunk("surface", 0, 0)
	for y in 8:
		for x in 8:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")


func after_each() -> void:
	w.close()


func _player(name: String) -> String:
	var c := PortableCharacter.create(name, "base:humanoid_adult")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _at(r: Dictionary) -> Dictionary:
	r.merge({"location": "surface", "x": 4, "y": 3})
	return r


func test_a_chest_keeps_things_for_its_owner() -> void:
	var a := _player("Аня")
	w.grant(a, "base:plank", 20)
	w.grant(a, "base:stone", 30)
	check(_req(a, _at({"type": "build", "part": "base:chest"})).get("ok", false), "built")
	var r := _req(a, _at({"type": "store", "item": "base:stone", "count": 30}))
	eq(r.get("contents"), {"base:stone": 30}, "stone in")
	eq(w.inventory(a).count("base:stone"), 0)
	r = _req(a, _at({"type": "take", "item": "base:stone", "count": 12}))
	eq(r.get("contents"), {"base:stone": 18}, "a stack split: some taken out")
	eq(w.inventory(a).count("base:stone"), 12)
	var b := _player("Боря")
	eq(_req(b, _at({"type": "look_in"})).get("reason"), "not_owner", "not someone else's chest")
	eq(_req(a, _at({"type": "dismantle"})).get("reason"), "not_empty", "not taken apart with things in it")
	w.close()
	w = ServerWorld.open(_db, _content)
	var known: Dictionary = w._known_character(a)
	w.enter(known["owner"], PortableCharacter.from_data(known["data"]))
	w.move_character(a, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	eq(_req(a, _at({"type": "look_in"})).get("contents"), {"base:stone": 18}, "kept over a restart")


func test_a_chest_holds_so_many_cells() -> void:
	var a := _player("Аня")
	w.grant(a, "base:plank", 2000)
	_req(a, _at({"type": "build", "part": "base:chest"}))
	# Planks stack by 99: 16 cells hold 1584.
	eq(_req(a, _at({"type": "store", "item": "base:plank", "count": 1584})).get("ok"), true)
	eq(_req(a, _at({"type": "store", "item": "base:plank", "count": 1})).get("reason"), "full")


## Parts wear and break under blows (anyone's, unless the world forbids
## breaking others'), and are mended for materials; what one holds is seen.
func test_parts_break_under_blows_and_are_mended() -> void:
	var a := _player("Аня")
	w.grant(a, "base:plank", 20)
	w.grant(a, "base:axe", 1)
	_req(a, _at({"type": "build", "part": "base:wood_wall"}))
	_req(a, {"type": "hold", "item": "base:axe"})
	var r := _req(a, _at({"type": "strike_part", "item": "base:axe"}))
	eq(r.get("damage"), 4, "an axe takes 4 of 40")
	eq(_req(a, _at({"type": "strike_part", "item": "base:axe"})).get("reason"), "not_ready", "not again at once")
	for i in 4:
		w.tick += 20
		w.combat.step(w.tick)
		_req(a, _at({"type": "strike_part", "item": "base:axe"}))
	eq(int(w.chunk("surface", 0, 0).get_props(4, 3).get("damage", 0)), 20)
	var planks := w.inventory(a).count("base:plank")
	check(_req(a, _at({"type": "repair"})).get("ok", false), "mended")
	eq(planks - w.inventory(a).count("base:plank"), 1, "a little worn: a plank, rounded up")
	eq(int(w.chunk("surface", 0, 0).get_props(4, 3).get("damage", 0)), 0)
	var b := _player("Боря")
	w.break_others = false
	eq(_req(b, _at({"type": "strike_part"})).get("reason"), "not_owner", "not someone else's where the world forbids it")
	w.break_others = true  # the default (ADR-0016): anyone breaks anything
	_wear(4, 3, "structure", 3)
	for i in 40:
		w.tick += 20
		w.combat.step(w.tick)
		r = _req(b, _at({"type": "strike_part"}))
		if r.has("broken"):
			break
	eq(r.get("broken"), "base:wood_wall", "fists break it at last, where the world allows")
	eq(w.chunk("surface", 0, 0).get_cell("structure", 4, 3), "", "gone")
	var left := 0
	for id: String in w.items:
		if w.items[id]["item"] == "base:plank":
			left += int(w.items[id]["count"])
	eq(left, 1, "half of what it cost lies there")


func test_what_one_holds_is_seen() -> void:
	var a := _player("Аня")
	eq(_req(a, {"type": "hold", "item": "base:bow"}).get("reason"), "not_carried")
	w.grant(a, "base:bow", 1)
	check(_req(a, {"type": "hold", "item": "base:bow"}).get("ok", false), "held")
	eq(w.present[a]["held"], "base:bow")


## ADR-0007: nothing falls. A wall broken under a walkway leaves the walkway
## and the level over it; wear is kept over a restart.
func test_a_broken_wall_takes_nothing_else_and_wear_is_kept() -> void:
	var a := _player("Аня")
	w.grant(a, "base:plank", 50)
	w.grant(a, "base:axe", 1)
	_req(a, _at({"type": "build", "part": "base:wood_wall"}))
	_req(a, _at({"type": "build", "part": "base:wood_ceiling"}))
	_req(a, {"type": "build", "location": "surface", "x": 5, "y": 3, "part": "base:wood_wall"})
	_req(a, {"type": "hold", "item": "base:axe"})
	eq(_req(a, _at({"type": "strike_part"})).get("damage"), 4)
	w.flush_state()
	w.close()
	w = ServerWorld.open(_db, _content)
	eq(int(w.chunk("surface", 0, 0).get_props(4, 3).get("damage", 0)), 4, "wear kept over a restart")
	var known: Dictionary = w._known_character(a)
	w.enter(known["owner"], PortableCharacter.from_data(known["data"]))
	w.move_character(a, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	w.break_others = true
	var level := w.levels.level(w._ceiling_building("surface", 4, 3), 1)
	check(level != "", "a level over the walkway")
	_req(a, {"type": "hold", "item": "base:axe"})
	_wear(4, 3, "structure", 8)
	var r := {}
	for i in 20:
		w.tick += 20
		w.combat.step(w.tick)
		r = _req(a, _at({"type": "strike_part"}))
		if r.has("broken"):
			break
	eq(r.get("broken"), "base:wood_wall", "the wall under the walkway broken")
	eq(w.chunk("surface", 0, 0).get_cell("ceiling", 4, 3), "base:wood_ceiling", "the walkway stays")
	eq(w._part_at(level, 4, 3, "ground"), "base:wood_floor", "and the floor over it")
	eq(w.chunk("surface", 0, 0).get_cell("structure", 5, 3), "base:wood_wall", "the next wall untouched")
	w.tick += 20
	w.combat.step(w.tick)
	eq(_req(a, _at({"type": "strike_part", "location": "surface", "x": 4, "y": 3})).get("reason"), "unbreakable",
		"no wall there now: the walkway is struck by its layer")


## Worn almost through: `left` of its durability is left (long breaks made short).
func _wear(x: int, y: int, layer: String, left: int) -> void:
	var c := w.chunk("surface", 0, 0)
	var part := c.get_cell(layer, x, y)
	var props := c.get_props(x, y).duplicate()
	var worn: Dictionary = props if layer == "structure" else props.get(layer, {}).duplicate()
	worn["damage"] = float(int(_content.get_def(part)["durability"]) - left)
	if layer != "structure":
		props[layer] = worn
	c.set_props(x, y, props)
