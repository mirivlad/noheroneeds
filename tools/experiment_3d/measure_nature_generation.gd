extends SceneTree
## Cold detailed generation, before/after routes, in the same current engine.
## Run without background jobs; this is CPU generation, not frame/GPU timing.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var version := 20
	var output := ProjectSettings.globalize_path("res://build/nature-final/generation-20.json")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--version="): version = int(arg.trim_prefix("--version="))
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	if version not in [19, 20]:
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var content := ContentRegistry.load_packs(["res://content/base"])
	var report := {"surface_version": version, "worlds": {}, "sources": {}, "scenario_sha256": FileAccess.get_sha256(get_script().resource_path)}
	for path: String in ["src/world/surface_generator.gd", "src/world/bridge_routes.gd", "src/world/settlements.gd", "src/world/hospitality_plans.gd", "src/world/world_plan.gd", "content/base/terrain.json"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path)
	for seed_value in [2, 431, 991]:
		var started := Time.get_ticks_usec()
		var plan := WorldPlan.generate(seed_value, "small", "temperate", content)
		var plan_ms := (Time.get_ticks_usec() - started) / 1000.0
		var generator := SurfaceGenerator.new(seed_value, content, plan, version)
		var rows := []
		var times: Array[float] = []
		# Same near-to-far request order as a normally streamed starting view.
		var cells: Array[Vector2i] = []
		for y in range(-2, 3):
			for x in range(-2, 3): cells.append(Vector2i(x, y))
		cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.length_squared() < b.length_squared() if a.length_squared() != b.length_squared() else (a.y < b.y if a.y != b.y else a.x < b.x))
		for at: Vector2i in cells:
			started = Time.get_ticks_usec()
			var chunk := generator.generate(at.x, at.y)
			var ms := (Time.get_ticks_usec() - started) / 1000.0
			times.append(ms)
			rows.append({"chunk": [at.x, at.y], "cpu_ms": ms, "sha256": Hash.sha256(ChunkCodec.encode(chunk)).hex_encode()})
			print("NATURE_GENERATION ", version, " seed=", seed_value, " chunk=", at, " ms=", ms)
		times.sort()
		var total := 0.0
		for value: float in times: total += value
		report.worlds[str(seed_value)] = {"plan_ms": plan_ms, "plan_sha256": JSON.stringify(plan.to_dict()).sha256_text(), "chunks": rows, "total_cpu_ms": total, "p50_ms": times[times.size() / 2], "p95_ms": times[mini(times.size() - 1, times.size() * 95 / 100)], "max_ms": times[-1]}
		FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	quit()
