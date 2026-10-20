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


func test_a_rod_fishes_in_water_and_the_water_stays() -> void:
	var a := _player("Аня")
	var c := w.chunk("surface", 0, 0)
	c.set_cell("ground", 4, 3, "base:water")
	var fish := {"type": "gather", "location": "surface", "x": 4, "y": 3, "layer": "ground"}
	eq(_req(a, fish.merged({"item": ""})).get("reason"), "no_tool", "no fish by hand")
	eq(_req(a, {"type": "gather", "location": "surface", "x": 3, "y": 4, "layer": "ground", "item": ""}).get("reason"),
		"nothing_to_gather", "grass holds no fish")
	# A rod is made at a workbench of a plank and a hide.
	w.grant(a, "base:log", 4)
	check(_req(a, {"type": "build", "location": "surface", "x": 2, "y": 3, "part": "base:workbench"}).get("ok", false), "workbench")
	w.grant(a, "base:plank", 1)
	w.grant(a, "base:hide", 1)
	eq(_req(a, {"type": "craft", "recipe": "base:make_fishing_rod", "count": 1}).get("made"), {"base:fishing_rod": 1})
	_req(a, {"type": "hold", "item": "base:fishing_rod"})
	var casts := 0
	var got := {}
	while got.is_empty() and casts < 60:
		w.tick += 40  # past the cast's cooldown
		w.combat.step(w.tick)
		var r := _req(a, fish.merged({"item": "base:fishing_rod"}))
		check(r.get("ok", false), "cast %d: %s" % [casts, str(r)])
		got = r.get("drops", {})
		casts += 1
	eq(got.size(), 1, "a fish, sooner or later (%d casts)" % casts)
	eq(c.get_cell("ground", 4, 3), "base:water", "the water is still there")
	# Cooked at a fire, eaten.
	w.grant(a, "base:log", 2)
	check(_req(a, {"type": "build", "location": "surface", "x": 3, "y": 2, "part": "base:campfire"}).get("ok", false), "a fire")
	w.grant(a, "base:raw_fish", 1)
	eq(_req(a, {"type": "craft", "recipe": "base:cook_fish", "count": 1}).get("made"), {"base:cooked_fish": 1})
	w.combat.hurt(a, 10, "")
	eq(_req(a, {"type": "eat", "item": "base:cooked_fish"}).get("health"), 14, "four back")


func test_a_hide_becomes_leather_and_leather_armour() -> void:
	var a := _player("Аня")
	w.grant(a, "base:log", 4)
	check(_req(a, {"type": "build", "location": "surface", "x": 4, "y": 3, "part": "base:workbench"}).get("ok", false), "workbench")
	w.grant(a, "base:hide", 4)
	eq(_req(a, {"type": "craft", "recipe": "base:tan_leather", "count": 4}).get("made"), {"base:leather": 4})
	eq(_req(a, {"type": "craft", "recipe": "base:make_leather_armor", "count": 1}).get("made"), {"base:leather_armor": 1})
	check(_req(a, {"type": "equip", "item": "base:leather_armor"}).get("ok", false), "worn in its own slot")
	eq(w.combat.armor_of(a), 2)


func test_a_pick_digs_the_nearest_rock_toward_the_aim_within_three_cells() -> void:
	var a := _player("Аня")  # at (3, 3)
	var c := w.chunk("surface", 0, 0)
	for x in [5, 6]:
		c.set_cell("structure", x, 3, "base:rock")
	c.set_cell("structure", 3, 8, "base:rock")
	w.grant(a, "base:pickaxe", 1)
	_req(a, {"type": "hold", "item": "base:pickaxe"})
	var dig := func(x: int, y: int, aim := Vector2i(-1, -1)) -> Dictionary:
		w.tick += 40
		w.combat.step(w.tick)
		var r := {"type": "gather", "location": "surface", "x": x, "y": y, "layer": "structure", "item": "base:pickaxe"}
		if aim.x >= 0:
			r["ax"] = aim.x
			r["ay"] = aim.y
		return _req(a, r)
	eq(dig.call(6, 3).get("reason"), "in_the_way", "not the rock behind another")
	eq(dig.call(6, 3, Vector2i(6 * 256 + 128, 3 * 256 + 128)).get("reason"), "in_the_way", "aimed at it either")
	check(dig.call(5, 3, Vector2i(6 * 256 + 128, 3 * 256 + 128)).get("ok", false), "the nearer one, aimed beyond it")
	while c.get_cell("structure", 5, 3) != "":
		dig.call(5, 3)
	check(dig.call(6, 3).get("ok", false), "dug through: the next one is reached")
	eq(dig.call(3, 8).get("reason"), "too_far", "five cells away: out of reach")
	check(Reach.digs(_content, "base:pickaxe") and Reach.digs(_content, "base:axe"), "a pick and an axe dig by the line")
	check(not Reach.digs(_content, "base:hoe") and not Reach.digs(_content, "base:fishing_rod"), "a hoe and a rod work where one points")


