extends TestCase
## ADR-0031: a cast catches by luck — the water's chance, better at dawn and
## dusk; a fish of a kind by weight; a place fished out comes back in time.

var w: ServerWorld
var _content: ContentRegistry
var a := ""


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 3})
	w.world_time = 9 * Daylight.HOUR_MS + Daylight.DAY_MS  # an hour of plain luck
	var c := w.chunk("surface", 0, 0)
	for y in 32:
		for x in 32:
			c.set_cell("ground", x, y, "base:water" if x >= 5 else "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")
	var pc := PortableCharacter.create("Аня", "base:human_m")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + pc.character_id, pc)
	a = pc.character_id
	w.move_character(a, Vector2i(4 * 256 + 128, 16 * 256 + 128))
	w.grant(a, "base:fishing_rod", 1)
	_req({"type": "hold", "item": "base:fishing_rod"})


func after_each() -> void:
	w.close()


func _req(r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(a, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _cast(x: int, y: int) -> Dictionary:
	w.tick += 40
	w.combat.step(w.tick)
	return _req({"type": "gather", "location": "surface", "x": x, "y": y, "layer": "ground", "item": "base:fishing_rod"})


func test_a_cast_is_luck_and_the_kinds_go_by_weight() -> void:
	var bites := 0
	var kinds := {}
	var casts := 0
	var c := w.chunk("surface", 0, 0)
	for i in 600:
		var r := _cast(5, 16)
		check(r.get("ok", false), str(r))
		c.set_props(5, 16, {})  # a place not fished before, every time
		casts += 1
		if r.get("bite", false):
			bites += 1
			for k: String in r["drops"]:
				kinds[k] = int(kinds.get(k, 0)) + 1
	var share := float(bites) / casts
	check(share > 0.18 and share < 0.42, "about three casts in ten: %.2f of %d" % [share, casts])
	check(int(kinds.get("base:raw_fish", 0)) > int(kinds.get("base:perch", 0)) and int(kinds.get("base:perch", 0)) > int(kinds.get("base:pike", 0)),
		"roach most, perch less, pike rarest: %s" % str(kinds))
	check(int(kinds.get("base:pike", 0)) > 0, "but a pike now and then")
	var held := 0
	for k: String in kinds:
		held += w.inventory(a).count(k)
	eq(held, bites, "every catch is in the bag")


func test_a_place_fished_out_comes_back() -> void:
	var catches := 0
	for i in 200:
		if _cast(5, 16).get("bite", false):
			catches += 1
	eq(catches, 6, "a place gives its stock and no more")
	var r := _cast(5, 16)
	check(float(r.get("chance", 1.0)) < 0.01, "fished out: no chance (%s)" % str(r))
	w.world_time += 8 * Daylight.HOUR_MS
	check(float(_cast(5, 16).get("chance", 0.0)) > 0.05, "eight hours on: fish again (two of six back)")


func test_dawn_and_dusk_bite_best() -> void:
	var at := func(h: float) -> float: return ServerWorld.bite_hour(int(h * Daylight.HOUR_MS))
	check(at.call(6.0) > at.call(9.0) and at.call(19.0) > at.call(9.0), "dawn and dusk above the morning")
	check(at.call(13.0) < at.call(9.0) and at.call(0.5) < at.call(9.0), "noon and midnight below")


func test_malformed_luck_is_a_content_error() -> void:
	var item := {"id": "test:fish", "kind": "item"}
	var water := {"id": "test:w", "kind": "ground", "gather": {"tool": "", "verb": "x", "drops": {}, "chance": 0.5, "pick": {"test:fish": 1}}}
	eq(ContentRegistry.from_defs([item, water]).errors, PackedStringArray())
	for bad: Dictionary in [{"chance": 0}, {"chance": 2}, {"pick": {}}, {"pick": {"test:none": 1}}, {"stock": 0}]:
		var g: Dictionary = water["gather"].merged(bad, true)
		check(not ContentRegistry.from_defs([item, water.merged({"gather": g}, true)]).errors.is_empty(), "refused: %s" % str(bad))
	var plant := {"id": "test:p", "kind": "plant", "gather": water["gather"]}
	check(not ContentRegistry.from_defs([item, plant]).errors.is_empty(), "luck is a ground's only")
