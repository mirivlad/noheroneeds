extends TestCase
## Storage measurements for ADR-0005 (run: tools/run_tests.sh --bench --only=bench).
## Prints "MEASURE name value unit" lines; the summary lives in docs/measurements/.
## Checks here are sanity limits, not targets.

const COSTS := {"test:wood_wall": {"test:plank": 3}, "test:stone_wall": {"test:stone": 2, "test:plank": 1}}
const GROUND := ["base:grass", "base:grass_dry", "base:dirt", "base:moss", "base:sand"]
const COVER := ["base:tall_grass", "base:clover", "base:fern", "base:flower_red", "base:flower_yellow", "base:bush", "base:pebbles"]


func _measure(name: String, value: float, unit: String) -> void:
	print("MEASURE %s %.3f %s" % [name, value, unit])


func _store(dir: String, sync := "FULL") -> WorldStore:
	var s := WorldStore.new()
	check(s.open(dir.path_join("world.db"), {"synchronous": sync}), s.last_error)
	return s


## A plausible surface chunk: varied ground, a third covered by plants, sometimes a building.
func _make_chunk(rng: RandomNumberGenerator, cx: int, cy: int) -> Chunk:
	var c := Chunk.new()
	var base := rng.randi() % GROUND.size()
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			var g := base if rng.randf() < 0.8 else rng.randi() % GROUND.size()
			c.set_cell("ground", x, y, GROUND[g])
			if rng.randf() < 0.3:
				c.set_cell("cover", x, y, COVER[rng.randi() % COVER.size()])
	if rng.randf() < 0.1:
		for y in range(8, 16):
			for x in range(8, 18):
				if y == 8 or y == 15 or x == 8 or x == 17:
					c.set_cell("structure", x, y, "test:wood_wall")
					c.set_props(x, y, {"owner": "player-%d" % (rng.randi() % 20)})
	c.meta = {"gen": "base:surface", "gen_version": 1, "cx": cx, "cy": cy}
	return c


func _pct(samples: Array, p: float) -> float:
	if samples.is_empty():
		return 0.0
	var s := samples.duplicate()
	s.sort()
	return s[mini(s.size() - 1, int(p * s.size()))]


func _file_mb(path: String) -> float:
	return FileAccess.get_size(path) / 1048576.0 if FileAccess.file_exists(path) else 0.0


func bench_10k_chunks() -> void:
	var dir := tmp_dir()
	var s := _store(dir)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	# Encoding cost is per chunk; generate a pool of varied chunks and reuse it.
	var pool: Array = []
	for i in 200:
		pool.append(_make_chunk(rng, i, 0))
	var t := Time.get_ticks_usec()
	var blobs: Array = []
	for c: Chunk in pool:
		blobs.append(ChunkCodec.encode(c))
	_measure("chunk_encode", (Time.get_ticks_usec() - t) / 1000.0 / pool.size(), "ms/chunk")
	var total_bytes := 0
	for b: PackedByteArray in blobs:
		total_bytes += b.size()
	_measure("chunk_blob_avg", total_bytes / float(blobs.size()), "bytes")
	t = Time.get_ticks_usec()
	for b: PackedByteArray in blobs:
		ChunkCodec.decode(b)
	_measure("chunk_decode", (Time.get_ticks_usec() - t) / 1000.0 / blobs.size(), "ms/chunk")
	# Write 10 000 chunks (100 x 100 area) in transactions of 100.
	t = Time.get_ticks_usec()
	var i := 0
	for cy in 100:
		s.begin()
		for cx in 100:
			s.put_chunk("surface", cx - 50, cy - 50, blobs[i % blobs.size()])
			i += 1
		check(s.commit(), s.last_error)
	var write_s := (Time.get_ticks_usec() - t) / 1000000.0
	_measure("write_10k_chunks", write_s, "s")
	s.checkpoint()
	eq(s.count_chunks(), 10000)
	_measure("db_size_10k_chunks", _file_mb(dir.path_join("world.db")), "MB")
	# Load a 9x9 area (what a player needs around them) many times at random places.
	var times: Array = []
	for k in 50:
		var ox := rng.randi_range(-50, 40)
		var oy := rng.randi_range(-50, 40)
		t = Time.get_ticks_usec()
		for dy in 9:
			for dx in 9:
				var c := ChunkCodec.decode(s.get_chunk("surface", ox + dx, oy + dy))
				check(c != null, "chunk decodes")
		times.append((Time.get_ticks_usec() - t) / 1000.0)
	_measure("load_9x9_area_p50", _pct(times, 0.5), "ms")
	_measure("load_9x9_area_p95", _pct(times, 0.95), "ms")
	s.close()


