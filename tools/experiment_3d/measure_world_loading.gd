extends SceneTree
## Native client/server startup and movement on a disposable small planet.
## Run with two absolute arguments: output directory, then profile directory.
## Optional "warm" reuses the disposable profile. "wide" tests the edge at maximum zoom.

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
	if args.size() < 2 or args.size() > 4 or Array(args.slice(2)).any(func(arg: String) -> bool: return arg not in ["warm", "wide"]):
		printerr("Usage: measure_world_loading.gd -- OUTPUT PROFILE [warm] [wide]")
		quit(2)
		return
	var output := String(args[0])
	var profile := String(args[1])
	var warm := "warm" in args.slice(2)
	var wide := "wide" in args.slice(2)
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
	root.size = Vector2i(1800, 1012) if wide else Vector2i(960, 540)
	root.unresizable = true
	Engine.max_fps = 60
	var game := app.game
	if game == null:
		push_error("No game opened")
		quit(1)
		return
	var view := game.view
	if wide:
		view.zoom = 48.0
		view.yaw = .66
		view.tilt = 55.0
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
	await process_frame
	capture(view, output.path_join("entry.png"))
	var start_cell := Movement.cell_of(client.position)
	var target := start_cell + Vector2i(82, 6)
	var frame_ms: Array[float] = []
	var wrong := 0
	var wait_frames := 0
	var missing_walk_data := 0
	var outside := 0
	var draw_calls: Array[float] = []
	var primitives: Array[float] = []
	var memory_peak := 0.0
	var max_meshes := 0
	var min_zoom := view.zoom
	var supports_preview := view.has_method("has_surface_at")
	if not warm:
		game.orders.walk_to(target, start_cell, client.is_solid)
		var began := Time.get_ticks_usec()
		var prior := began
		while Time.get_ticks_usec() - began < 24000000:
			await process_frame
			var now := Time.get_ticks_usec()
			frame_ms.append((now - prior) / 1000.0)
			prior = now
			var direction := game._last_dir
			if game.get("_terrain_wait") == true:
				wait_frames += 1
				var a := Movement.cell_of(client.position)
				var b := Movement.cell_of(client.position + direction * Movement.RUN)
				if not client.chunks.has(client.chunk_key(client.location, a.x >> 5, a.y >> 5)) \
						or not client.chunks.has(client.chunk_key(client.location, b.x >> 5, b.y >> 5)):
					missing_walk_data += 1
			var own := Vector2(client.position) / Movement.UNIT
			var feet := Vector3(own.x, view.elevation(own), own.y)
			if not Rect2(Vector2.ZERO, Vector2(view.viewport.size)).has_point(view.eye.unproject_position(feet)):
				outside += 1
			draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
			memory_peak = maxf(memory_peak, Performance.get_monitor(Performance.MEMORY_STATIC))
			max_meshes = maxi(max_meshes, view._geometry.size())
			min_zoom = minf(min_zoom, view.eye.size)
			var center := Vector2(view._follow.x, view._follow.z)
			if wide:
				for uv: Vector2 in [Vector2(.01, .01), Vector2(.99, .01), Vector2(.01, .99), Vector2(.99, .99)]:
					var pixel := uv * Vector2(view.viewport.size)
					var ray := view.eye.project_ray_normal(pixel)
					var ray_origin := view.eye.project_ray_origin(pixel)
					var point := ray_origin + ray * ((view._follow.y - ray_origin.y) / ray.y)
					var sample := Vector2i(floori(point.x), floori(point.z))
					var covered: bool = view.call("has_surface_at", sample) if supports_preview else view.has_geometry_at(client.location, sample)
					if not covered:
						wrong += 1
						if wrong == 1: capture(view, output.path_join("missing-corner.png"))
						break
			elif supports_preview:
				if not view.call("has_surface_at", Vector2i(center.floor())): wrong += 1
			elif not view.has_geometry_at(client.location, Vector2i(center.floor())):
				wrong += 1
			if not game.orders.active(): break
	var end := Movement.cell_of(client.position)
	capture(view, output.path_join("exploration.png"))
	frame_ms.sort()
	draw_calls.sort()
	primitives.sort()
	var result := {"entry": entry, "start": [start_cell.x, start_cell.y], "end": [end.x, end.y],
		"target": [target.x, target.y], "insufficient_ground_frames": wrong, "waiting_frames": wait_frames, "max_meshes": max_meshes,
		"p95_frame_ms": frame_ms[int(frame_ms.size() * .95)] if not frame_ms.is_empty() else 0,
		"p99_frame_ms": frame_ms[int(frame_ms.size() * .99)] if not frame_ms.is_empty() else 0,
		"frames": frame_ms.size(), "movement_wait_missing_data": missing_walk_data,
		"player_outside_frames": outside, "godot_memory_peak_mib": memory_peak / 1048576.0,
		"p95_draw_calls": draw_calls[int(draw_calls.size() * .95)] if not draw_calls.is_empty() else 0,
		"p95_primitives": primitives[int(primitives.size() * .95)] if not primitives.is_empty() else 0,
		"max_frame_ms": frame_ms[-1] if not frame_ms.is_empty() else 0,
		"terrain_zoom": view.eye.size, "minimum_zoom": min_zoom, "window": str(root.size), "viewport": str(view.viewport.size)}
	print("RESULT ", JSON.stringify(result))
	FileAccess.open(output.path_join("runtime.json"), FileAccess.WRITE).store_string(JSON.stringify(result, "  "))
	app.quit()
	app.free()
	quit(0 if warm or (wrong == 0 and outside == 0 and (end - start_cell).length() > (80.0 if wide else 64.0)) else 1)

func capture(view: WorldView3D, path: String) -> void:
	var image := view.viewport.get_texture().get_image()
	if image and not image.is_empty(): image.save_png(path)
