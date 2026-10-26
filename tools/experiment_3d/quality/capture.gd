extends "res://tools/experiment_3d/check_runtime.gd"
## Repeatable captures of real generated chunks. No decorative test level.
var clock := 10 * Daylight.HOUR_MS
var frames: Array[float] = []
func pump(n: int) -> void:
	for i in n:
		if world: world.world_time = clock
		var start := Time.get_ticks_usec()
		await super.pump(1)
		frames.append((Time.get_ticks_usec() - start) / 1000.0)

func run() -> void:
	output = "/tmp/nhn-quality-before"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var lib := WorldLibrary.new(profile.path_join("worlds"))
	var world_id := lib.create("Качество 431", {"seed": "431", "starter_kit": true})
	var prepared := ServerWorld.open(lib.db_path(world_id), ContentRegistry.load_packs(["res://content/base"]), {"seed": 431})
	prepared.close()
	app = App.new()
	app.configure({"renderer": "3d", "profile_dir": profile, "world": world_id, "time": "10", "weather": "clear"})
	root.add_child(app)
	g = app.game
	g.set_process(false)
	view = g.view as WorldView3D
	world = g.game.world
	g.game.server.wait_for_disk = true
	# Clear weather at both real locations using the existing Weather model.
	for seed_value in 10000:
		if Weather.kind(seed_value, clock, Vector2i(28,1), world.generator.geography.climate_at(28,1)) == "clear" and Weather.kind(seed_value, clock, Vector2i(-231,816), world.generator.geography.climate_at(-231,816)) == "clear":
			world.weather_seed = seed_value
			break
	await pump(50)
	var timings := {}
	for area: String in ["village", "mountain"]:
		var cell := Vector2i(28, 1) if area == "village" else Vector2i(-231, 816)
		await move_to(cell + Vector2i(2, 0))
		view.zoom = 16.875 if area == "village" else 38
		view.tilt = 49 if area == "village" else 38
		view.yaw = .6
		await settle()
		for angle in 4:
			view.yaw = .6 + angle * PI / 2
			await pump(80)
			await capture(area + "-" + str(angle))
		frames.clear()
		var start := Time.get_ticks_usec()
		await pump(300)
		frames.sort()
		timings[area] = {"seconds_300_frames": (Time.get_ticks_usec() - start) / 1e6, "chunks": view._geometry.size(), "pending": view.pending_chunks(), "objects": view.object_count(), "p95_ms":frames[284], "worst_ms":frames[-1]}
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify({"seed":431,"logical_size":str(view.viewport.size),"window_size":str(DisplayServer.window_get_size()),"weather_seed":world.weather_seed,"weather_time_ms":clock,"adapter":RenderingServer.get_video_adapter_name(), "timings":timings}, "\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit()
