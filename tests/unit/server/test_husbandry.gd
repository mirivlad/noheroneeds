extends TestCase
## ADR-0030: animals fed what they eat become one's own, follow the one who
## holds it out, stay where they were led, give produce and young when fed.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})
	w.world_time = 10 * Daylight.HOUR_MS  # day: nobody rests
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			w.chunk("surface", 5 + dx, 5 + dy)
	for id: String in w.creatures.creatures.keys():
		w.creatures.remove(id)
	var c := w.chunk("surface", 5, 5)
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")


func after_each() -> void:
	w.close()


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func _player(cell: Vector2i) -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, _at(cell))
	return c.character_id


func _spawn(kind: String, cell: Vector2i) -> Creature:
	return w.creatures._spawn(kind, "surface", cell, {}, 7)


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _hold(actor: String, item: String) -> void:
	_req(actor, {"type": "hold", "item": item})


func _feed(actor: String, c: Creature, item: String) -> Dictionary:
	return _req(actor, {"type": "feed", "creature": c.id, "item": item})


func _ticks(n: int) -> void:
	for i in n:
		w.tick += 1
		w.advance_time()
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				w.mark_needed("surface", 5 + dx, 5 + dy)
		w.creatures.step(w.tick)


func test_fed_what_it_eats_it_becomes_ones_own() -> void:
	var a := _player(Vector2i(170, 170))
	var sheep := _spawn("base:sheep", Vector2i(171, 170))
	w.grant(a, "base:wheat", 5)
	w.grant(a, "base:stone", 1)
	_hold(a, "base:stone")
	eq(_feed(a, sheep, "base:stone").get("reason"), "not_its_food")
	_hold(a, "base:wheat")
	eq(_feed(a, sheep, "base:stone").get("reason"), "not_held", "what one holds, not what one names")
	var r := _feed(a, sheep, "base:wheat")
	check(r.get("ok", false) and not r.get("tamed"), "one feed of two: %s" % str(r))
	eq(sheep.owner, "", "still wild")
	r = _feed(a, sheep, "base:wheat")
	check(r.get("tamed", false), "the second: tamed")
	eq(sheep.owner, a)
	eq(sheep.home, Vector2i(171, 170), "its home is where it was tamed")
	eq(w.inventory(a).count("base:wheat"), 3, "two eaten")
	eq(_feed(a, sheep, "base:wheat").get("reason"), "fed_already", "one's own is not fed again while full")
	var wolf := _spawn("base:wolf", Vector2i(169, 170))
	eq(_feed(a, wolf, "base:wheat").get("reason"), "not_tameable")
	var far := _spawn("base:sheep", Vector2i(180, 170))
	eq(_feed(a, far, "base:wheat").get("reason"), "too_far")
	# Kept across a restart, with its owner.
	var id := sheep.id
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	eq(w.creatures.get_creature(id).owner, a, "still hers after a restart")


func test_a_wild_one_lets_food_come_close_and_runs_from_empty_hands() -> void:
	var sheep := _spawn("base:sheep", Vector2i(170, 170))
	var a := _player(Vector2i(172, 170))
	w.grant(a, "base:wheat", 1)
	_hold(a, "base:wheat")
	_ticks(30)
	check(sheep.state != "flee" and sheep.cell().distance_to(Vector2i(170, 170)) <= 10.0,
		"held out wheat: it stays (%s at %s)" % [sheep.state, sheep.cell()])
	_hold(a, "")
	w.move_character(a, sheep.pos + Vector2i(2 * Movement.UNIT, 0))
	_ticks(30)
	check(sheep.state in ["flee", "alert"], "empty hands: it runs (%s)" % sheep.state)


func test_ones_own_follows_the_food_and_stays_where_it_was_led() -> void:
	var a := _player(Vector2i(170, 170))
	var cow := _spawn("base:cow", Vector2i(171, 170))
	w.grant(a, "base:carrot", 4)
	_hold(a, "base:carrot")
	for i in 3:
		_feed(a, cow, "base:carrot")
	eq(cow.owner, a, "three carrots: hers")
	w.move_character(a, _at(Vector2i(178, 170)))
	_ticks(200)
	check(cow.cell().x >= 175, "it followed the carrot: %s" % cow.cell())
	_hold(a, "")
	w.move_character(a, _at(Vector2i(160, 170)))
	_ticks(300)
	check(cow.cell().x >= 173, "left there, it keeps there: %s (home %s)" % [cow.cell(), cow.home])
	check(cow.home.x >= 175, "its home moved with it")


func test_fed_ones_give_produce_and_young() -> void:
	var a := _player(Vector2i(170, 170))
	var hens: Array[Creature] = [_spawn("base:chicken", Vector2i(171, 170)), _spawn("base:chicken", Vector2i(171, 171))]
	w.grant(a, "base:wheat_seeds", 4)
	_hold(a, "base:wheat_seeds")
	for h: Creature in hens:
		check(_feed(a, h, "base:wheat_seeds").get("tamed", false), "a hen tamed with one feed")
	_hold(a, "")
	w.move_character(a, _at(Vector2i(160, 160)))
	_ticks(20)
	var mine := w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.kind == "base:chicken")
	eq(mine.size(), 3, "two fed hens near each other: a chick")
	var chick: Creature = mine.filter(func(c: Creature) -> bool: return not hens.has(c))[0]
	eq(chick.owner, a, "the owner's")
	_ticks(20)
	eq(w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.kind == "base:chicken").size(), 3,
		"not again until breed_hours have passed")
	var eggs := func() -> int:
		var n := 0
		for id: String in w.items:
			if w.items[id]["item"] == "base:egg":
				n += int(w.items[id]["count"])
		return n
	eq(eggs.call(), 0, "no egg yet")
	w.world_time += 12 * Daylight.HOUR_MS
	_ticks(20)
	eq(eggs.call(), 2, "twelve hours on, adults lay; the chick is too young")
	# An empty pen, rather than grass the hens can eat themselves.
	var ch := w.chunk("surface", 5, 5)
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			ch.set_cell("ground", x, y, "base:sand")
	w._changed(ServerWorld.chunk_key("surface", 5, 5))
	w.world_time += 30 * Daylight.HOUR_MS
	_ticks(20)
	eq(eggs.call(), 2, "hungry hens do not lay")


