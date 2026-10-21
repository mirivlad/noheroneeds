extends TestCase
## ADR-0046 on the server: every use wears the copy in the hands (a blow of
## work, a hit, a shot), a blow taken wears armour; dull is slower, broken
## does nothing until mended at its station, and falls apart when it can be
## mended no more; a copy keeps its wear wherever it goes.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})
	for cy in [4, 5, 6]:
		for cx in [4, 5, 6]:
			var c := w.chunk("surface", cx, cy)
			for id: String in w.creatures.in_chunk("surface", cx, cy):
				w.creatures.remove(id)
			for y in Chunk.SIZE:
				for x in Chunk.SIZE:
					c.set_cell("ground", x, y, "base:grass")
					c.set_cell("cover", x, y, "")
					c.set_cell("structure", x, y, "")


func after_each() -> void:
	w.close()


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func _player(name: String, cell := Vector2i(170, 170)) -> String:
	var c := PortableCharacter.create(name, "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, _at(cell))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _wait(ticks: int) -> void:
	for i in ticks:
		w.tick += 1
		w.combat.step(w.tick)


func _plant(cell: Vector2i, plant: String) -> void:
	w.chunk("surface", cell.x >> 5, cell.y >> 5).set_cell("cover", cell.x & 31, cell.y & 31, plant)


func _chop(actor: String, cell: Vector2i, item: String) -> Dictionary:
	return _req(actor, {"type": "gather", "location": "surface", "x": cell.x, "y": cell.y, "layer": "cover", "item": item})


func _state(actor: String, item: String, copy := 0) -> Dictionary:
	return w.inventory(actor).state_of(item, copy)


func test_every_blow_wears_the_tool_dull_is_slower_broken_does_nothing() -> void:
	var a := _player("Аня")
	w.grant(a, "base:axe", 1)
	_req(a, {"type": "hold", "item": "base:axe"})
	var oak := Vector2i(171, 170)
	_plant(oak, "base:oak")
	for i in 3:
		_wait(20)
		check(_chop(a, oak, "base:axe").get("ok", false), "a blow")
	eq(_state(a, "base:axe"), {"wear": 3}, "three blows: three uses")
	# Fresh: ready again after its 0.7 s; dull: not yet.
	_chop(a, oak, "base:axe")
	_wait(15)
	check(_chop(a, oak, "base:axe").get("ok", false), "a sharp axe strikes again in 0.7 s")
	w.inventory(a).set_state("base:axe", 0, {"wear": 395})
	_wait(15)
	_chop(a, oak, "base:axe")
	_wait(15)
	eq(_chop(a, oak, "base:axe").get("reason"), "not_ready", "a dull one is slower")
	_wait(10)
	var r := {}
	for i in 10:
		_wait(20)
		r = _chop(a, oak, "base:axe")
		if r.has("broke"):
			break
	eq(r.get("broke"), "base:axe", "worn out: it breaks, and says so")
	eq(r.get("gone"), false, "a stone axe stays, to be mended")
	eq(w.inventory(a).count("base:axe"), 1)
	_wait(20)
	eq(_chop(a, oak, "base:axe").get("reason"), "broken", "a broken axe does nothing")
	# Flint is not mended: worn out, it falls apart.
	w.grant(a, "base:flint_axe", 1, [{"wear": 119}])
	_req(a, {"type": "hold", "item": "base:flint_axe"})
	_wait(20)
	r = _chop(a, oak, "base:flint_axe")
	eq([r.get("broke"), r.get("gone")], ["base:flint_axe", true], "the last blow of a flint axe")
	eq(w.inventory(a).count("base:flint_axe"), 0, "and it is gone")
	check(w.held_of(a) == "", "empty hands")


func test_mending_at_its_station_for_materials_a_few_times_then_it_is_spent() -> void:
	var a := _player("Аня")
	w.grant(a, "base:axe", 1, [{"wear": 400}])
	var mend := {"type": "mend", "item": "base:axe", "copy": 0}
	eq(_req(a, mend.duplicate()).get("reason"), "no_station", "a stone axe is mended at a workbench")
	w.grant(a, "base:workbench_item", 1)
	check(_req(a, {"type": "build", "location": "surface", "x": 171, "y": 171, "part": "base:workbench"}).get("ok", false), "a workbench")
	eq(_req(a, mend.duplicate()).get("reason"), "materials", "a mend takes materials")
	w.grant(a, "base:plank", 10)
	w.grant(a, "base:stone", 10)
	var r := _req(a, mend.duplicate())
	check(r.get("ok", false), str(r))
	eq(r.get("spent"), {"base:plank": 1, "base:stone": 1}, "broken: the whole mend")
	eq(r.get("mends_left"), 3)
	eq(_state(a, "base:axe"), {"repairs": 1})
	eq(Wear.limit(_content, "base:axe", _state(a, "base:axe")), 340, "it lasts less now")
	eq(_req(a, mend.duplicate()).get("reason"), "not_worn", "nothing to mend")
	for i in 3:
		w.inventory(a).set_state("base:axe", 0, Wear.used(_state(a, "base:axe"), 50))
		check(_req(a, mend.duplicate()).get("ok", false), "mend %d" % (i + 2))
	eq(w.inventory(a).count("base:plank"), 6, "a little wear costs one of each, rounded up")
	w.inventory(a).set_state("base:axe", 0, Wear.used(_state(a, "base:axe"), 10))
	eq(_req(a, mend.duplicate()).get("reason"), "worn_out", "four mends: no more")
	# Spent: when it breaks now it falls apart.
	w.inventory(a).set_state("base:axe", 0, Wear.used(_state(a, "base:axe"), 149))
	_req(a, {"type": "hold", "item": "base:axe"})
	var oak := Vector2i(169, 170)
	_plant(oak, "base:oak")
	_wait(20)
	r = _chop(a, oak, "base:axe")
	eq([r.get("broke"), r.get("gone")], ["base:axe", true], "spent: it falls apart")
	w.grant(a, "base:flint_axe", 1, [{"wear": 3}])
	eq(_req(a, {"type": "mend", "item": "base:flint_axe", "copy": 0}).get("reason"), "not_mendable", "flint is not mended")
	eq(_req(a, {"type": "mend", "item": "base:axe", "copy": 0}).get("reason"), "not_carried")


func test_a_copy_keeps_its_wear_wherever_it_goes() -> void:
	var a := _player("Аня")
	var b := _player("Боря", Vector2i(171, 170))
	w.grant(a, "base:axe", 2, [{"wear": 100}, {}])
	_req(a, {"type": "hold", "item": "base:axe", "copy": 1})
	eq(_state(a, "base:axe"), {}, "the copy taken up comes first: the new one")
	eq(_state(a, "base:axe", 1), {"wear": 100})
	var dropped := _req(a, {"type": "drop", "item": "base:axe", "count": 1, "copy": 1})
	check(dropped.get("ok", false), str(dropped))
	eq(w.items[dropped["entity"]].get("states"), [{"wear": 100}], "on the ground it is still worn")
	check(_req(b, {"type": "pickup", "entity": dropped["entity"]}).get("ok", false), "another picks it up")
	eq(_state(b, "base:axe"), {"wear": 100}, "worn as it was")
	check(_req(b, {"type": "transfer", "to": a, "item": "base:axe", "count": 1}).get("ok", false), "given back")
	eq(w.inventory(a).states_of("base:axe"), [{}, {"wear": 100}])
	# Into a chest and out.
	w.grant(a, "base:chest_item", 1)
	check(_req(a, {"type": "build", "location": "surface", "x": 170, "y": 171, "part": "base:chest"}).get("ok", false), "a chest")
	var chest := {"location": "surface", "x": 170, "y": 171}
	check(_req(a, chest.merged({"type": "store", "item": "base:axe", "count": 1, "copy": 1})).get("ok", false), "stored")
	eq(w.inventory(a).states_of("base:axe"), [{}], "the worn one went")
	check(_req(a, chest.merged({"type": "take", "item": "base:axe", "count": 1})).get("ok", false), "taken out")
	eq(w.inventory(a).states_of("base:axe"), [{}, {"wear": 100}], "worn as it was")
	# Worn armour on the body and off.
	w.grant(a, "base:leather_armor", 1, [{"wear": 30}])
	check(_req(a, {"type": "equip", "item": "base:leather_armor"}).get("ok", false), "put on")
	eq(w.worn_of(a)["armor"], ["base:leather_armor", {"wear": 30}], "it wears its wear")
	check(_req(a, {"type": "unequip", "slot": "armor"}).get("ok", false), "taken off")
	eq(_state(a, "base:leather_armor"), {"wear": 30})
	# Kept over a restart.
	w.close()
	w = ServerWorld.open(_db, _content)
	eq(w.inventory(a).states_of("base:axe"), [{}, {"wear": 100}], "saved with the inventory")


func test_hits_and_shots_wear_weapons_blows_taken_wear_armour() -> void:
	w.world_time = 12 * Daylight.HOUR_MS
	var a := _player("Аня")
	var b := _player("Боря", Vector2i(171, 170))
	w.combat.pvp = "free"
	w.grant(a, "base:spear", 1)
	_req(a, {"type": "hold", "item": "base:spear"})
	_wait(20)
	var aim := _at(Vector2i(170, 173))
	eq(_req(a, {"type": "attack", "item": "base:spear", "x": aim.x, "y": aim.y}).get("hit"), "", "a blow into the air")
	eq(_state(a, "base:spear"), {}, "does not wear the spear")
	w.grant(b, "base:leather_armor", 1)
	_req(b, {"type": "equip", "item": "base:leather_armor"})
	_wait(20)
	aim = _at(Vector2i(171, 170))
	eq(_req(a, {"type": "attack", "item": "base:spear", "x": aim.x, "y": aim.y}).get("hit"), b, "a hit")
	eq(_state(a, "base:spear"), {"wear": 1}, "wears the spear")
	eq(w.worn_of(b)["armor"][1], {"wear": 1}, "and the armour that took it")
	eq(w.combat.armor_of(b), 2)
	var data: Dictionary = w._known_character(b)["data"]
	data["equipment_states"]["armor"] = {"wear": 300}
	eq(w.combat.armor_of(b), 0, "broken armour keeps nothing off")
	# A shot wears the bow.
	w.grant(a, "base:bow", 1)
	w.grant(a, "base:arrow", 5)
	_req(a, {"type": "hold", "item": "base:bow"})
	_wait(20)
	aim = _at(Vector2i(170, 180))
	check(_req(a, {"type": "attack", "item": "base:bow", "x": aim.x, "y": aim.y}).get("ok", false), "a shot")
	eq(_state(a, "base:bow"), {"wear": 1}, "wears the bow")
	w.inventory(a).set_state("base:bow", 0, {"wear": 300})
	_wait(20)
	eq(_req(a, {"type": "attack", "item": "base:bow", "x": aim.x, "y": aim.y}).get("reason"), "broken", "a broken bow does not shoot")
	eq(w.inventory(a).count("base:arrow"), 4, "and spends no arrow")


func test_worn_armour_is_mended_on_the_body_and_dead_ones_things_keep_their_wear() -> void:
	var a := _player("Аня")
	w.grant(a, "base:iron_helmet", 1, [{"wear": 400}])
	_req(a, {"type": "equip", "item": "base:iron_helmet"})
	w.grant(a, "base:stone", 10)
	check(_req(a, {"type": "build", "location": "surface", "x": 171, "y": 171, "part": "base:forge"}).get("ok", false), "a forge")
	w.grant(a, "base:iron_ingot", 1)
	var r := _req(a, {"type": "mend", "slot": "headwear"})
	check(r.get("ok", false), str(r))
	eq(w.worn_of(a)["headwear"][1], {"repairs": 1}, "mended where it is worn")
	eq(w.inventory(a).count("base:iron_ingot"), 0, "for an ingot")
	w.grant(a, "base:pickaxe", 1, [{"wear": 77}])
	w.combat.hurt(a, 100, "")
	var found := {}
	for id: String in w.items:
		found[w.items[id]["item"]] = w.items[id].get("states", [])
	eq(found.get("base:pickaxe"), [{"wear": 77}], "what the dead carried keeps its wear")
	eq(found.get("base:iron_helmet"), [{"repairs": 1}], "and what it wore")

