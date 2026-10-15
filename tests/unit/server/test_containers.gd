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
