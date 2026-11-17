extends SceneTree
## Normal engine/LocalGame frames and a separate warm geometry rebuild.
## Run sequentially on identical disposable profile copies, with no test workers.
var app: App
var game: GameScreen
var output := ""
var previous_frame := 0
var expected_cell := Vector2i.MAX
var phases: Array = []
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func summarize(samples: Array) -> Dictionary:
	var values := samples.duplicate()
	values.sort()
	var n := values.size()
	var total := 0.0
	for value: float in values: total += value
	return {"samples": n, "p50_ms": values[n / 2] if n else 0, "p95_ms": values[mini(n - 1, n * 95 / 100)] if n else 0,
		"p99_ms": values[mini(n - 1, n * 99 / 100)] if n else 0, "max_ms": values[-1] if n else 0, "sum_ms": total,
		"mean_fps": 1000.0 * n / total if total > 0 else 0}

func frame(samples: Array) -> void:
	await process_frame
	var now := Time.get_ticks_usec()
	if previous_frame: samples.append((now - previous_frame) / 1000.0)
	previous_frame = now

func ready_view() -> bool:
	if game.client.state != "playing" or not game.client.has_position: return false
	var at := Movement.cell_of(game.client.position)
	if expected_cell != Vector2i.MAX and at != expected_cell: return false
	for y in range((at.y >> 5) - 2, (at.y >> 5) + 3):
		for x in range((at.x >> 5) - 2, (at.x >> 5) + 3):
			if not game.client.chunks.has(ServerWorld.chunk_key(game.client.location, x, y)): return false
	return game.view.pending_chunks() == 0 and game.view.object_count() > 0

func memory() -> Dictionary:
	var result := {"godot_static_bytes": OS.get_static_memory_usage()}
	var lines: Array = []
	if OS.execute("ps", PackedStringArray(["-o", "rss=", "-p", str(OS.get_process_id())]), lines) == 0:
		result["process_rss_kib"] = int(String(lines[0]).strip_edges())
	return result

