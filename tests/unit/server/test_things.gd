extends TestCase
## ADR-0048: things of their own and stacks. What is worn, held, worked with
## or set up is a copy of its own, never stacked; materials stack. Furniture
## is made, set up from the bag and taken down the very same copy — its
## quality, maker, damage; smashed, it is wreckage; it lasts by how well it
## was made. Many copies move at once.

var w: ServerWorld
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 5})
	w.knowledge.never_fail = true  # what is made, not the dice
	var c := w.chunk("surface", 0, 0)
	for y in 12:
		for x in 12:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")


func after_each() -> void:
	w.close()


func _player(name: String, n := 1) -> String:
	var c := PortableCharacter.create(name, "base:human_m")
	c.character_id = "00000000-0000-4000-8000-%012d" % n
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


func _at(x: int, r: Dictionary) -> Dictionary:
	return r.merged({"location": "surface", "x": x, "y": 3})


func test_finished_things_never_stack_materials_do() -> void:
	for id: String in _content.defs:
		var d := _content.get_def(id)
		if d.get("kind") != "item":
			continue
		if d.has("equip_slot") or d.has("tools") or d.has("weapon") or d.has("places") or d.has("liquid") or int(d.get("armor", 0)) > 0:
			eq(Bag.stack_of(_content, id), 1, "%s: a thing of its own" % id)
	for id: String in ["base:log", "base:plank", "base:stone", "base:fiber", "base:iron_ore", "base:arrow", "base:coin"]:
		check(Bag.stack_of(_content, id) > 1, "%s: stacks" % id)
	eq(Bag.stack_of(_content, "base:bucket"), 1, "a bucket is a thing of its own now")
	var a := _player("Аня")
	w.grant(a, "base:axe", 3, [{"quality": 0.6}, {"quality": 0.9, "by": "Мастер"}, {}])
	eq(Bag.used(_content, w.inventory(a).stacks), 3, "three axes, three cells")
	var cells: Array = Bag.lay_out(_content, w.inventory(a).stacks, [])["cells"]
	eq(cells.filter(func(c: Array) -> bool: return c[0] == "base:axe").size(), 3)


func test_furniture_is_made_set_up_and_taken_down_the_same_copy() -> void:
	var a := _player("Аня")
	w.grant(a, "base:log", 4)
	var r := _req(a, {"type": "craft", "recipe": "base:make_workbench", "count": 1})
	check(r.get("ok", false), "a workbench made in the hands: %s" % str(r))
	var made := w.inventory(a).state_of("base:workbench_item", 0)
	eq(made.get("by"), "Аня", "with its maker's name")
	check(made.has("quality"), "and a quality: %s" % str(made))
	check(_req(a, _at(4, {"type": "build", "part": "base:workbench"})).get("ok", false), "set up from the bag")
	eq(w.inventory(a).count("base:workbench_item"), 0, "it left the bag")
	var props := w.chunk("surface", 0, 0).get_props(4, 3)
	eq(props.get("made"), made, "the part keeps the copy")
	eq(w.part_durability(_content.get_def("base:workbench"), props), roundi(780 * Wear.quality(made)), "lasts by how well it was made")
	check(w.station_near(a, "workbench"), "and works as a station")
	# Struck a little, taken down: the same copy, its damage with it.
	w.grant(a, "base:axe", 1)
	_req(a, {"type": "hold", "item": "base:axe"})
	check(_req(a, _at(4, {"type": "strike_part"})).get("ok", false), "struck")
	check(_req(a, _at(4, {"type": "dismantle"})).get("ok", false), "taken down")
	var back := w.inventory(a).state_of("base:workbench_item", 0)
	eq(back.get("by"), "Аня")
	eq(back.get("quality"), made.get("quality"))
	check(float(back.get("damage", 0)) > 0.0, "and its damage: %s" % str(back))
	check(_req(a, _at(5, {"type": "build", "part": "base:workbench"})).get("ok", false), "set up again")
	check(float(w.chunk("surface", 0, 0).get_props(5, 3).get("damage", 0)) > 0.0, "still damaged")
	# Mended with boards, not with another workbench.
	w.grant(a, "base:plank", 5)
	var m := _req(a, _at(5, {"type": "repair"}))
	check(m.get("ok", false), str(m))
	check((m["spent"] as Dictionary).has("base:plank") and not (m["spent"] as Dictionary).has("base:workbench_item"), "boards")


