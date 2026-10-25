extends TestCase
## ADR-0057: actual creatures, terrain, combat and persistent world rows.

var w: ServerWorld
var content: ContentRegistry
var db := ""
const HERE := Vector2i(170, 170)


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, content, {"seed": 11})
	w.world_time = 12 * Daylight.HOUR_MS
	for cy in range(4, 7):
		for cx in range(4, 7):
			_field(Vector2i(cx, cy))
	for id: String in w.creatures.creatures.keys():
		w.creatures.remove(id)


func after_each() -> void:
	w.close()


func _field(patch: Vector2i, ground := "base:grass") -> void:
	var ch := w.chunk(Levels.SURFACE, patch.x, patch.y)
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			for layer: String in ["ground", "cover", "structure", "ceiling", "roof"]:
				ch.set_cell(layer, x, y, ground if layer == "ground" else "")
			ch.set_props(x, y, {})
	w._changed(ServerWorld.chunk_key(Levels.SURFACE, patch.x, patch.y))


func _spawn(kind: String, at := HERE) -> Creature:
	return w.creatures._spawn(kind, Levels.SURFACE, at, {}, 7)


func _ticks(n: int) -> void:
	for i in n:
		w.tick += 1
		w.advance_time()
		for cy in range(4, 7):
			for cx in range(4, 7):
				w.mark_needed(Levels.SURFACE, cx, cy)
		w.creatures.step(w.tick)
		w.combat.step(w.tick)


func _later(hours: int) -> void:
	w.world_time += hours * Daylight.HOUR_MS
	# This suite isolates life from the existing offscreen position catch-up.
	for c: Creature in w.creatures.creatures.values():
		c.last_time = w.world_time


func test_wild_birth_requires_a_living_pair_and_is_not_a_respawn() -> void:
	var a := _spawn("base:hare")
	_later(48)
	_ticks(20)
	eq(w.creatures.creatures.size(), 1, "a solitary survivor cannot replace the hunted")
	var b := _spawn("base:hare", a.cell() + Vector2i.RIGHT)
	_later(48)
	_ticks(20)  # both forage and discover each other on their normal schedule
	check(w.creatures.life.ready(a, content.get_def(a.kind)) and w.creatures.life.ready(b, content.get_def(b.kind)), "both parents ready")
	check(a.memory.has(b.id), "the pair sees each other")
	_later(1)
	_ticks(25)
	eq(w.creatures.creatures.size(), 3, "a living, fed pair has one offspring")
	var child: Creature
	for c: Creature in w.creatures.creatures.values():
		if c != a and c != b:
			child = c
	if not check(child != null, "the offspring exists"):
		return
	check(w.creatures.life.young(child, content.get_def(child.kind)), "born young")
	var born := child.born_at
	var cid := child.id
	w.close()
	w = ServerWorld.open(db, content)
	w.chunk(Levels.SURFACE, child.cell().x >> 5, child.cell().y >> 5)
	eq(w.creatures.get_creature(cid).born_at, born, "birth date survives a restart")
	for id: String in w.creatures.creatures.keys():
		w.creatures.remove(id)
	w.close()
	w = ServerWorld.open(db, content)
	w.chunk(Levels.SURFACE, 5, 5)
	_later(96)
	_ticks(40)
	eq(w.creatures.creatures.size(), 0, "empty hunting grounds stay empty across reload and time")


func test_vegetation_and_shared_food_limit_births() -> void:
	var hare := content.get_def("base:hare")
	eq(w.creatures.life.capacity(hare, Levels.SURFACE, Vector2i(5, 5)), 8, "grass supports eight hares")
	_spawn("base:deer")
	_spawn("base:deer", HERE + Vector2i(1, 0))
	eq(w.creatures.life.pressure(hare, Levels.SURFACE, Vector2i(5, 5)), 4.0, "two deer eat four hares' share")
	var a := _spawn("base:hare", HERE + Vector2i(0, 1))
	var b := _spawn("base:hare", HERE + Vector2i(1, 1))
	_field(Vector2i(5, 5), "base:sand")
	eq(w.creatures.life.capacity(hare, Levels.SURFACE, Vector2i(5, 5)), 0, "changed terrain invalidates food cache")
	_later(48)
	a.memory[b.id] = {"pos": b.cell(), "time": w.world_time, "what": "animal"}
	w.creatures.life._breed(a, hare)
	eq(w.creatures.creatures.size(), 4, "no food, no birth")
	w.world_time = 3 * Seasons.SEASON_MS + 12 * Daylight.HOUR_MS
	_field(Vector2i(5, 5))
	check(w.creatures.life.capacity(hare, Levels.SURFACE, Vector2i(5, 5)) < 8, "frozen pasture supports fewer animals")


