extends TestCase
## ADR-0016: porings and poporings pick up what lies about (not what a dead
## one dropped while it is kept for them), digest it in a couple of hours,
## and give back what is left when killed.

var w: ServerWorld
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 7})
	w.world_time = 12 * Daylight.HOUR_MS
	for cy in [4, 5, 6]:
		for cx in [4, 5, 6]:
			var c := w.chunk("surface", cx, cy)
			for id: String in w.creatures.in_chunk("surface", cx, cy):
				w.creatures.remove(id)
			for y in Chunk.SIZE:
				for x in Chunk.SIZE:
					c.set_cell("ground", x, y, "base:grass")
					c.set_cell("cover", x, y, "")


func after_each() -> void:
	w.close()


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func _ticks(n: int) -> void:
	for i in n:
		w.tick += 1
		w.advance_time()
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				w.mark_needed("surface", 5 + dx, 5 + dy)
		w.creatures.step(w.tick)
		w.combat.step(w.tick)


func test_a_poring_picks_up_digests_and_gives_back() -> void:
	var poring := w.creatures._spawn("base:poring", "surface", Vector2i(170, 170), {}, 1)
	var free := w.place_item("surface", _at(Vector2i(174, 171)), "base:plank", 3)
	var kept := w.place_item("surface", _at(Vector2i(166, 170)), "base:stone", 2, "someone dead", w.tick + 400)
	_ticks(200)
	check(not w.items.has(free), "it went and swallowed the planks")
	check(w.items.has(kept), "not a dead one's things, kept for them")
	eq(poring.stomach.map(func(e: Dictionary) -> String: return e["item"]), ["base:plank"])
	_ticks(400)
	check(not w.items.has(kept), "once anyone's, those too")
	eq(poring.stomach.size(), 2)
	# Some two hours on, the planks are digested; the stone, swallowed later, not yet.
	w.world_time = int(poring.stomach[0]["at"]) + int(7200.0 * Movement.TICK_RATE * w.time_rate)
	w.creatures.digest(poring)
	eq(poring.stomach.map(func(e: Dictionary) -> String: return e["item"]), ["base:stone"], "the planks are gone")
	var where := poring.cell()
	w.combat.hurt(poring.id, 100, "")
	var lying := {}
	for id: String in w.items:
		if Movement.cell_of(Vector2i(w.items[id]["x"], w.items[id]["y"])) == where:
			lying[w.items[id]["item"]] = int(w.items[id]["count"])
	eq(lying, {"base:stone": 2}, "killed, it gives back what is left")


func test_a_poring_keeps_what_it_swallowed_over_a_restart() -> void:
	var db := tmp_dir().path_join("again.db")
	var w2 := ServerWorld.open(db, _content, {"seed": 7})
	var p := w2.creatures._spawn("base:poporing", "surface", Vector2i(3, 3), {}, 1)
	p.stomach.append({"item": "base:raw_gem", "count": 1, "at": w2.world_time})
	p.changed()
	w2.creatures.save_all()
	w2.flush_state()
	var id := p.id
	w2.close()
	w2 = ServerWorld.open(db, _content)
	w2.chunk("surface", 0, 0)
	var back := w2.creatures.get_creature(id)
	check(back != null, "back after a restart")
	if back:
		eq(back.stomach.size(), 1, "with what it swallowed")
	w2.close()


## Worlds made before the looters meet them too: chunks populated then get
## the new kinds only, about as many as their share of the fauna.
func test_old_chunks_get_only_the_new_kinds() -> void:
	var kinds := {}
	for i in 40:
		var cx := 20 + i
		w.chunk("surface", cx, 20)
		for id: String in w.creatures.in_chunk("surface", cx, 20):
			w.creatures.remove(id)
		w.creatures._populate("surface", cx, 20, 1)
		for id: String in w.creatures.in_chunk("surface", cx, 20):
			var k := w.creatures.get_creature(id).kind
			kinds[k] = int(kinds.get(k, 0)) + 1
	check(not kinds.is_empty(), "some came")
	check(kinds.keys().all(func(k: String) -> bool: return k in ["base:poring", "base:poporing"]), "looters only: %s" % kinds)
	var n := 0
	for k: String in kinds:
		n += int(kinds[k])
	check(n < 30, "not a crowd: %d in 40 chunks" % n)