func test_smashed_furniture_is_wreckage() -> void:
	var a := _player("Аня", 1)
	var b := _player("Боря", 2)
	w.grant(a, "base:bed_item", 1, [{"quality": 0.5}])
	check(_req(a, _at(4, {"type": "build", "part": "base:bed"})).get("ok", false), "a bed")
	eq(w.part_durability(_content.get_def("base:bed"), w.chunk("surface", 0, 0).get_props(4, 3)), 300, "half made, half as strong")
	w.grant(b, "base:axe", 1)
	_req(b, {"type": "hold", "item": "base:axe"})
	var r := {}
	for i in 200:
		w.tick += 20
		w.combat.step(w.tick)
		w.inventory(b).set_state("base:axe", 0, {})
		r = _req(b, _at(4, {"type": "strike_part"}))
		if r.has("broken"):
			break
	eq(r.get("broken"), "base:bed", "smashed")
	var lying := {}
	for id: String in w.items:
		lying[w.items[id]["item"]] = int(lying.get(w.items[id]["item"], 0)) + int(w.items[id]["count"])
	eq(lying, {"base:plank": 3, "base:cloth": 1}, "wreckage: what it is mended with")


func test_a_bucket_stays_the_same_bucket() -> void:
	var a := _player("Аня")
	var c := w.chunk("surface", 0, 0)
	c.set_cell("ground", 4, 3, "base:water")
	w.grant(a, "base:bucket", 1, [{"by": "Бондарь"}])
	_req(a, {"type": "hold", "item": "base:bucket"})
	var r := _req(a, {"type": "fill", "location": "surface", "x": 4, "y": 3, "item": "base:bucket"})
	check(r.get("ok", false), str(r))
	eq(w.inventory(a).state_of("base:water_bucket", 0), {"by": "Бондарь"}, "filled, the cooper's bucket")
	_req(a, {"type": "hold", "item": "base:water_bucket"})
	r = _req(a, {"type": "pour", "location": "surface", "x": 5, "y": 3, "item": "base:water_bucket"})
	check(r.get("ok", false), str(r))
	eq(w.inventory(a).state_of("base:bucket", 0), {"by": "Бондарь"}, "poured out, still his")


func test_many_copies_move_at_once_each_as_it_is() -> void:
	var a := _player("Аня")
	var axes := [{"quality": 0.6}, {"quality": 0.9, "by": "Мастер"}, {"wear": 50}]
	w.grant(a, "base:axe", 3, axes)
	w.grant(a, "base:chest_item", 1)
	check(_req(a, _at(4, {"type": "build", "part": "base:chest"})).get("ok", false), "a chest")
	check(_req(a, _at(4, {"type": "store", "item": "base:axe", "count": 3})).get("ok", false), "all three at once")
	var look := _req(a, _at(4, {"type": "look_in"}))
	eq((look["states"] as Dictionary).get("base:axe"), axes, "each as it was")
	check(_req(a, _at(4, {"type": "take", "item": "base:axe", "count": 3})).get("ok", false), "and back")
	eq(w.inventory(a).states_of("base:axe"), axes)
	var dropped := _req(a, {"type": "drop", "item": "base:axe", "count": 2})
	eq(w.items[dropped["entity"]].get("states"), axes.slice(1), "two on the ground, each as it was")
	check(_req(a, {"type": "pickup", "entity": dropped["entity"]}).get("ok", false), "picked up")
	eq(w.inventory(a).states_of("base:axe"), axes)
