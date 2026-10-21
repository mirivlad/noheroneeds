extends TestCase
## ADR-0027: a hoe turns ground into a field, a seed sown there grows by the
## world's clock, ripe it is gathered by hand for its crop and new seeds.

var w: ServerWorld
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 5})
	var c := w.chunk("surface", 0, 0)
	for y in 10:
		for x in 10:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")


func after_each() -> void:
	w.close()


func _player() -> String:
	var c := PortableCharacter.create("Аня", "base:human_f")
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


func _at(r: Dictionary, x := 4, y := 3) -> Dictionary:
	return r.merged({"location": "surface", "x": x, "y": y})


func test_till_sow_grow_and_reap() -> void:
	var a := _player()
	var c := w.chunk("surface", 0, 0)
	eq(_req(a, _at({"type": "till"})).get("reason"), "no_tool", "bare hands do not plough")
	w.grant(a, "base:hoe", 1)
	_req(a, {"type": "hold", "item": "base:hoe"})
	check(_req(a, _at({"type": "till", "item": "base:hoe"})).get("ok", false), "tilled")
	eq(c.get_cell("ground", 4, 3), "base:farmland")
	eq(_req(a, _at({"type": "till", "item": "base:hoe"})).get("reason"), "not_tillable", "a field is a field")
	c.set_cell("ground", 2, 3, "base:sand")
	eq(_req(a, _at({"type": "till", "item": "base:hoe"}, 2)).get("reason"), "not_tillable", "sand is not ploughed")
	eq(_req(a, _at({"type": "sow", "item": "base:wheat_seeds"})).get("reason"), "not_carried")
	w.grant(a, "base:wheat_seeds", 2)
	eq(_req(a, _at({"type": "sow", "item": "base:wheat_seeds"}, 3, 4)).get("reason"), "not_a_field", "seed on grass")
	check(_req(a, _at({"type": "sow", "item": "base:wheat_seeds"})).get("ok", false), "sown")
	eq(c.get_cell("cover", 4, 3), "base:wheat_crop")
	eq(w.inventory(a).count("base:wheat_seeds"), 1)
	eq(_req(a, _at({"type": "sow", "item": "base:wheat_seeds"})).get("reason"), "occupied", "one crop a cell")
	var reap := _at({"type": "gather", "layer": "cover", "item": "base:hoe"})
	eq(_req(a, reap.duplicate()).get("reason"), "not_ripe", "just sown")
	var crop := _content.get_def("base:wheat_crop")
	var sown := float((c.get_props(4, 3)["cover"] as Dictionary)["planted"])
	eq(Crops.stage(crop, sown, sown), 0)
	eq(Crops.stage(crop, sown, sown + 24 * Daylight.HOUR_MS), 1, "a day: past the first stage")
	w.world_time += 48 * Daylight.HOUR_MS
	check(Crops.ripe(crop, sown, w.world_time), "two days: ripe")
	var r := _req(a, reap.duplicate())
	eq(r.get("drops"), {"base:wheat": 2, "base:wheat_seeds": 2}, "the crop and new seed")
	eq(c.get_cell("cover", 4, 3), "", "reaped")
	eq(c.get_cell("ground", 4, 3), "base:farmland", "the field stays")


func test_seeds_from_the_wild_and_bread_from_the_field() -> void:
	var a := _player()
	var c := w.chunk("surface", 0, 0)
	c.set_cell("cover", 4, 3, "base:tall_grass")
	c.set_cell("cover", 2, 3, "base:clover")
	eq(_req(a, _at({"type": "gather", "layer": "cover"})).get("drops"), {"base:wheat_seeds": 1}, "grass gives wheat seed")
	eq(_req(a, _at({"type": "gather", "layer": "cover"}, 2)).get("drops"), {"base:carrot_seeds": 1}, "clover gives carrot seed")
	w.grant(a, "base:stone", 10)
	_req(a, _at({"type": "build", "part": "base:forge"}))
	w.grant(a, "base:wheat", 3)
	eq(_req(a, {"type": "craft", "recipe": "base:bake_bread"}).get("made"), {"base:bread": 1})


func test_malformed_fields_are_content_errors() -> void:
	var good := {"id": "test:g", "kind": "ground"}
	for bad: Dictionary in [{"id": "test:a", "kind": "ground", "tilled": "test:none"},
			{"id": "test:b", "kind": "plant", "crop": {"stages": 1, "grow_hours": 5}},
			{"id": "test:c", "kind": "plant", "crop": {"stages": 3}},
			{"id": "test:d", "kind": "item", "plants": "test:g"}]:
		check(not ContentRegistry.from_defs([good, bad]).errors.is_empty(), "refused: %s" % str(bad))


func test_a_fence_keeps_out_but_is_seen_over_and_a_gate_opens() -> void:
	var a := _player()
	w.grant(a, "base:plank", 20)
	for x in [3, 5]:
		check(_req(a, _at({"type": "build", "part": "base:wood_fence"}, x, 5)).get("ok", false), "fence")
	check(_req(a, _at({"type": "build", "part": "base:wood_gate"}, 4, 5)).get("ok", false), "gate")
	check(w.is_solid("surface", 3, 5) and w.is_solid("surface", 4, 5), "a fence and a shut gate stop one")
	# A man's eyes see over a fence (half a storey); a hare's do not.
	check(Sight.clear(w, "surface", Vector2i(3, 3), "surface", Vector2i(3, 7)), "seen over the fence")
	check(not Sight.clear(w, "surface", Vector2i(3, 3), "surface", Vector2i(3, 7), 0.2, 0.2), "a hare behind it is hidden")
	w.move_character(a, Vector2i(4 * 256 + 128, 4 * 256 + 128))
	check(_req(a, _at({"type": "use"}, 4, 5)).get("ok", false), "the gate opens")
	check(not w.is_solid("surface", 4, 5), "an open gate lets through")
	check(not w.is_solid("surface", 6, 5), "beside the fence is open")


## The wild's gifts: berries off a bush (the bush stays, picked), mushrooms
## by hand, stone off a boulder with a pick.
func test_berries_mushrooms_and_stone_from_the_wild() -> void:
	var a := _player()
	var c := w.chunk("surface", 0, 0)
	c.set_cell("cover", 4, 3, "base:berry_bush")
	c.set_cell("cover", 2, 3, "base:boletus")
	c.set_cell("cover", 3, 4, "base:boulder")
	eq(_req(a, _at({"type": "gather", "layer": "cover"})).get("drops"), {"base:berries": 3}, "berries picked")
	eq(c.get_cell("cover", 4, 3), "base:bush", "the bush stays, picked")
	eq(_req(a, _at({"type": "gather", "layer": "cover"}, 2)).get("drops"), {"base:mushroom": 3}, "a boletus")
	eq(c.get_cell("cover", 2, 3), "", "taken")
	eq(_req(a, _at({"type": "gather", "layer": "cover", "item": ""}, 3, 4)).get("reason"), "no_tool", "a boulder wants a pick")
	w.grant(a, "base:pickaxe", 1)
	_req(a, {"type": "hold", "item": "base:pickaxe"})
	var r := {}
	for i in 8:
		w.tick += 20  # the pick's pace
		w.combat.step(w.tick)
		r = _req(a, _at({"type": "gather", "layer": "cover", "item": "base:pickaxe"}, 3, 4))
		if r.has("drops"):
			break
	eq(r.get("drops"), {"base:stone": 2}, "stone off a boulder: " + str(r))