func phase(name: String, seconds: float, wait_ready := false) -> void:
	var samples: Array = []
	var build: Array = []
	var began := Time.get_ticks_usec()
	var stable := 0
	previous_frame = 0
	while Time.get_ticks_usec() - began < seconds * 1000000:
		await frame(samples)
		build.append(game.view._last_build_ms)
		if wait_ready:
			stable = stable + 1 if ready_view() else 0
			if stable >= 3: break
	var row := summarize(samples)
	row["phase"] = name
	row["elapsed_ms"] = (Time.get_ticks_usec() - began) / 1000.0
	row["ready"] = ready_view()
	row["geometry_frame_cpu"] = summarize(build)
	row["memory"] = memory()
	row["server"] = game.game.server.take_stats()
	row["chunks"] = game.view._geometry.size()
	row["objects"] = game.view.object_count()
	row["actors"] = game.view._actors.size()
	row["world_time_ms"] = game.client.world_time
	row["location"] = game.client.location
	row["player_cell"] = str(Movement.cell_of(game.client.position))
	row["walkable_player_cell"] = not game.game.world.is_solid(game.client.location, Movement.cell_of(game.client.position).x, Movement.cell_of(game.client.position).y)
	row["draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	row["primitives"] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	phases.append(row)
	if wait_ready and stable < 3: failures.append("terrain did not finish: " + name)
	if not wait_ready and not row.ready: failures.append("the comparison scene changed during " + name)
	print("NATURE_FRAME_PHASE ", JSON.stringify(row))

func picture(name: String) -> void:
	await RenderingServer.frame_post_draw
	game.view.viewport.get_texture().get_image().save_png(output.path_join(name + ".png"))

func rebuild_geometry() -> void:
	# Already streamed terrain, no simulation, same normal view-build budget.
	game.set_process(false)
	game.client.changed_chunks.assign(["*"])
	var slices: Array = []
	var began := Time.get_ticks_usec()
	var complete := false
	for i in 20000:
		game.view.update_view(1.0, 0.0)
		slices.append(game.view._last_build_ms)
		await process_frame
		if game.view.pending_chunks() == 0 and not game.view._geometry.is_empty():
			complete = true
			break
	var chunks := game.view._geometry.size()
	var row := {"phase": "warm_geometry_rebuild", "elapsed_ms": (Time.get_ticks_usec() - began) / 1000.0,
		"frame_cpu_slices": summarize(slices), "finished_chunks": chunks, "complete": complete, "memory": memory()}
	row["cpu_ms_per_finished_chunk"] = row.frame_cpu_slices.sum_ms / chunks if chunks else 0
	phases.append(row)
	if not complete: failures.append("warm geometry rebuild did not finish")
	print("NATURE_FRAME_PHASE ", JSON.stringify(row))
	game.set_process(true)

func run() -> void:
	var profile := ""
	var target := Vector2i(46, -61)
	var camera_zoom := 28.0
	var stream_to := Vector2i(224, -156)
	output = ProjectSettings.globalize_path("res://build/nature-final/frames")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=").simplify_path()
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=").simplify_path()
		if arg.begins_with("--zoom="): camera_zoom = clampf(float(arg.trim_prefix("--zoom=")), 12, 48)
		if arg.begins_with("--cell="):
			var v := arg.trim_prefix("--cell=").split(",")
			target = Vector2i(int(v[0]), int(v[1]))
		if arg.begins_with("--stream-to="):
			var v := arg.trim_prefix("--stream-to=").split(",")
			stream_to = Vector2i(int(v[0]), int(v[1]))
	if not profile.begins_with(ProjectSettings.globalize_path("res://build/nature-final/")) or not output.begins_with(ProjectSettings.globalize_path("res://build/nature-final/")):
		printerr("Only disposable profile/output copies below build/nature-final are accepted")
		quit(1)
		return
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var worlds := library.list()
	if worlds.size() != 1:
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var startup_begin := Time.get_ticks_usec()
	app = App.new()
	app.configure({"profile_dir": profile, "world": String(worlds[0]["id"]), "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	root.add_child(app)
	var startup_ms := (Time.get_ticks_usec() - startup_begin) / 1000.0
	root.min_size = Vector2i(960, 540)
	root.max_size = Vector2i(960, 540)
	root.size = Vector2i(960, 540)
	root.unresizable = true
	game = app.game
	if game == null:
		quit(1)
		return
	# App applies the profile settings during startup; disable its VSync only
	# after that, so the normal settings load cannot silently re-enable it.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	game.settings.values["keyboard_walk"] = false
	game.set_process_input(false)
	game.set_process_unhandled_input(false)
	root.gui_disable_input = true
	await phase("initial_view", 180, true)
	expected_cell = target
	var move_begin := Time.get_ticks_usec()
	game.game.world.move_character(game.client.character_id, target * Movement.UNIT + Vector2i(128, 128))
	var move_ms := (Time.get_ticks_usec() - move_begin) / 1000.0
	await phase("selected_view", 180, true)
	phases[-1]["move_character_cpu_ms"] = move_ms
	if not phases[-1]["walkable_player_cell"]: failures.append("the selected comparison camera must stand on walkable ground")
	game.view.yaw = .6
	game.view.tilt = 49
	game.view.zoom = camera_zoom
	for i in 120: await process_frame
	await phase("steady_simulation", 10)
	await picture("steady")
	await rebuild_geometry()
	expected_cell = stream_to
	move_begin = Time.get_ticks_usec()
	game.game.world.move_character(game.client.character_id, stream_to * Movement.UNIT + Vector2i(128, 128))
	move_ms = (Time.get_ticks_usec() - move_begin) / 1000.0
	await phase("new_chunk_stream", 180, true)
	phases[-1]["move_character_cpu_ms"] = move_ms
	for i in 120: await process_frame
	await phase("after_stream_steady", 10)
	await picture("after-stream")
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED or Engine.max_fps != 0:
		failures.append("the native timing run must keep VSync and the FPS cap disabled")
	if root.size != Vector2i(960, 540) or game.view.viewport.size != Vector2i(960, 540):
		failures.append("the native comparison must render at 960x540")
	var report := {"startup_cpu_ms": startup_ms, "engine": Engine.get_version_info().string, "adapter": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"vsync_mode": DisplayServer.window_get_vsync_mode(), "max_fps": Engine.max_fps, "window": [root.size.x, root.size.y], "raster": [game.view.viewport.size.x, game.view.viewport.size.y], "target": [target.x, target.y], "stream_to": [stream_to.x, stream_to.y],
		"camera": str(game.view.eye.transform), "camera_zoom": camera_zoom, "surface_version": game.game.world.generator.generation_version, "phases": phases, "failures": failures, "scenario_sha256": FileAccess.get_sha256(get_script().resource_path), "sources": {}}
	for path: String in ["src/experiment_3d/world_view_3d.gd", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/ground.gdshader", "src/experiment_3d/water.gdshader", "src/experiment_3d/foliage.gdshader", "src/presentation/weather_view.gd", "src/world/surface_generator.gd", "src/world/settlements.gd", "src/server/creature_sim.gd"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path) if FileAccess.file_exists("res://" + path) else "not-present-in-baseline"
	app.quit()
	app.free()
	FileAccess.open(output.path_join("frames.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("NATURE_FRAME_RESULT ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