func bench_surface_generation() -> void:
	var g := SurfaceGenerator.new(1, ContentRegistry.load_packs(["res://content/base"]))
	var t := Time.get_ticks_usec()
	for i in 100:
		g.generate(i % 10, i / 10)
	var ms := (Time.get_ticks_usec() - t) / 1000.0 / 100
	_measure("surface_generate", ms, "ms/chunk")
	# A walking player (4 cells/s) enters a new column of 7 chunks every 8 s.
	_measure("loader_share_for_one_walking_player", ms * 7 / 8000.0 * 100.0, "% of one core")


func bench_operation_commits() -> void:
	for sync: String in ["FULL", "NORMAL"]:
		var sub := tmp_dir().path_join(sync)
		DirAccess.make_dir_recursive_absolute(sub)
		var w := ServerWorld.open(sub.path_join("world.db"), sample_content(), {"synchronous": sync})
		var rng := RandomNumberGenerator.new()
		rng.seed = 2
		for p in 20:
			w.grant("p%d" % p, "test:plank", 100000)
			w.grant("p%d" % p, "test:stone", 100000)
		w.sync()
		var sim: Array = []
		var disk: Array = []
		var n := 0
		for batch in 400:
			for k in 10:  # ten operations by different players, contested area
				var a := "p%d" % (rng.randi() % 20)
				var x := rng.randi_range(-40, 40)
				var y := rng.randi_range(-40, 40)
				if rng.randf() < 0.6:
					w.handle(a, {"request_id": "r%d" % n, "type": "build", "location": "surface", "x": x, "y": y, "part": "test:wood_wall"})
				else:
					w.handle(a, {"request_id": "r%d" % n, "type": "transfer", "to": "p%d" % (rng.randi() % 20), "item": "test:plank", "count": 1})
				n += 1
			var t := Time.get_ticks_usec()
			w.commit_async(true)
			sim.append((Time.get_ticks_usec() - t) / 1000.0)
			t = Time.get_ticks_usec()
			w.writer.wait_idle()
			disk.append((Time.get_ticks_usec() - t) / 1000.0)
			w.poll()
			w.take_acks()
		_measure("ops_batch10_sim_thread_%s_p50" % sync, _pct(sim, 0.5), "ms")
		_measure("ops_batch10_sim_thread_%s_max" % sync, _pct(sim, 1.0), "ms")
		_measure("ops_batch10_writer_%s_p50" % sync, _pct(disk, 0.5), "ms")
		_measure("ops_batch10_writer_%s_p95" % sync, _pct(disk, 0.95), "ms")
		_measure("ops_batch10_writer_%s_max" % sync, _pct(disk, 1.0), "ms")
		w.close()


func bench_state_flush_and_shutdown() -> void:
	var dir := tmp_dir()
	var w := ServerWorld.open(dir.path_join("world.db"), sample_content())
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var ids: Array = []
	for i in 5000:
		ids.append(Uuid.v4())
	for round in 5:
		for id: String in ids:
			w.set_entity(id, "surface", rng.randi_range(-1600, 1600), rng.randi_range(-1600, 1600), "base:deer",
				{"hp": rng.randi_range(1, 20), "hunger": rng.randf(), "dir": rng.randi() % 8, "mood": "calm"})
		var t := Time.get_ticks_usec()
		w.flush_state()
		_measure("flush_5000_entities_sim_thread_round%d" % round, (Time.get_ticks_usec() - t) / 1000.0, "ms")
		t = Time.get_ticks_usec()
		w.writer.wait_idle()
		_measure("flush_5000_entities_writer_round%d" % round, (Time.get_ticks_usec() - t) / 1000.0, "ms")
	var t2 := Time.get_ticks_usec()
	w.close()
	_measure("shutdown_close", (Time.get_ticks_usec() - t2) / 1000.0, "ms")


## One hour of play at 20 ticks/s, compressed (as fast as the machine goes):
## 20 players acting about every two seconds; changes handed to the writer
## every tick (with backpressure); 2000 creatures change every 30 s and are
## flushed 100 per tick; old requests pruned every 5 min. Shows growth over
## time and how much of the simulated hour the writer was busy.
func bench_long_session() -> void:
	_session(int(options.get("ticks", 20 * 3600)), false)


## Two minutes at the real pace of 20 ticks/s: acknowledgement delay in ms.
func bench_realtime_session() -> void:
	_session(int(options.get("realtime_ticks", 20 * 120)), true)


