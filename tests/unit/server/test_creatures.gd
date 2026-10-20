extends TestCase
## ADR-0018: living creatures on the server: populated once, saved, honest
## senses, memory, behaviour, a bounded cost, catching up after time away.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})


func after_each() -> void:
	w.close()


## A clear field to test in: no plants, no water, nobody else around.
func _field(cx := 5, cy := 5) -> void:
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			w.chunk("surface", cx + dx, cy + dy)  # around it loaded, as around a player
	var c := w.chunk("surface", cx, cy)
	for id: String in w.creatures.in_chunk("surface", cx, cy):
		w.creatures.creatures.erase(id)
	w.creatures._by_chunk.erase(ServerWorld.chunk_key("surface", cx, cy))
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func _spawn(kind: String, cell: Vector2i) -> Creature:
	return w.creatures._spawn(kind, "surface", cell, {}, 7)


func _player(cell: Vector2i) -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, _at(cell))
	return c.character_id


## Players near: the chunks around `cell` are needed (as GameServer marks them).
func _near(cell: Vector2i) -> void:
	var cx := floori(cell.x / 32.0)
	var cy := floori(cell.y / 32.0)
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			w.mark_needed("surface", cx + dx, cy + dy)


func _ticks(n: int, keep_near := Vector2i(1 << 20, 0)) -> void:
	for i in n:
		w.tick += 1
		w.advance_time()
		if keep_near.x != 1 << 20:
			_near(keep_near)
		w.creatures.step(w.tick)


func test_chunks_get_their_animals_once_and_villagers_come() -> void:
	var animals := 0
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			w.chunk("surface", cx, cy)
	var homes: Array = w.generator.settlements.plans_near(Vector2i.ZERO, 300)[0]["homes"]
	var villagers := w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.kind == "base:villager")
	eq(villagers.size(), homes.size(), "a dweller a home in the village by the spawn point")
	check(not (villagers[0] as Creature).looks.is_empty(), "with looks of their own")
	for c: Creature in w.creatures.creatures.values():
		animals += 1 if c.kind != "base:villager" and c.owner == "" else 0
	check(animals > 10, "animals across 49 chunks: %d" % animals)
	var count := w.creatures.creatures.size()
	var kinds := {}
	for c: Creature in w.creatures.creatures.values():
		kinds[c.kind + str(c.home)] = true
	w.close()
	w = ServerWorld.open(_db, _content)
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			w.chunk("surface", cx, cy)
	eq(w.creatures.creatures.size(), count, "the same creatures, no second population")
	var other := ServerWorld.open(tmp_dir().path_join("other.db"), _content, {"seed": 11})
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			other.chunk("surface", cx, cy)
	var same := true
	for c: Creature in other.creatures.creatures.values():
		same = same and kinds.has(c.kind + str(c.home))
	check(same, "the same seed, the same animals in the same places")
	other.close()


func test_creatures_are_kept_across_a_restart() -> void:
	_field()
	var hare := _spawn("base:hare", Vector2i(170, 170))
	hare.pos = _at(Vector2i(172, 171))
	hare.state = "graze"
	hare.memory["someone"] = {"pos": Vector2i(160, 160), "time": w.world_time, "what": "character"}
	hare.changed()
	var id := hare.id
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	var back := w.creatures.get_creature(id)
	check(back != null, "it is back")
	eq(back.pos, _at(Vector2i(172, 171)), "where it was")
	eq(back.home, Vector2i(170, 170))
	eq(back.memory["someone"]["pos"], Vector2i(160, 160), "with what it remembers")