func test_grazing_does_not_prevent_accepting_the_owners_food() -> void:
	w.world_time += 30 * Daylight.HOUR_MS
	var a := _player(Vector2i(170, 170))
	var cow := _spawn("base:cow", Vector2i(171, 170))
	cow.owner = a
	cow.fed_at = w.world_time - 30 * Daylight.HOUR_MS
	cow.ate_at = cow.fed_at
	w.grant(a, "base:carrot", 1)
	_ticks(20)
	check(w.world_time - cow.ate_at < Daylight.HOUR_MS, "grazed without help")
	w.move_character(a, cow.pos - Vector2i(Movement.UNIT, 0))
	w.grant(a, "base:bucket", 1)
	_hold(a, "base:bucket")
	eq(_req(a, {"type": "fill", "creature": cow.id, "item": "base:bucket"}).get("now"), "base:milk_bucket",
		"a self-fed cow gives milk")
	_hold(a, "base:carrot")
	w.move_character(a, cow.pos - Vector2i(Movement.UNIT, 0))
	check(_feed(a, cow, "base:carrot").get("ok", false), "still accepts the owner's offer after grazing")
	eq(w.inventory(a).count("base:carrot"), 0)
	eq(cow.fed_at, w.world_time, "the hand feeding clock is independent of grazing")


func test_self_fed_adults_lay_eggs_and_have_young() -> void:
	var hens: Array[Creature] = [_spawn("base:chicken", Vector2i(170, 170)), _spawn("base:chicken", Vector2i(171, 170))]
	for h: Creature in hens:
		h.owner = "keeper"
		h.made_at = w.world_time
		h.bred_at = -1  # newly tamed pair: its first offspring is due
	w.world_time += 30 * Daylight.HOUR_MS
	for h: Creature in hens:
		h.last_time = w.world_time
	_ticks(25)
	eq(w.items.values().filter(func(it: Dictionary) -> bool: return it["item"] == "base:egg").size(), 2,
		"self-fed adult hens lay eggs")
	eq(w.creatures.creatures.size(), 3, "the self-fed pair has a chick")
	for h: Creature in hens:
		eq(h.fed_at, -1, "no hand feeding was needed")


func test_owners_held_food_takes_priority_over_pasture_and_dropped_feed() -> void:
	w.world_time += 30 * Daylight.HOUR_MS
	var a := _player(Vector2i(175, 170))
	var cow := _spawn("base:cow", Vector2i(170, 170))
	cow.owner = a
	cow.ate_at = w.world_time - 30 * Daylight.HOUR_MS
	var before := cow.ate_at
	var dropped := w.place_item("surface", cow.pos, "base:carrot", 2)
	w.grant(a, "base:carrot", 1)
	_hold(a, "base:carrot")
	_ticks(50)
	eq(cow.ate_at, before, "it waits for the owner's offer instead of grazing")
	check(cow.cell().x >= 173, "it followed the owner: %s" % cow.cell())
	check(w.items.has(dropped), "left the dropped food alone while following")
	_hold(a, "")
	_ticks(160)
	check(cow.ate_at > before, "with the offer withdrawn it finds food itself")
	eq(w.items.values().filter(func(it: Dictionary) -> bool: return it["item"] == "base:carrot").size(), 1)
	var left: Dictionary = w.items.values().filter(func(it: Dictionary) -> bool: return it["item"] == "base:carrot")[0]
	eq(left["count"], 1, "one meal, not the whole stack")
	check(cow.fed_at > 0, "player-provided feed has priority over grass")


func test_malformed_husbandry_is_a_content_error() -> void:
	var item := {"id": "test:grain", "kind": "item"}
	var beast := {"id": "test:b", "kind": "creature", "behavior": "prey", "speed": 1, "run_speed": 1,
		"tame": {"food": ["test:grain"], "feeds": 2, "breed_hours": 10}, "produce": {"item": "test:grain", "hours": 5}}
	eq(ContentRegistry.from_defs([item, beast]).errors, PackedStringArray())
	for bad: Dictionary in [{"tame": {"food": []}}, {"tame": {"food": ["test:none"]}}, {"tame": {"food": ["test:grain"], "feeds": 0}},
			{"produce": {"item": "test:grain", "hours": 0}}, {"produce": {"item": "test:none", "hours": 5}}]:
		check(not ContentRegistry.from_defs([item, beast.merged(bad, true)]).errors.is_empty(), "refused: %s" % str(bad))
	var wild := beast.duplicate()
	wild.erase("tame")
	check(not ContentRegistry.from_defs([item, wild]).errors.is_empty(), "produce without tame: refused")