func test_a_bucket_is_filled_poured_milked_and_drunk() -> void:
	var a := _player("Аня")  # at (3, 3)
	var c := w.chunk("surface", 0, 0)
	c.set_cell("ground", 4, 3, "base:water")
	w.grant(a, "base:log", 4)
	check(_req(a, {"type": "build", "location": "surface", "x": 2, "y": 4, "part": "base:workbench"}).get("ok", false), "workbench")
	w.grant(a, "base:plank", 3)
	eq(_req(a, {"type": "craft", "recipe": "base:make_bucket", "count": 1}).get("made"), {"base:bucket": 1})
	_req(a, {"type": "hold", "item": "base:bucket"})
	eq(_req(a, {"type": "fill", "location": "surface", "x": 3, "y": 2, "item": "base:bucket"}).get("reason"), "nothing_to_fill", "grass")
	var r := _req(a, {"type": "fill", "location": "surface", "x": 4, "y": 3, "item": "base:bucket"})
	eq(r.get("now"), "base:water_bucket", "water taken up")
	eq(w.inventory(a).count("base:bucket"), 0)
	# Watered: a crop is six hours on, once in twelve.
	c.set_cell("ground", 3, 2, "base:farmland")
	c.set_cell("cover", 3, 2, "base:wheat_crop")
	w._set_layer_props(c, "cover", 3, 2, {"planted": w.world_time})
	_req(a, {"type": "hold", "item": "base:water_bucket"})
	r = _req(a, {"type": "pour", "location": "surface", "x": 3, "y": 2, "item": "base:water_bucket"})
	check(r.get("watered", false) and r.get("now") == "base:bucket", "watered, the bucket empty: %s" % str(r))
	eq(int(w._layer_props(c, "cover", 3, 2)["planted"]), w.world_time - 6 * Daylight.HOUR_MS)
	_req(a, {"type": "hold", "item": "base:bucket"})
	_req(a, {"type": "fill", "location": "surface", "x": 4, "y": 3, "item": "base:bucket"})
	_req(a, {"type": "hold", "item": "base:water_bucket"})
	eq(_req(a, {"type": "pour", "location": "surface", "x": 3, "y": 2, "item": "base:water_bucket"}).get("watered"), false, "not again so soon")
	_req(a, {"type": "hold", "item": "base:bucket"})
	eq(_req(a, {"type": "pour", "item": "base:bucket"}).get("reason"), "not_a_liquid")
	# A cow of one's own is milked, twice a day at most; another's is not.
	var cow := w.creatures._spawn("base:cow", "surface", Vector2i(3, 4), {}, 3)
	eq(_req(a, {"type": "fill", "creature": cow.id, "item": "base:bucket"}).get("reason"), "not_yours", "a wild cow")
	cow.owner = a
	eq(_req(a, {"type": "fill", "creature": cow.id, "item": "base:bucket"}).get("now"), "base:milk_bucket", "milked")
	w.grant(a, "base:bucket", 1)
	_req(a, {"type": "hold", "item": "base:bucket"})
	eq(_req(a, {"type": "fill", "creature": cow.id, "item": "base:bucket"}).get("reason"), "not_yet", "not again at once")
	_req(a, {"type": "hold", "item": "base:milk_bucket"})
	w.needs.set_satiety(a, 50.0)
	r = _req(a, {"type": "eat", "item": "base:milk_bucket"})
	check(r.get("ok", false) and r.get("now") == "base:bucket", "drunk, the bucket left: %s" % str(r))
	eq(w.inventory(a).count("base:bucket"), 2)


func test_ore_shut_in_rock_is_told_as_rock_until_dug_open() -> void:
	var depth := Levels.depth_id(-1)
	var c := w.chunk(depth, 0, 0)
	for y in range(0, 12):
		for x in range(0, 12):
			c.set_cell("structure", x, y, "base:rock")
	c.set_cell("structure", 5, 5, "base:iron_ore_rock")
	w._changed(ServerWorld.chunk_key(depth, 0, 0))
	var sent := func() -> String:
		return ChunkCodec.decode(w.encoded_chunk(depth, 0, 0)).get_cell("structure", 5, 5)
	var mapped := func() -> String:
		var t := MapTile.decode(w.map_tile(depth, 0, 0))
		return (t["palette"] as PackedStringArray)[(t["cells"] as PackedByteArray)[5 * Chunk.SIZE + 5]]
	eq(sent.call(), "base:rock", "shut in: sent as rock")
	eq(mapped.call(), "base:rock", "and on the map")
	eq(c.get_cell("structure", 5, 5), "base:iron_ore_rock", "the world keeps the ore")
	c.set_cell("structure", 5, 6, "")  # dug next to it
	w._changed(ServerWorld.chunk_key(depth, 0, 0))
	eq(sent.call(), "base:iron_ore_rock", "laid open: told as it is")
	eq(mapped.call(), "base:iron_ore_rock")
	# At a chunk's edge: digging in the next chunk tells this one again.
	c.set_cell("structure", 0, 8, "base:copper_ore_rock")
	var west := w.chunk(depth, -1, 0)
	west.set_cell("structure", 31, 8, "base:rock")
	w._changed(ServerWorld.chunk_key(depth, 0, 0))
	var west_of := func() -> String: return ChunkCodec.decode(w.encoded_chunk(depth, 0, 0)).get_cell("structure", 0, 8)
	eq(west_of.call(), "base:rock")
	var rev := w.chunk_revision(depth, 0, 0)
	west.set_cell("structure", 31, 8, "")
	w._changed(ServerWorld.chunk_key(depth, -1, 0))
	check(w.chunk_revision(depth, 0, 0) > rev, "the neighbour is told again")
	eq(west_of.call(), "base:copper_ore_rock", "and its ore shows")