func test_sight_is_honest() -> void:
	_field()
	var deer := _spawn("base:deer", Vector2i(170, 170))
	var def := _content.get_def("base:deer")
	w.world_time = 12 * Daylight.HOUR_MS
	check(Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(178, 170)), "8 cells off at noon")
	check(not Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(184, 170)), "beyond its sight")
	w.grant("b", "base:plank", 10)
	var r := {"request_id": "wall", "type": "build", "location": "surface", "x": 174, "y": 170, "part": "base:wood_wall"}
	w.handle("b", r)
	w.sync()
	check(not Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(178, 170)), "not through a wall")
	check(Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(170, 178)), "but round it")
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS
	check(not Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(170, 178)), "at night, 8 cells is too far")
	w.grant("b", "base:log", 1)
	w.handle("b", {"request_id": "torch", "type": "build", "location": "surface", "x": 171, "y": 179, "part": "base:torch"})
	w.sync()
	check(Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(170, 178)), "by a torch it is seen again")
	deer.changed()


func test_memory_keeps_where_it_saw_not_where_one_is() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var hare := _spawn("base:hare", Vector2i(170, 170))
	var pid := _player(Vector2i(176, 170))
	_ticks(12, Vector2i(170, 170))
	check(hare.memory.has(pid), "it saw the player")
	w.move_character(pid, _at(Vector2i(190, 190)))  # gone far, out of sight
	_ticks(12, Vector2i(170, 170))
	check(hare.memory.has(pid), "still remembers")
	check(Vector2(hare.memory[pid]["pos"]).distance_to(Vector2(190, 190)) > 10, "where it saw, not where the player is")


func test_a_hare_runs_from_someone_coming_close() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var hare := _spawn("base:hare", Vector2i(170, 170))
	_player(Vector2i(173, 170))
	_ticks(30, Vector2i(170, 170))
	check(hare.state in ["flee", "alert"], "it ran and watches: " + hare.state)
	check(hare.cell().x < 167, "away from the player: %s" % hare.cell())


func test_noise_is_heard_as_a_place() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var deer := _spawn("base:deer", Vector2i(170, 170))
	w.grant("b", "base:plank", 10)
	w.handle("b", {"request_id": "n", "type": "build", "location": "surface", "x": 176, "y": 172, "part": "base:wood_wall"})
	w.sync()
	_ticks(12, Vector2i(170, 170))
	check(deer.memory.has("noise"), "it heard building")
	eq(deer.memory["noise"]["pos"], Vector2i(176, 172), "where, not who")


func test_villagers_go_home_at_night() -> void:
	_field()
	var v := w.creatures._spawn("base:villager", "surface", Vector2i(170, 170), {"body_plan": "base:human_m"}, 3)
	v.pos = _at(Vector2i(175, 172))
	w.world_time = 22 * Daylight.HOUR_MS
	v.last_time = w.world_time
	_ticks(200, Vector2i(170, 170))
	eq(v.cell(), Vector2i(170, 170), "home")
	eq(v.state, "home")


func test_thinking_has_a_budget_and_nobody_thinks_far_from_players() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	for i in 300:
		_spawn("base:hare", Vector2i(161 + i % 30, 161 + i / 30 % 30))
	var most := 0
	for i in 20:
		_ticks(1, Vector2i(170, 170))
		most = maxi(most, w.creatures.thinks_last_tick)
	eq(most, CreatureSim.THINKS_PER_TICK, "never more than the budget")
	var far := _spawn("base:hare", Vector2i(170, 170))
	_ticks(CreatureSim.ACTIVE_TICKS + 30)  # nobody needs these chunks any more
	var before := far.pos
	var thought := far.next_think
	_ticks(120)
	eq(far.pos, before, "nobody near: it stands")
	check(far.next_think - thought >= 60, "and thinks rarely")


func test_a_creature_away_catches_up() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var v := w.creatures._spawn("base:villager", "surface", Vector2i(170, 170), {"body_plan": "base:human_m"}, 3)
	v.pos = _at(Vector2i(178, 175))
	v.last_time = w.world_time
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS  # long away; night now
	_ticks(30, Vector2i(170, 170))
	eq(v.cell(), Vector2i(170, 170), "back at home at once: the night went on without anyone")