func test_crowding_moves_a_survivor_to_empty_neighbouring_land() -> void:
	_field(Vector2i(5, 5), "base:sand")
	var c := _spawn("base:hare", Vector2i(189, 176))
	var id := c.id
	_later(1)
	for i in 220:
		_ticks(1)
		if c.home.x >= 192:
			break
	check(c.cell().x >= 192, "walked over the chunk boundary: %s" % c.cell())
	eq(c.id, id, "the original survivor, not a replacement")
	eq(w.creatures.creatures.size(), 1)
	check(c.home.x >= 192, "the empty neighbouring ground is now home: %s" % c.home)
	check(w.creatures.in_chunk(Levels.SURFACE, 6, 5, c.kind).has(id), "new patch's species index follows the animal")
	check(not w.creatures.in_chunk(Levels.SURFACE, 5, 5, c.kind).has(id), "old species index no longer sees it")


func test_solid_fences_block_dispersal_and_pairing() -> void:
	var a := _spawn("base:chicken")
	var b := _spawn("base:chicken", HERE + Vector2i(2, 0))
	for c: Creature in [a, b]:
		c.owner = "keeper"
		c.fed_at = w.world_time
		c.bred_at = -1
	var ch := w.chunk(Levels.SURFACE, 5, 5)
	ch.set_cell("structure", 171 - 160, 170 - 160, "base:wood_wall")
	check(not w.creatures.life.clear_route(a, b.cell()), "wall blocks a real route")
	w.creatures._breed(a, content.get_def(a.kind))
	eq(w.creatures.creatures.size(), 2, "no offspring through a wall")


func test_young_do_not_breed_or_produce_then_grow_into_adults() -> void:
	var c := _spawn("base:chicken")
	c.owner = "keeper"
	c.fed_at = w.world_time
	c.made_at = w.world_time
	w.creatures.life.offspring(c)
	var adult := _spawn("base:chicken", HERE + Vector2i.RIGHT)
	adult.owner = "keeper"
	adult.fed_at = w.world_time
	_later(12)
	_ticks(20)
	eq(w.creatures.creatures.size(), 2, "a chick cannot be a parent")
	var eggs := w.items.values().filter(func(e: Dictionary) -> bool: return e["item"] == "base:egg")
	eq(eggs.size(), 0, "a chick does not lay")
	# Feed through development; before the first grown-up think, preserve
	# the data and let the normal server schedule discover adulthood.
	for i in 2:
		w.creatures.fed_by(c, "keeper")
		_later(18)
		_ticks(20)
	check(not w.creatures.life.young(c, content.get_def(c.kind)), "48-hour chick is an adult")
	check(w.creatures.life.take_changes().has(c.id), "the new stage is replicated")


func test_unfed_livestock_hungers_and_catches_up_after_unload() -> void:
	_field(Vector2i(5, 5), "base:sand")
	var c := _spawn("base:sheep")
	c.owner = "keeper"
	c.fed_at = w.world_time
	var id := c.id
	_later(30)
	_ticks(20)
	check(w.creatures.life.hungry(c), "hungry after a day without feed")
	eq(c.health, 7, "one health per six hours of hunger")
	w.sync()
	w.close()
	w = ServerWorld.open(db, content)
	w.world_time += 48 * Daylight.HOUR_MS
	w.chunk(Levels.SURFACE, 5, 5)
	_ticks(20)
	check(not w.creatures.has(id), "neglect is caught up on return; starvation is lethal")


