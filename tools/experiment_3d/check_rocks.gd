extends "res://tools/experiment_3d/check_settlements.gd"
## Native LocalGame rock review. Render attachment is exactly 960x540;
## the desktop window manager cannot change the comparison's raster.
var clock := 12.0 * Daylight.HOUR_MS
var report := {}
var baseline := false

func pump(n: int) -> void:
	for i in n:
		if world: world.world_time = clock
		await super.pump(1)
		view.viewport.size = Vector2i(960, 540)

func capture(name: String) -> void:
	view.viewport.size = Vector2i(960, 540)
	await process_frame
	await RenderingServer.frame_post_draw
	view.viewport.get_texture().get_image().save_png(output.path_join(name + ".png"))

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/rocks/before")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg == "--baseline": baseline = true
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var land := SurfaceGenerator.new(431, content, plan)
	var spots := {}
	for radius in range(16, 193, 16):
		for y in range(-radius, radius + 1, 4):
			for x in range(-radius, radius + 1, 4):
				if maxi(absi(x), absi(y)) < radius - 16: continue
				var at := plan.spawn + Vector2i(x, y)
				var sample := land.land_at(at.x, at.y)
				if sample.what != "rock": continue
				var name := "cliff" if sample.get("cliff", false) else "crag"
				if not spots.has(name): spots[name] = at
		if spots.size() == 2: break
	verify(spots.size() == 2, "generated small planet has both cliffs and crags")
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := library.create("Скалы 431", {"seed": "431", "starter_kit": true, "world_plan": plan.to_dict()})
	var prepared := ServerWorld.open(library.db_path(wid), content, {"world_plan": plan.to_dict(), "require_planned": true})
	if prepared == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	prepared.close()
	app = App.new()
	app.configure({"profile_dir": profile, "world": wid, "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	root.add_child(app)
	root.min_size = Vector2i(960, 540)
	root.max_size = Vector2i(960, 540)
	root.size = Vector2i(960, 540)
	root.unresizable = true
	g = app.game
	if g == null:
		quit(1)
		return
	g.set_process(false)
	g.set_process_input(false)
	g.set_process_unhandled_input(false)
	root.gui_disable_input = true
	view = g.view as WorldView3D
	world = g.game.world
	world.time_rate = 0
	g.game.server.wait_for_disk = true
	view.models.set_wind(0)
	await pump(50)
	verify(g.client.state == "playing", "native LocalGame joined")
	verify(root.size == Vector2i(960, 540), "native window and logical render both fixed to 960x540")
	report = {"seed": 431, "preset": "small", "time_ms": clock, "raster": [960, 540],
		"adapter": RenderingServer.get_video_adapter_name(), "sources": {}, "scenes": {}}
	for path: String in ["src/experiment_3d/rock_cells_3d.gd", "src/experiment_3d/rock.gdshader", "src/experiment_3d/world_view_3d.gd", "src/world/surface_generator.gd", "content/base/terrain.json", "content/base/structures.json", "tools/experiment_3d/check_rocks.gd"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path)
	for name: String in spots:
		var at: Vector2i = spots[name]
		await move_to(at)
		await settle()
		frame_rect(Rect2i(at - Vector2i(12, 8), Vector2i(24, 16)))
		view.eye.size = 19
		await capture(name)
		report.scenes[name] = {"cell": [at.x, at.y], "camera": str(view.eye.transform)}
		report.scenes[name]["render_benchmark"] = await benchmark()
	# Specimen mass crosses x=32, so mining tests neighbour-chunk rebuilds.
	var plot := Vector2i(28, 8)
	await move_to(plot + Vector2i(4, 8))
	await settle()
	for y in range(-2, 10):
		for x in range(-2, 20):
			var at := plot + Vector2i(x, y)
			var chunk := world.chunk("surface", at.x >> 5, at.y >> 5)
			chunk.set_cell("ground", at.x & 31, at.y & 31, "base:grass")
			for layer: String in ["structure", "cover", "ceiling", "roof"]: chunk.set_cell(layer, at.x & 31, at.y & 31, "")
			chunk.set_props(at.x & 31, at.y & 31, {})
			if x >= 0 and x < 16 and x % 4 < 3 and y >= 0 and y < 4:
				chunk.set_cell("structure", at.x & 31, at.y & 31, "base:rock")
			world._changed(ServerWorld.chunk_key("surface", at.x >> 5, at.y >> 5))
	await pump(30)
	await settle()
	if not baseline: material_swatches(plot)
	frame_rect(Rect2i(plot - Vector2i(2, 3), Vector2i(20, 12)))
	view.eye.size = 17
	await capture("lithology")
	report.scenes["lithology"] = {"render_benchmark": await benchmark()}
	if not baseline: await mine_edge(plot + Vector2i(4, 3))
	report.checks = checks
	report.failures = failures
	report.static_memory_bytes = OS.get_static_memory_usage()
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func benchmark() -> Dictionary:
	# Freeze the simulation and camera while timing the real 960x540 render.
	# No VSync cap, no background test workers, and a shader/cache warm-up.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for i in 120:
		await process_frame
		await RenderingServer.frame_post_draw
	var values: Array[float] = []
	var last := Time.get_ticks_usec()
	for i in 360:
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		values.append((now - last) / 1000.0)
		last = now
	values.sort()
	return {"frames": values.size(), "p50_ms": values[180], "p95_ms": values[341], "worst_ms": values[-1],
		"raster": str(view.viewport.size), "window": str(root.size), "actors": view._actors.size(), "chunks": view._geometry.size(),
		"rendered_primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}

func mine_edge(at: Vector2i) -> void:
	await move_to(at + Vector2i.DOWN)
	await settle()
	g.hotbar.put(0, "base:pickaxe", -1)
	g._choose_slot(0)
	g._update_hud()
	await pump(8)
	var point := Vector2(at) + Vector2.ONE * .5
	g.mouse_at = view.screen_point(view.eye.unproject_position(Vector3(point.x, view.elevation(point) + .6, point.y)) / view._pixel)
	g._update_target()
	verify(g.target.get("cell") == at and g.target.get("layer") == "structure", "cursor selects the rock at the actual chunk boundary")
	var mined := false
	for i in 30:
		var result := await request({"type": "gather", "location": "surface", "x": at.x, "y": at.y, "layer": "structure", "item": "base:pickaxe"})
		await pump(25)
		if world._part_at("surface", at.x, at.y, "structure") == "":
			mined = true
			break
	verify(mined, "normal pickaxe work removes rock through the server")
	await settle()
	verify(view._cell_layer(at, "structure") == "" and not world.is_solid("surface", at.x, at.y), "rendered and authoritative collision cells both open after mining")
	frame_rect(Rect2i(at - Vector2i(4, 5), Vector2i(12, 10)))
	view.eye.size = 12
	await capture("mined-edge")
	await move_to(at + Vector2i.DOWN)
	g.client.move = Vector2i.UP
	for i in 24:
		await pump(1)
		if Movement.cell_of(g.client.position) == at: break
	g.client.move = Vector2i.ZERO
	verify(Movement.cell_of(g.client.position) == at, "normal player movement crosses the mined opening")

func material_swatches(plot: Vector2i) -> void:
	# Controlled material swatches on actual server rock, never new ore/rock
	# IDs or saved properties. Generated landscapes retain their normal styles.
	for chunk_root: Node in view._geometry.values():
		for node: Node in chunk_root.get_children():
			if not node is MeshInstance3D: continue
			var old := (node as MeshInstance3D).mesh
			if old == null or old.surface_get_material(0) != view.buildings.rock: continue
			var arrays := old.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			if colors.is_empty(): colors.resize(vertices.size())
			for i in vertices.size():
				var p := vertices[i]
				if p.x >= plot.x and p.x < plot.x + 16 and p.z >= plot.y and p.z < plot.y + 4:
					colors[i] = Color(floorf((p.x - plot.x) / 4) / 3, 0, 0, 1)
			arrays[Mesh.ARRAY_COLOR] = colors
			var replacement := ArrayMesh.new()
			replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			replacement.surface_set_material(0, view.buildings.rock)
			(node as MeshInstance3D).mesh = replacement
