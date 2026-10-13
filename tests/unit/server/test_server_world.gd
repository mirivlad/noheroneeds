extends TestCase
## Idempotent operations, acknowledgement after commit, no duplication under races.

const COSTS := {"base:wood_wall": {"base:plank": 3}, "base:stone_wall": {"base:stone": 2, "base:plank": 1}}

var _dir := ""


func before_each() -> void:
	_dir = tmp_dir()


func _world() -> ServerWorld:
	var s := WorldStore.new()
	check(s.open(_dir.path_join("world.db")), s.last_error)
	var w := ServerWorld.new(s)
	w.part_costs = COSTS
	return w


func _build(rid: String, x: int, y: int, part := "base:wood_wall") -> Dictionary:
	return {"request_id": rid, "type": "build", "location": "surface", "x": x, "y": y, "part": part}


## Material totals: inventories plus what is built in the given cells.
func _totals(w: ServerWorld, owners: Array, cells: Array) -> Dictionary:
	var t := {}
	for o: String in owners:
		var inv := w.inventory(o)
		for id: String in inv.stacks:
			t[id] = t.get(id, 0) + inv.stacks[id]
	for xy: Vector2i in cells:
		var cx := floori(xy.x / float(Chunk.SIZE))
		var cy := floori(xy.y / float(Chunk.SIZE))
		var part := w.chunk("surface", cx, cy).get_cell("structure", xy.x - cx * Chunk.SIZE, xy.y - cy * Chunk.SIZE)
		var costs: Dictionary = COSTS.get(part, {})
		for id: String in costs:
			t[id] = t.get(id, 0) + int(costs[id])
	return t


func test_ack_only_after_commit_and_repeat_is_harmless() -> void:
	var w := _world()
	w.grant("a", "base:plank", 10)
	w.handle("a", _build("r1", 5, 5))
	eq(w.take_acks(), [], "nothing acknowledged before commit")
	w.handle("a", _build("r1", 5, 5))  # resent while pending
	check(w.flush_operations(), w.store.last_error)
	var acks := w.take_acks()
	eq(acks.size(), 1, "one acknowledgement")
	eq(acks[0][2], {"ok": true})
	w.handle("a", _build("r1", 5, 5))  # resent after commit
	eq(w.take_acks(), [["a", "r1", {"ok": true}]], "same result again")
	eq(w.inventory("a").count("base:plank"), 7, "paid once")


func test_contested_cell_has_one_winner() -> void:
	var w := _world()
	var actors := ["a", "b", "c", "d", "e"]
	for a: String in actors:
		w.grant(a, "base:plank", 3)
	var before := _totals(w, actors, [])
	for a: String in actors:
		w.handle(a, _build("r-" + a, -1, -1))  # all into one cell, across the chunk border
	w.flush_operations()
	var wins := 0
	for ack: Array in w.take_acks():
		if ack[2]["ok"]:
			wins += 1
		else:
			eq(ack[2]["reason"], "occupied")
	eq(wins, 1, "exactly one wall")
	eq(_totals(w, actors, [Vector2i(-1, -1)]), before, "materials conserved")


func test_racing_transfers_cannot_duplicate() -> void:
	var w := _world()
	w.grant("a", "base:stone", 10)
	w.handle("a", {"request_id": "t1", "type": "transfer", "to": "b", "item": "base:stone", "count": 7})
	w.handle("a", {"request_id": "t2", "type": "transfer", "to": "c", "item": "base:stone", "count": 7})
	w.handle("a", {"request_id": "t1", "type": "transfer", "to": "b", "item": "base:stone", "count": 7})
	w.flush_operations()
	eq(w.inventory("a").count("base:stone") + w.inventory("b").count("base:stone") + w.inventory("c").count("base:stone"), 10)
	eq(w.inventory("b").count("base:stone"), 7)
	eq(w.inventory("c").count("base:stone"), 0)


func test_committed_requests_survive_restart() -> void:
	var w := _world()
	w.grant("a", "base:plank", 6)
	w.handle("a", _build("r1", 1, 1))
	w.flush_operations()
	w.take_acks()
	w.store.close()
	var w2 := _world()
	w2.handle("a", _build("r1", 1, 1))  # the client did not get the ack and resends
	eq(w2.take_acks(), [["a", "r1", {"ok": true}]], "answered from the ledger")
	eq(w2.inventory("a").count("base:plank"), 3, "not paid twice")
	eq(w2.chunk("surface", 0, 0).get_cell("structure", 1, 1), "base:wood_wall")


func test_uncommitted_work_is_lost_whole_and_never_acknowledged() -> void:
	var w := _world()
	w.grant("a", "base:plank", 6)
	w.flush_operations()
	w.handle("a", _build("r1", 1, 1))
	w.store.close()  # crash before the batch commit
	var w2 := _world()
	eq(w2.inventory("a").count("base:plank"), 6, "no payment")
	eq(w2.chunk("surface", 0, 0).get_cell("structure", 1, 1), "", "no wall")
	w2.handle("a", _build("r1", 1, 1))
	w2.flush_operations()
	eq(w2.take_acks(), [["a", "r1", {"ok": true}]], "resend applies it once")
	eq(w2.inventory("a").count("base:plank"), 3)


func test_random_load_keeps_invariants() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var actors := ["a", "b", "c", "d", "e", "f", "g", "h"]
	var cells: Array = []
	for y in range(-3, 3):
		for x in range(-3, 3):
			cells.append(Vector2i(x, y))
	var w := _world()
	for a: String in actors:
		w.grant(a, "base:plank", 40)
		w.grant(a, "base:stone", 20)
	var start := _totals(w, actors, cells)
	var sent: Array = []
	for i in 2000:
		var a: String = actors[rng.randi() % actors.size()]
		var req: Dictionary
		if sent.size() > 0 and rng.randf() < 0.2:
			var old: Array = sent[rng.randi() % sent.size()]  # a resent packet
			a = old[0]
			req = old[1]
		else:
			var xy: Vector2i = cells[rng.randi() % cells.size()]
			var roll := rng.randf()
			if roll < 0.45:
				req = _build("r%d" % i, xy.x, xy.y, ["base:wood_wall", "base:stone_wall"][rng.randi() % 2])
			elif roll < 0.75:
				req = {"request_id": "r%d" % i, "type": "dismantle", "location": "surface", "x": xy.x, "y": xy.y}
			else:
				req = {"request_id": "r%d" % i, "type": "transfer", "to": actors[rng.randi() % actors.size()],
					"item": ["base:plank", "base:stone"][rng.randi() % 2], "count": rng.randi_range(1, 8)}
			sent.append([a, req])
		w.handle(a, req)
		if i % 25 == 24:
			check(w.flush_operations(), w.store.last_error)
	w.flush_operations()
	eq(_totals(w, actors, cells), start, "conserved in memory")
	w.store.close()
	var w2 := _world()
	eq(_totals(w2, actors, cells), start, "conserved after reopen")
	check(w2.store.integrity_ok(), "integrity")
