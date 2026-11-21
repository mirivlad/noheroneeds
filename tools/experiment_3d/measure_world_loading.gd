extends SceneTree
## Native client/server startup and movement on a disposable small planet.
## Run with two absolute arguments: output directory, then profile directory.
## Repeat with the same disposable profile and a third argument "warm".

func _initialize() -> void:
	call_deferred("run")

func wait_until(predicate: Callable, timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if predicate.call(): return true
	return false

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args.size() > 3 or (args.size() == 3 and args[2] != "warm"):
		printerr("Usage: measure_world_loading.gd -- OUTPUT PROFILE [warm]")
		quit(2)
		return
	var output := String(args[0])
	var profile := String(args[1])
	var warm := args.size() == 3
	DirAccess.make_dir_recursive_absolute(output)
	var lib := WorldLibrary.new(profile.path_join("worlds"))
	var existing := lib.list()
	if (warm and existing.size() != 1) or (not warm and not existing.is_empty()):
		printerr("Use an empty disposable profile for cold runs, the same single-world profile for warm runs")
		quit(2)
		return
	var id: String
	if not warm:
		var content := ContentRegistry.load_packs(["res://content/base"])
		var plan_start := Time.get_ticks_usec()
		var plan := WorldPlan.generate(431, "small", "temperate", content)
		print("WORLD_PLAN_MS ", (Time.get_ticks_usec() - plan_start) / 1000.0)
		id = lib.create("Streaming 431", {"seed": "431", "starter_kit": true, "world_plan": plan.to_dict()})
	else:
		id = existing[0]["id"]
	var start := Time.get_ticks_usec()
	var app := App.new()
	app.configure({"profile_dir": profile, "world": id, "body": "base:human_ro_m", "time": "12", "weather": "clear", "run": true})
	root.add_child(app)
	root.size = Vector2i(960, 540)
	root.unresizable = true
	Engine.max_fps = 60
	var game := app.game
	if game == null:
		push_error("No game opened")
		quit(1)
		return
	var view := game.view
	game._opts["perf"] = true
	var client := game.client
	var world := game.game.world
	var first := await wait_until(func() -> bool: return not game.loading.visible, 120.0)
	var first_ms := (Time.get_ticks_usec() - start) / 1000.0
	var entry := {"first_view_ms": first_ms, "loaded": world.loaded_chunks(), "geometry": view._geometry.size(),
		"pending": view.pending_chunks(), "renderer": RenderingServer.get_current_rendering_method(),
		"adapter": RenderingServer.get_video_adapter_name(), "opened": first}
	print("ENTRY ", JSON.stringify(entry))
	if not first:
		quit(1)
		return
	await RenderingServer.frame_post_draw
	view.viewport.get_texture().get_image().save_png(output.path_join("entry.png"))
	var start_cell := Movement.cell_of(client.position)
	var target := start_cell + Vector2i(82, 6)
	var frame_ms: Array[float] = []
	var wrong := 0
	var wait_frames := 0
	var max_meshes := 0
	var min_zoom := view.zoom
	if not warm:
		game.orders.walk_to(target, start_cell, client.is_solid)
		var began := Time.get_ticks_usec()
		var prior := began
		while Time.get_ticks_usec() - began < 24000000:
			await process_frame
			var now := Time.get_ticks_usec()
			frame_ms.append((now - prior) / 1000.0)
			prior = now
			if game.get("_terrain_wait") == true: wait_frames += 1
			max_meshes = maxi(max_meshes, view._geometry.size())
			min_zoom = minf(min_zoom, view.eye.size)
			var center := Vector2(view._follow.x, view._follow.z)
			if not view.has_geometry_at(client.location, Vector2i(center.floor())): wrong += 1
			if not game.orders.active(): break
	var end := Movement.cell_of(client.position)
	await RenderingServer.frame_post_draw
	view.viewport.get_texture().get_image().save_png(output.path_join("exploration.png"))
	frame_ms.sort()
	var result := {"entry": entry, "start": [start_cell.x, start_cell.y], "end": [end.x, end.y],
		"target": [target.x, target.y], "insufficient_ground_frames": wrong, "waiting_frames": wait_frames, "max_meshes": max_meshes,
		"p95_frame_ms": frame_ms[int(frame_ms.size() * .95)] if not frame_ms.is_empty() else 0,
		"p99_frame_ms": frame_ms[int(frame_ms.size() * .99)] if not frame_ms.is_empty() else 0,
		"frames": frame_ms.size(),
		"max_frame_ms": frame_ms[-1] if not frame_ms.is_empty() else 0,
		"terrain_zoom": view.eye.size, "minimum_zoom": min_zoom, "window": str(root.size), "viewport": str(view.viewport.size)}
	print("RESULT ", JSON.stringify(result))
	FileAccess.open(output.path_join("runtime.json"), FileAccess.WRITE).store_string(JSON.stringify(result, "  "))
	app.quit()
	app.free()
	quit(0 if warm or (end - start_cell).length() > 64.0 else 1)
