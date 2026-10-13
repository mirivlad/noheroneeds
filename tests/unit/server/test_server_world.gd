extends TestCase
## Idempotent operations, acknowledgement after commit, no duplication under races.

const COSTS := {"test:wood_wall": {"test:plank": 3}, "test:stone_wall": {"test:stone": 2, "test:plank": 1}}

var _dir := ""
var _worlds: Array[ServerWorld] = []


func before_each() -> void:
	_dir = tmp_dir()


func after_each() -> void:
	for w in _worlds:
		w.close()
	_worlds.clear()


func _world() -> ServerWorld:
	var w := ServerWorld.open(_dir.path_join("world.db"), sample_content())
	check(w != null, "world opens")
	_worlds.append(w)
	return w


func _build(rid: String, x: int, y: int, part := "test:wood_wall") -> Dictionary:
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
	w.grant("a", "test:plank", 10)
	w.handle("a", _build("r1", 5, 5))
	eq(w.take_acks(), [], "nothing acknowledged before commit")
	w.handle("a", _build("r1", 5, 5))  # resent while pending
	check(w.sync(), w.writer.last_error())
	var acks := w.take_acks()
	eq(acks.size(), 1, "one acknowledgement")
	eq(acks[0][2], {"ok": true})
	w.handle("a", _build("r1", 5, 5))  # resent after commit
	eq(w.take_acks(), [["a", "r1", {"ok": true}]], "same result again")
	eq(w.inventory("a").count("test:plank"), 7, "paid once")


func test_contested_cell_has_one_winner() -> void:
	var w := _world()
	var actors := ["a", "b", "c", "d", "e"]
	for a: String in actors:
		w.grant(a, "test:plank", 3)
	var before := _totals(w, actors, [])
	for a: String in actors:
		w.handle(a, _build("r-" + a, -1, -1))  # all into one cell, across the chunk border
	w.sync()
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
	w.grant("a", "test:stone", 10)
	w.handle("a", {"request_id": "t1", "type": "transfer", "to": "b", "item": "test:stone", "count": 7})
	w.handle("a", {"request_id": "t2", "type": "transfer", "to": "c", "item": "test:stone", "count": 7})
	w.handle("a", {"request_id": "t1", "type": "transfer", "to": "b", "item": "test:stone", "count": 7})
	w.sync()
	eq(w.inventory("a").count("test:stone") + w.inventory("b").count("test:stone") + w.inventory("c").count("test:stone"), 10)
	eq(w.inventory("b").count("test:stone"), 7)
	eq(w.inventory("c").count("test:stone"), 0)


func test_committed_requests_survive_restart() -> void:
	var w := _world()
	w.grant("a", "test:plank", 6)
	w.handle("a", _build("r1", 1, 1))
	w.sync()
	w.take_acks()
	w.close()
	var w2 := _world()
	w2.handle("a", _build("r1", 1, 1))  # the client did not get the ack and resends
	eq(w2.take_acks(), [["a", "r1", {"ok": true}]], "answered from the ledger")
	eq(w2.inventory("a").count("test:plank"), 3, "not paid twice")
	eq(w2.chunk("surface", 0, 0).get_cell("structure", 1, 1), "test:wood_wall")


func test_uncommitted_work_is_lost_whole_and_never_acknowledged() -> void:
	var w := _world()
	w.grant("a", "test:plank", 6)
	w.sync()
	w.handle("a", _build("r1", 1, 1))
	w.abandon()  # crash before the batch is handed to the writer
	var w2 := _world()
	eq(w2.inventory("a").count("test:plank"), 6, "no payment")
	eq(w2.chunk("surface", 0, 0).get_cell("structure", 1, 1), "", "no wall")
	w2.handle("a", _build("r1", 1, 1))
	w2.sync()
	eq(w2.take_acks(), [["a", "r1", {"ok": true}]], "resend applies it once")
	eq(w2.inventory("a").count("test:plank"), 3)


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
		w.grant(a, "test:plank", 40)
		w.grant(a, "test:stone", 20)
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
				req = _build("r%d" % i, xy.x, xy.y, ["test:wood_wall", "test:stone_wall"][rng.randi() % 2])
			elif roll < 0.75:
				req = {"request_id": "r%d" % i, "type": "dismantle", "location": "surface", "x": xy.x, "y": xy.y}
			else:
				req = {"request_id": "r%d" % i, "type": "transfer", "to": actors[rng.randi() % actors.size()],
					"item": ["test:plank", "test:stone"][rng.randi() % 2], "count": rng.randi_range(1, 8)}
			sent.append([a, req])
		w.handle(a, req)
		if i % 25 == 24:
			check(w.sync(), w.writer.last_error())
	w.sync()
	eq(_totals(w, actors, cells), start, "conserved in memory")
	w.close()
	var w2 := _world()
	eq(_totals(w2, actors, cells), start, "conserved after reopen")
	check(w2.store.integrity_ok(), "integrity")
	w2.close()


static func sample_content() -> ContentRegistry:
	return ContentRegistry.from_defs([
		{"id": "test:plank", "kind": "item"}, {"id": "test:stone", "kind": "item"},
		{"id": "test:wood_wall", "kind": "structure", "cost": {"test:plank": 3}},
		{"id": "test:stone_wall", "kind": "structure", "cost": {"test:stone": 2, "test:plank": 1}},
	])
