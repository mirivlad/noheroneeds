extends Node
## Normal GameScreen processing (20 Hz simulation, one view update per frame).
## Use only a disposable profile; a supplied closed fixture is copied first.
## The local frame intervals are diagnostic observations, not admitted hardware benchmarks.
var app: App
var game: GameScreen
var output := ""
var previous_frame := 0
var phases := []
var failures := []

func _ready() -> void:
	call_deferred("run")

func summarize(samples: Array) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	var n := sorted.size()
	return {"frames": n, "p50_ms": sorted[n / 2] if n else 0, "p95_ms": sorted[mini(n - 1, n * 95 / 100)] if n else 0,
		"p99_ms": sorted[mini(n - 1, n * 99 / 100)] if n else 0, "max_ms": sorted[-1] if n else 0}

func frame(samples: Array) -> void:
	await get_tree().process_frame
	var now := Time.get_ticks_usec()
	if previous_frame: samples.append((now - previous_frame) / 1000.0)
	previous_frame = now

func ready_view() -> bool:
	if game.client.state != "playing" or not game.client.has_position: return false
	var cell := Movement.cell_of(game.client.position)
	for y in range((cell.y >> 5) - 2, (cell.y >> 5) + 3):
		for x in range((cell.x >> 5) - 2, (cell.x >> 5) + 3):
			if not game.client.chunks.has(ServerWorld.chunk_key(game.client.location, x, y)): return false
	return game.view.pending_chunks() == 0 and game.view.object_count() > 0

func phase(name: String, seconds: float, wait_ready := false) -> void:
	var samples := []
	var began := Time.get_ticks_usec()
	var stable := 0
	var max_build := 0.0
	var label_ms := -1.0
	previous_frame = 0
	while Time.get_ticks_usec() - began < seconds * 1000000 or (name == "map_first" and label_ms < 0 and Time.get_ticks_usec() - began < 120000000):
		await frame(samples)
		max_build = maxf(max_build, game.view._last_build_ms)
		if name == "map_first" and label_ms < 0 and not game.world_map.places.is_empty(): label_ms = (Time.get_ticks_usec() - began) / 1000.0
		if wait_ready:
			stable = stable + 1 if ready_view() else 0
			if stable >= 3: break
	var row := summarize(samples)
	row["phase"] = name
	row["elapsed_ms"] = (Time.get_ticks_usec() - began) / 1000.0
	row["ready"] = ready_view()
	row["max_geometry_build_ms"] = max_build
	if name == "map_first": row["first_label_ms"] = label_ms
	row["server"] = game.game.server.take_stats()
	phases.append(row)
	if wait_ready and stable < 3: failures.append("terrain did not finish: " + name)
	print("FRAME_PHASE ", JSON.stringify(row))

func picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_tree().root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func run() -> void:
	var options := {}
	for arg in OS.get_cmdline_user_args():
		var pair := arg.trim_prefix("--").split("=", true, 1)
		options[pair[0]] = pair[1] if pair.size() > 1 else ""
	output = options.get("out", "")
	if output == "": get_tree().quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var plan_path: String = options.get("plan", "/home/mirivlad/git/noheroneeds/build/settlement-placement/mirv-plan.json")
	var plan := WorldPlan.from_dict(JSON.parse_string(FileAccess.get_file_as_string(plan_path)))
	if plan == null: get_tree().quit(1); return
	var content := ContentRegistry.load_packs(["res://content/base"])
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var id := library.create("Проверка фризов", {"seed": str(plan.seed_value), "world_plan": plan.to_dict()})
	if options.has("fixture"):
		if DirAccess.copy_absolute(options.fixture, library.db_path(id)) != OK: get_tree().quit(1); return
	else:
		var world := ServerWorld.open(library.db_path(id), content, {"world_plan": plan.to_dict()})
		if world == null: get_tree().quit(1); return
		world.close()
	Engine.max_fps = 60
	app = App.new()
	app.configure({"profile_dir": profile, "world": id, "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	add_child(app)
	game = app.game
	if game:
		game.set_process_input(false)
		game.set_process_unhandled_input(false)
	if game == null or game.game == null: get_tree().quit(1); return
	get_tree().root.mode = Window.MODE_WINDOWED
	get_tree().root.size = Vector2i(1800, 1013)
	await phase("initial_view", 180, true)
	await picture("initial")
	var home := game.game.world.generator.settlements.home_plan()
	game.game.world.move_character(game.client.character_id, home.fire * Movement.UNIT + Vector2i(128, 128))
	await phase("village_view", 180, true)
	await picture("village")
	var before_idle_unload := game.game.world.loaded_chunks()
	await phase("village_steady", 6)
	game.open_window("map")
	var map_start := Time.get_ticks_usec()
	await phase("map_first", 6)
	var labelled := not game.world_map.places.is_empty()
	if not labelled: failures.append("a seen village has no map label")
	var map_elapsed := (Time.get_ticks_usec() - map_start) / 1000.0
	await picture("map")
	game.world_map.zoom = .1
	await phase("map_zoom_out", 4)
	await picture("map-zoom-out")
	game.world_map.close()
	await phase("return_to_game", 4)
	await phase("unload_observation", 12)
	var world := game.game.world
	world.prefetch("surface", 2000 >> 5, 2000 >> 5)
	var extra := []
	for i in 5: await frame(extra)
	var pending_on_close := world.loader.waiting()
	var report := {"engine": Engine.get_version_info().string, "debug": OS.is_debug_build(), "seed": plan.seed_value,
		"settlement_generator": Settlements.VERSION, "plan_sha256": FileAccess.get_sha256(plan_path),
		"window": [get_tree().root.size.x, get_tree().root.size.y], "viewport": [game.view.viewport.size.x, game.view.viewport.size.y],
		"adapter": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"scope": "normal engine frames; local diagnostic timings; one run; no statistical or hardware-admission claim",
		"phases": phases, "map_has_seen_label": labelled, "map_phase_ms": map_elapsed, "pending_chunks_on_close": pending_on_close,
		"idle_unloaded_chunks": before_idle_unload - world.loaded_chunks(), "failures": failures}
	var quit_at := Time.get_ticks_usec()
	app.quit()
	app.free()
	report["quit_ms"] = (Time.get_ticks_usec() - quit_at) / 1000.0
	FileAccess.open(output.path_join("frames.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("FRAME_RESULT ", JSON.stringify(report))
	get_tree().quit(0 if failures.is_empty() else 1)