func test_livestock_and_young_can_graze_without_manual_feeding() -> void:
	for kind: String in ["base:sheep", "base:cow", "base:chicken"]:
		var c := _spawn(kind)
		c.owner = "keeper"
		w.creatures.life.offspring(c)
		_later(30)
		_ticks(25)
		check(not w.creatures.life.hungry(c), "%s found its own food" % kind)
		check(w.world_time - c.ate_at < Daylight.HOUR_MS, "a real new meal: %s" % kind)
		eq(c.fed_at, -1, "grazing does not count as hand feeding")
		check(w.creatures.fed_lately(c), "self feeding supports produce as well")
		var id := c.id
		var ate := c.ate_at
		w.advance_time()
		w.close()
		w = ServerWorld.open(db, content)
		w.chunk(Levels.SURFACE, 5, 5)
		eq(w.creatures.get_creature(id).ate_at, ate, "self feeding survives reload")
		w.creatures.remove(id)


func test_a_fence_blocks_food_but_a_route_around_a_corner_reaches_it() -> void:
	_field(Vector2i(5, 5), "base:sand")
	var c := _spawn("base:sheep")
	c.owner = "keeper"
	_later(30)
	var ch := w.chunk(Levels.SURFACE, 5, 5)
	# A small empty pen, with grass and dropped feed on the other side.
	for y in range(168, 173):
		for x in range(168, 173):
			if x in [168, 172] or y in [168, 172]:
				ch.set_cell("structure", x & 31, y & 31, "base:wood_fence")
	ch.set_cell("ground", 173 & 31, 170 & 31, "base:grass")
	var feed := w.place_item(Levels.SURFACE, Vector2i(173, 170) * Movement.UNIT + Vector2i(128, 128), "base:wheat", 2)
	w._changed(ServerWorld.chunk_key(Levels.SURFACE, 5, 5))
	_ticks(40)
	check(w.creatures.life.hungry(c), "no eating through a fence")
	check(w.items.has(feed), "unreachable feed stays there")
	# The exit is to the north, not a straight route towards the food.
	ch.set_cell("structure", 170 & 31, 168 & 31, "")
	w._changed(ServerWorld.chunk_key(Levels.SURFACE, 5, 5))
	for i in 300:
		_ticks(1)
		if not w.creatures.life.hungry(c):
			break
	check(not w.creatures.life.hungry(c), "walked around the corner and ate")
	eq(c.cell(), Vector2i(173, 170), "the animal actually reached the feed")
	check(not w.items.has(feed), "ate from the stack")
	var left := w.items.values().filter(func(it: Dictionary) -> bool: return it["item"] == "base:wheat")
	eq(left.size(), 1)
	eq(left[0]["count"], 1)


func test_empty_and_crowded_pasture_cannot_feed_an_unlimited_herd() -> void:
	_field(Vector2i(5, 5), "base:sand")
	var a := _spawn("base:sheep")
	var b := _spawn("base:sheep", HERE + Vector2i.RIGHT)
	for c: Creature in [a, b]:
		c.owner = "keeper"
	_later(30)
	_ticks(20)
	check(w.creatures.life.hungry(a) and w.creatures.life.hungry(b), "empty ground feeds neither animal")
	var ch := w.chunk(Levels.SURFACE, 5, 5)
	ch.set_cell("ground", HERE.x & 31, HERE.y & 31, "base:grass")
	w._changed(ServerWorld.chunk_key(Levels.SURFACE, 5, 5))
	_ticks(80)
	eq([a, b].filter(func(c: Creature) -> bool: return not w.creatures.life.hungry(c)).size(), 1,
		"one patch is shared, not counted as a full meal for every animal")


func test_a_hunter_eats_real_prey_and_leaves_a_fed_herd_alone() -> void:
	var wolf := _spawn("base:wolf")
	var sheep := _spawn("base:sheep", HERE + Vector2i.RIGHT)
	sheep.owner = "keeper"
	_later(6)
	wolf.ate_at = w.world_time - 6 * Daylight.HOUR_MS
	_ticks(180)
	check(not w.creatures.has(sheep.id), "a hungry wolf caught and killed the sheep")
	check(w.world_time - wolf.ate_at < Daylight.HOUR_MS, "the kill fed the hunter")
	var next := _spawn("base:sheep", wolf.cell() + Vector2i.RIGHT)
	next.owner = "keeper"
	_ticks(60)
	eq(next.health, 8, "a full hunter does not keep killing animals")
	var meat := w.items.values().filter(func(e: Dictionary) -> bool: return e["item"] == "base:raw_meat")
	eq(meat.size(), 0, "eaten meat is not also loot")


