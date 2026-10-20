extends TestCase
## ADR-0026: recipes made at their station within reach, from what one
## carries, all or nothing, once per request; food heals up to one's most.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 5})
	var c := w.chunk("surface", 0, 0)
	for y in 12:
		for x in 12:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")


func after_each() -> void:
	w.close()


func _player(name: String) -> String:
	var c := PortableCharacter.create(name, "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	if not r.has("request_id"):
		r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func test_a_recipe_needs_its_station_near_and_all_it_takes() -> void:
	var a := _player("Аня")
	w.grant(a, "base:log", 10)
	var saw := {"type": "craft", "recipe": "base:saw_planks", "count": 2}
	eq(_req(a, saw.duplicate()).get("reason"), "no_station", "no workbench: no planks")
	check(_req(a, {"type": "build", "location": "surface", "x": 4, "y": 3, "part": "base:workbench"}).get("ok", false),
		"a workbench of logs")
	eq(w.inventory(a).count("base:log"), 6)
	var r := _req(a, saw.duplicate())
	check(r.get("ok", false), "at the workbench: %s" % str(r))
	eq(r.get("made"), {"base:plank": 8}, "twice four planks")
	eq(w.inventory(a).count("base:log"), 4)
	eq(w.inventory(a).count("base:plank"), 8)
	eq(_req(a, {"type": "craft", "recipe": "base:saw_planks", "count": 5}).get("reason"), "not_enough",
		"five logs asked, four carried")
	eq(w.inventory(a).count("base:log"), 4, "nothing taken when not all is there")
	eq(w.inventory(a).count("base:plank"), 8)
	# Walked away: the station is out of reach.
	w.move_character(a, Vector2i(9 * 256 + 128, 9 * 256 + 128))
	eq(_req(a, saw.duplicate()).get("reason"), "no_station", "too far from the workbench")
	check(not w.station_near(a, "forge"), "no forge anywhere")


func test_the_same_request_makes_once_and_bad_ones_are_refused() -> void:
	var a := _player("Аня")
	w.grant(a, "base:log", 4)
	check(_req(a, {"type": "build", "location": "surface", "x": 3, "y": 4, "part": "base:workbench"}).get("ok", false), "workbench")
	w.grant(a, "base:log", 4)
	var r := {"type": "craft", "recipe": "base:saw_planks", "count": 1, "request_id": "same"}
	check(_req(a, r.duplicate()).get("ok", false), "made")
	check(_req(a, r.duplicate()).get("ok", false), "the repeat answers the same")
	eq(w.inventory(a).count("base:plank"), 4, "but makes nothing again")
	for bad: Dictionary in [{"recipe": "base:nothing"}, {"recipe": "base:saw_planks", "count": 0},
			{"recipe": "base:saw_planks", "count": 1000}, {"recipe": "base:log"}]:
		eq(_req(a, bad.merged({"type": "craft"})).get("reason"), "bad_request", str(bad))


func test_a_chain_from_ore_to_ingot_and_meat_to_health() -> void:
	var a := _player("Аня")
	w.grant(a, "base:stone", 10)
	w.grant(a, "base:log", 4)
	check(_req(a, {"type": "build", "location": "surface", "x": 4, "y": 3, "part": "base:forge"}).get("ok", false), "a forge")
	check(_req(a, {"type": "build", "location": "surface", "x": 2, "y": 3, "part": "base:campfire"}).get("ok", false), "a fire")
	w.grant(a, "base:iron_ore", 4)
	w.grant(a, "base:log", 2)
	eq(_req(a, {"type": "craft", "recipe": "base:smelt_iron", "count": 2}).get("made"), {"base:iron_ingot": 2})
	w.grant(a, "base:raw_meat", 2)
	eq(_req(a, {"type": "craft", "recipe": "base:cook_meat", "count": 2}).get("made"), {"base:cooked_meat": 2})
	eq(_req(a, {"type": "eat", "item": "base:cooked_meat"}).get("reason"), "not_hungry", "full health: not eaten")
	eq(w.inventory(a).count("base:cooked_meat"), 2)
	w.combat.hurt(a, 10, "")
	var r := _req(a, {"type": "eat", "item": "base:cooked_meat"})
	eq(r.get("health"), 16, "six back")
	r = _req(a, {"type": "eat", "item": "base:cooked_meat"})
	eq(r.get("health"), 20, "never above the most")
	eq(w.inventory(a).count("base:cooked_meat"), 0)
	eq(_req(a, {"type": "eat", "item": "base:cooked_meat"}).get("reason"), "not_enough")
	eq(_req(a, {"type": "eat", "item": "base:stone"}).get("reason"), "not_food")


func test_malformed_recipes_and_food_are_content_errors() -> void:
	var item := {"id": "test:x", "kind": "item"}
	var good := {"id": "test:r", "kind": "recipe", "inputs": {"test:x": 1}, "outputs": {"test:x": 2}, "station": "anvil"}
	eq(ContentRegistry.from_defs([item, good]).errors, PackedStringArray())
	for bad: Array in [[good.merged({"station": ""}, true)], [good.merged({"station": 3}, true)],
			[item.merged({"food": {"heal": 0}}, true)], [item.merged({"food": "bread"}, true)]]:
		var defs: Array = [item if bad[0]["kind"] == "recipe" else good] + bad
		check(not ContentRegistry.from_defs(defs).errors.is_empty(), "refused: %s" % str(bad[0]))


func test_an_iron_axe_fells_twice_as_fast() -> void:
	var a := _player("Аня")
	var c := w.chunk("surface", 0, 0)
	c.set_cell("cover", 4, 3, "base:birch")  # eight blows of a stone axe
	c.set_cell("cover", 2, 3, "base:birch")
	var fell := func(tool: String, x: int) -> int:
		w.grant(a, tool, 1)
		_req(a, {"type": "hold", "item": tool})
		var blows := 0
		while c.get_cell("cover", x, 3) != "" and blows < 20:
			w.tick += 40  # past the swing's cooldown
			w.combat.step(w.tick)
			_req(a, {"type": "gather", "location": "surface", "x": x, "y": 3, "layer": "cover", "item": tool})
			blows += 1
		return blows
	eq(fell.call("base:axe", 4), 8)
	eq(fell.call("base:iron_axe", 2), 4, "power 2: half the blows")
	check(_content.get_def("base:iron_pickaxe")["against"]["stone"] > _content.get_def("base:pickaxe")["against"]["stone"],
		"an iron pick breaks stone sooner too")
