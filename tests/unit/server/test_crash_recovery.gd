extends TestCase
## A server process is killed at a random moment, several times over the same
## world. Every acknowledged operation must be in the database, the database
## must be intact, and no material may appear or vanish.

const COSTS := {"base:wood_wall": {"base:plank": 3}, "base:stone_wall": {"base:stone": 2, "base:plank": 1}}
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
		var w := ServerWorld.new(store)
		w.part_costs = COSTS
		eq(_totals(w), {"base:plank": 60 * ACTORS.size(), "base:stone": 30 * ACTORS.size()}, "materials after round %d" % round)
		store.close()


func _run_and_kill(db: String, round: int, seed: int, kill_after: int) -> Array:
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tests/support/crash_worker.gd", "--", "--db=" + db, "--round=%d" % round, "--seed=%d" % seed]
	var p := OS.execute_with_pipe(OS.get_executable_path(), args)
	var io: FileAccess = p["stdio"]
	var acked: Array = []
	var killed := false
	# Blocking reads until the pipe closes. Lines read after the kill were
	# printed before the worker died, so they were sent and count as acknowledged.
	while true:
		var line := io.get_line()
		# After the kill an empty read means the pipe is drained (the worker
		# prints no blank lines of its own); eof is not always reported.
		if line == "" and (killed or io.eof_reached() or not OS.is_process_running(p["pid"])):
			break
		if line.begins_with("ACK "):
			var f := line.split(" ")
			acked.append([f[1], f[2], f[3]])
			if not killed and acked.size() >= kill_after:
				OS.kill(p["pid"])
				killed = true
	if not killed:
		var err: FileAccess = p["stderr"]
		check(false, "worker exited by itself: " + err.get_as_text())
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
