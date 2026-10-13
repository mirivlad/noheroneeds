extends TestCase
## A server process is killed at a random moment, several times over the same
## world. Every acknowledged operation must be in the database, the database
## must be intact, and no material may appear or vanish.

const COSTS := {"test:wood_wall": {"test:plank": 3}, "test:stone_wall": {"test:stone": 2, "test:plank": 1}}
const ACTORS := ["a", "b", "c", "d", "e", "f"]


func test_kill_during_load() -> void:
	var db := tmp_dir().path_join("world.db")
	var rng := RandomNumberGenerator.new()
	rng.seed = int(options.get("seed", Time.get_ticks_usec()))
	var rounds := int(options.get("crash_rounds", 4))
	for round in rounds:
		var acked := _run_and_kill(db, round, rng.randi(), rng.randi_range(5, 400))
		if acked.is_empty() and round == 0:
			check(false, "worker produced no acknowledgements")
			return
		var store := WorldStore.new()
		if not check(store.open(db), "reopen after kill: " + store.last_error):
			return
		check(store.integrity_ok(), "integrity after round %d" % round)
		var missing := 0
		for ack: Array in acked:
			var stored := store.get_request(ack[0], ack[1])
			if stored.is_empty() or bool(Cbor.decode(stored).value["ok"]) != (ack[2] == "ok"):
				missing += 1
		eq(missing, 0, "acknowledged operations missing after round %d (of %d)" % [round, acked.size()])
		store.close()
		var w := ServerWorld.open(db, sample_content())
		eq(_totals(w), {"test:plank": 60 * ACTORS.size(), "test:stone": 30 * ACTORS.size()}, "materials after round %d" % round)
		w.close()


func _run_and_kill(db: String, round: int, seed: int, kill_after: int) -> Array:
	var p := spawn_godot("res://tests/support/crash_worker.gd", ["--db=" + db, "--round=%d" % round, "--seed=%d" % seed])
	var io: FileAccess = p["stdio"]
	var acked: Array = []
	var killed := false
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		var line := io.get_line()
		if line.begins_with("ACK "):
			var f := line.split(" ")
			acked.append([f[1], f[2], f[3]])
			if not killed and acked.size() >= kill_after:
				OS.kill(p["pid"])
				killed = true
		elif line == "":
			if killed or not OS.is_process_running(p["pid"]):
				# Lines already in the pipe were printed before the worker died:
				# those acknowledgements were sent.
				var rest := io.get_line()
				while rest != "":
					if rest.begins_with("ACK "):
						var g := rest.split(" ")
						acked.append([g[1], g[2], g[3]])
					rest = io.get_line()
				break
			OS.delay_msec(1)
	if not killed:
		OS.kill(p["pid"])
		var err: FileAccess = p["stderr"]
		check(false, "worker ended or stalled by itself: " + err.get_as_text())
	return acked


func _totals(w: ServerWorld) -> Dictionary:
	var t := {}
	for o: String in ACTORS:
		var inv := w.inventory(o)
		for id: String in inv.stacks:
			t[id] = t.get(id, 0) + inv.stacks[id]
	for cy in [-1, 0]:
		for cx in [-1, 0]:
			var c := w.chunk("surface", cx, cy)
			for i in Chunk.CELLS:
				var part := c.get_cell("structure", i % Chunk.SIZE, i / Chunk.SIZE)
				var costs: Dictionary = COSTS.get(part, {})
				for id: String in costs:
					t[id] = t.get(id, 0) + int(costs[id])
	return t


static func sample_content() -> ContentRegistry:
	return ContentRegistry.from_defs([
		{"id": "test:plank", "kind": "item"}, {"id": "test:stone", "kind": "item"},
		{"id": "test:wood_wall", "kind": "structure", "cost": {"test:plank": 3}},
		{"id": "test:stone_wall", "kind": "structure", "cost": {"test:stone": 2, "test:plank": 1}},
	])