func test_a_chunk_unloads_with_its_creatures_and_brings_them_back() -> void:
	_field(8, 8)
	var hare := _spawn("base:hare", Vector2i(266, 266))
	var id := hare.id
	w.sync()
	var gone := 0
	for i in 3:
		w.tick += 10000
		gone += w.unload_idle(100)
		w.sync()
	check(not w.has_chunk("surface", 8, 8), "unloaded")
	check(not w.creatures.has(id), "its creature too")
	w.chunk("surface", 8, 8)
	check(w.creatures.has(id), "back with it")


## ADR-0015: a creature below sees one on a walkway on a wall, not one
## behind a wall upstairs.
func test_a_creature_sees_one_on_a_walkway_not_behind_walls_upstairs() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	w.grant("b", "base:plank", 100)
	var level := ""
	for x in range(170, 177):
		w.handle("b", {"request_id": "w%d" % x, "type": "build", "location": "surface", "x": x, "y": 170, "part": "base:wood_wall"})
		w.handle("b", {"request_id": "c%d" % x, "type": "build", "location": "surface", "x": x, "y": 170, "part": "base:wood_ceiling"})
		w.handle("b", {"request_id": "d%d" % x, "type": "build", "location": "surface", "x": x, "y": 169, "part": "base:wood_ceiling"})
	w.sync()
	level = w.levels.level(w._ceiling_building("surface", 173, 170), 1)
	check(level != "", "a walkway up there")
	var deer := _spawn("base:deer", Vector2i(173, 177))
	var pid := _player(Vector2i(173, 160))
	w.present[pid]["location"] = level
	w.move_character(pid, _at(Vector2i(173, 170)))
	_ticks(12, Vector2i(173, 177))
	check(deer.memory.has(pid), "it saw the one on the walkway")
	deer.memory.clear()
	w.move_character(pid, _at(Vector2i(173, 169)))
	w.handle("b", {"request_id": "up", "type": "build", "location": level, "x": 173, "y": 170, "part": "base:wood_wall"})
	w.sync()
	eq(w._part_at(level, 173, 170, "structure"), "base:wood_wall", "a wall upstairs")
	_ticks(12, Vector2i(173, 177))
	check(not deer.memory.has(pid), "not behind a wall upstairs")


func test_bodies_have_their_own_size() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var hare := BodySize.of(content.get_def("base:hare"))
	var deer := BodySize.of(content.get_def("base:deer"))
	eq(BodySize.of(content.get_def("base:human_m")), BodySize.HUMAN, "a man without a size is a man")
	check(hare["half"].x < BodySize.HUMAN["half"].x and deer["half"].x > BodySize.HUMAN["half"].x, "small and big boxes")
	check(float(hare["eye"]) < Sight.EYE and float(deer["height"]) > float(BodySize.HUMAN["height"]), "heights by body")
	# A body two cells wide stops a cell sooner at a wall than a man does.
	var wall := func(x: int, _y: int) -> bool: return x == 5
	var man := Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
	var big := man
	for i in 200:
		man = Movement.step_at(man, 1, 0, wall, 51)
		big = Movement.step_at(big, 1, 0, wall, 51, Vector2i(Movement.UNIT, Movement.UNIT / 2))
	eq(man.x, 5 * Movement.UNIT - Movement.HALF_X)
	eq(big.x, 4 * Movement.UNIT)
	for bad: Variant in [[1, 2], {"half": [0, 1]}, {"half": [1]}, {"height": -1}, {"eye": "high"}, {"radius": 99}]:
		var errors := PackedStringArray()
		BodySize.parse("test:x", bad, errors)
		check(not errors.is_empty(), "malformed size refused: %s" % str(bad))
	eq(BodySize.cells(Vector2i(384, 384), Vector2i(256, 128)), [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)] as Array[Vector2i],
		"the cells a body covers")