func test_sight_and_fences_protect_prey_from_a_hunter() -> void:
	var wolf := _spawn("base:wolf")
	var sheep := _spawn("base:sheep", HERE + Vector2i(3, 0))
	sheep.owner = "keeper"
	var ch := w.chunk(Levels.SURFACE, 5, 5)
	for y in range(32):
		ch.set_cell("structure", 171 - 160, y, "base:wood_wall")
	_later(6)
	w.creatures._perceive(wolf, content.get_def(wolf.kind))
	check(not wolf.memory.has(sheep.id), "not seen through the wall")
	check(not w.combat.creature_attack(wolf, sheep.id), "not bitten through the wall")
	_ticks(160)
	eq(sheep.health, 8, "enclosed livestock survives")
	check(w.creatures.has(sheep.id), "still there")


func test_a_prey_remembers_only_the_last_seen_hunter_position() -> void:
	var hare := _spawn("base:hare")
	var wolf := _spawn("base:wolf", HERE + Vector2i(3, 0))
	w.creatures._perceive(hare, content.get_def(hare.kind))
	eq(hare.memory[wolf.id]["what"], "predator")
	var seen: Vector2i = hare.memory[wolf.id]["pos"]
	wolf.pos += Vector2i(20, 20) * Movement.UNIT
	w.creatures._index(wolf, ServerWorld.chunk_key(Levels.SURFACE, 5, 5))
	w.creatures._perceive(hare, content.get_def(hare.kind))
	eq(hare.memory[wolf.id]["pos"], seen, "out of sight, the prey does not know where the wolf went")
	w.creatures._prey(hare, content.get_def(hare.kind))
	eq(hare.state, "flee", "flees the remembered hunter")


func test_a_village_remembers_livestock_killed_by_a_hunter() -> void:
	var plan: Dictionary = w.generator.settlements.plans_near(Vector2i.ZERO, 400)[0]
	var village := String(plan["id"])
	var sheep := _spawn("base:sheep")
	sheep.owner = village
	var wolf := _spawn("base:wolf", HERE + Vector2i.RIGHT)
	w.combat.hurt(sheep.id, sheep.health, wolf.id)
	var entries: Array = w.chronicles.of(village)["entries"]
	var last: Dictionary = entries.back()
	check(String(last["text"]).contains("Волк") and String(last["text"]).contains("овца"), "real death in the chronicle: %s" % last)
	w.close()
	w = ServerWorld.open(db, content)
	eq((w.chronicles.of(village)["entries"] as Array).back()["text"], last["text"], "the loss is remembered after restart")


func test_old_creature_rows_get_a_grace_period_and_stay_adults() -> void:
	var old := Creature.from_data("old-sheep", Levels.SURFACE, {"kind": "base:sheep", "owner": "keeper",
		"x": 170 * Movement.UNIT, "y": 170 * Movement.UNIT, "last_time": 0, "fed_at": 0})
	w.world_time = 50 * Daylight.DAY_MS
	w.creatures.add(old)
	check(not w.creatures.life.young(old, content.get_def(old.kind)), "old saves mean adults")
	eq(old.ate_at, w.world_time, "upgrade does not instantly starve old livestock")
	_ticks(20)
	check(w.creatures.has(old.id), "survives the first think")


func test_animal_life_data_is_validated() -> void:
	var defs: Array = content.defs.values().map(func(d: Dictionary) -> Dictionary: return d.duplicate(true))
	var hare: Dictionary = defs.filter(func(d: Dictionary) -> bool: return d["id"] == "base:hare")[0]
	for bad: Variant in [false, {"mature_hours": 0}, {"mature_hours": 48, "breed_hours": -1},
			{"mature_hours": 48, "breed_hours": 24, "forage": ["base:raw_meat"]},
			{"mature_hours": 48, "breed_hours": 24, "prey": ["base:hare"]},
			{"mature_hours": 48, "breed_hours": 24, "forage": ["base:grass"], "food_cells": 0}]:
		hare["life"] = bad
		check(not ContentRegistry.from_defs(defs).errors.is_empty(), "bad life rejected: %s" % str(bad))
