extends TestCase
## GDD scenario 20: a dedicated server under 10 and 20 bot players over real
## ENet, measured (run: tools/run_tests.sh --bench --only=bench_load).
## --load_seconds=N changes the length of each run (default 60).


func bench_10_players() -> void:
	_run(10)


func bench_20_players() -> void:
	_run(20)


## ADR-0018: the same with 500 creatures (animals and villagers) around the
## players, living by their senses, saved, replicated.
func bench_10_players_500_creatures() -> void:
	_run(10, 500)


func bench_20_players_500_creatures() -> void:
	_run(20, 500)


func _run(n: int, creatures := 0) -> void:
	var dir := tmp_dir()
	var port := 42000 + n + creatures
	var seconds := int(options.get("load_seconds", 60))
	var server := spawn_godot("res://src/server/server_main.gd", ["--world=" + dir.path_join("world.db"),
		"--port=%d" % port, "--identity=" + ProjectSettings.globalize_path("user://test_keys/server"),
		"--stats=5", "--starter-kit=base:plank:200,base:stone:100", "--populate=%d" % creatures])
	if not check(read_until(server, "LISTENING") != "", "server started"):
		OS.kill(server["pid"])
		return
	var bots := spawn_godot("res://tests/support/load_bots.gd", ["--connect=127.0.0.1:%d" % port,
		"--bots=%d" % n, "--seconds=%d" % seconds])
	var report := read_until(bots, "BOTS {", (seconds + 180) * 1000)
	FileAccess.open(dir.path_join("STOP"), FileAccess.WRITE).close()
	var stats: Array = []
	var io: FileAccess = server["stdio"]
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var line := io.get_line()
		if line.begins_with("STATS "):
			stats.append(JSON.parse_string(line.substr(6)))
		elif line == "STOPPED":
			break
		elif line == "":
			OS.delay_msec(20)
	OS.kill(server["pid"])
	if not check(report != "", "bots finished"):
		OS.kill(bots["pid"])
		return
	var r: Dictionary = JSON.parse_string(report.substr(5))
	for k: String in r:
		print("MEASURE load%d_c%d_%s %s" % [n, creatures, k, r[k]])
	# Tick times and traffic while everyone played (skip the joining window).
	var full := stats.filter(func(s: Dictionary) -> bool: return int(s["players"]) == n)
	var p99 := 0
	var worst := 0
	var bytes := 0.0
	var ticks := 0
	var windows := 0
	var prev: Array = []
	for s: Dictionary in stats:
		print("  window: players %d, tick p50 %d p99 %d max %d us, sync loads %d, %s" % [int(s["players"]), int(s["p50"]),
			int(s["p99"]), int(s["max"]), int(s.get("sync_loads", 0)), JSON.stringify(s.get("sections_ms", {}))])
		print("    slowest tick: " + JSON.stringify(s.get("slowest_ms", {})))
		if prev.is_empty():
			prev = s["bytes"]
			continue
		if int(s["players"]) == n:
			p99 = maxi(p99, int(s["p99"]))
			worst = maxi(worst, int(s["max"]))
			for ch in 3:
				bytes += float(s["bytes"][ch]) - float(prev[ch])
			ticks += int(s["ticks"])
			windows += 1
		prev = s["bytes"]
	print("MEASURE load%d_c%d_server_tick_p99_worst_window %d us" % [n, creatures, p99])
	print("MEASURE load%d_c%d_server_tick_max %d us" % [n, creatures, worst])
	if ticks > 0:
		print("MEASURE load%d_c%d_out_per_client %.1f KB/s" % [n, creatures, bytes / (ticks / 20.0) / n / 1024.0])
		print("MEASURE load%d_c%d_ticks_per_second %.1f" % [n, creatures, ticks / (windows * 5.0)])
	eq(int(r["playing"]), n, "every bot played")
	eq(int(r["unanswered"]) <= n, true, "requests answered (a few may be in flight at the end)")