func _session(ticks: int, realtime: bool) -> void:
	var tag := "realtime" if realtime else "session"
	var dir := tmp_dir()
	var w := ServerWorld.open(dir.path_join("world.db"), sample_content())
	w.request_memory_ticks = 20 * 60 * 10
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	for p in 20:
		w.grant("p%d" % p, "test:plank", 1000000)
		w.grant("p%d" % p, "test:stone", 1000000)
	var creatures: Array = []
	for i in 2000:
		creatures.append([Uuid.v4(), rng.randi_range(-800, 800), rng.randi_range(-800, 800)])
	w.sync()
	var window := 20 * 600 if not realtime else 20 * 30
	var tick_cost: Array = []
	var ack_ms: Array = []
	var sent_at := {}
	var n := 0
	var wall := Time.get_ticks_usec()
	var busy0 := w.writer.busy_usec()
	for tick in ticks:
		var tick_start := Time.get_ticks_usec()
		w.tick = tick
		if rng.randf() < 0.5:  # ~10 operations per second
			var a := "p%d" % (rng.randi() % 20)
			var x := rng.randi_range(-200, 200)
			var y := rng.randi_range(-200, 200)
			var roll := rng.randf()
			var rid := "r%d" % n
			if roll < 0.5:
				w.handle(a, {"request_id": rid, "type": "build", "location": "surface", "x": x, "y": y, "part": "test:wood_wall"})
			elif roll < 0.8:
				w.handle(a, {"request_id": rid, "type": "dismantle", "location": "surface", "x": x, "y": y})
			else:
				w.handle(a, {"request_id": rid, "type": "transfer", "to": "p%d" % (rng.randi() % 20), "item": "test:stone", "count": 1})
			sent_at[rid] = Time.get_ticks_usec()
			n += 1
		if tick % 600 == 0:
			for c: Array in creatures:
				c[1] += rng.randi_range(-5, 5)
				c[2] += rng.randi_range(-5, 5)
				w.set_entity(c[0], "surface", c[1], c[2], "base:deer", {"hp": 10, "hunger": rng.randf()})
		if tick % 6000 == 5999:
			w.prune_requests()
		var t := Time.get_ticks_usec()
		w.commit_async()
		w.flush_state(100)
		w.poll()
		tick_cost.append((Time.get_ticks_usec() - t) / 1000.0)
		for ack: Array in w.take_acks():
			ack_ms.append((Time.get_ticks_usec() - int(sent_at[ack[1]])) / 1000.0)
			sent_at.erase(ack[1])
		if realtime:
			OS.delay_usec(maxi(0, 50000 - (Time.get_ticks_usec() - tick_start)))
		if tick % window == window - 1:
			var label := "%s_t%05d" % [tag, (tick + 1) / 20]
			_measure(label + "_tick_cost_p50", _pct(tick_cost, 0.5), "ms")
			_measure(label + "_tick_cost_p99", _pct(tick_cost, 0.99), "ms")
			_measure(label + "_tick_cost_max", _pct(tick_cost, 1.0), "ms")
			if realtime:
				_measure(label + "_ack_p50", _pct(ack_ms, 0.5), "ms")
				_measure(label + "_ack_p99", _pct(ack_ms, 0.99), "ms")
				_measure(label + "_ack_max", _pct(ack_ms, 1.0), "ms")
			else:
				_measure(label + "_db", _file_mb(dir.path_join("world.db")), "MB")
				_measure(label + "_wal", _file_mb(dir.path_join("world.db-wal")), "MB")
			tick_cost.clear()
			ack_ms.clear()
	_measure(tag + "_loop_wall_time", (Time.get_ticks_usec() - wall) / 1000000.0, "s")
	var t_sync := Time.get_ticks_usec()
	w.sync()
	_measure(tag + "_final_sync", (Time.get_ticks_usec() - t_sync) / 1000.0, "ms")
	for ack: Array in w.take_acks():
		sent_at.erase(ack[1])
	# Measured after the writer drained everything the session produced.
	_measure(tag + "_writer_busy_share", (w.writer.busy_usec() - busy0) / 1000000.0 / (ticks / 20.0) * 100.0, "% of game time")
	_measure(tag + "_operations", n, "ops")
	eq(sent_at.size(), 0, "every request acknowledged")
	check(w.store.integrity_ok(), "integrity after the session")
	w.close()


static func sample_content() -> ContentRegistry:
	return ContentRegistry.from_defs([
		{"id": "test:plank", "kind": "item"}, {"id": "test:stone", "kind": "item"},
		{"id": "test:wood_wall", "kind": "structure", "cost": {"test:plank": 3}},
		{"id": "test:stone_wall", "kind": "structure", "cost": {"test:stone": 2, "test:plank": 1}},
	])
