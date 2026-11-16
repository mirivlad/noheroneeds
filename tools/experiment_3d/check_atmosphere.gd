extends "res://tools/experiment_3d/check_rocks.gd"
## Real saved terrain, native lighting/water/weather; only disposable profiles.
func run() -> void:
	var profile := ""
	var timed := false
	var diagnose := false
	var night_sweep := false
	var shore_study := false
	output = ProjectSettings.globalize_path("res://build/atmosphere/native")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=").simplify_path()
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg == "--bench": timed = true
		if arg == "--diagnose": diagnose = true
		if arg == "--night-sweep": night_sweep = true
		if arg == "--shore-study": shore_study = true; timed = true
	if not profile.begins_with(ProjectSettings.globalize_path("res://build/atmosphere/")):
		printerr("A disposable copied profile below build/atmosphere is required")
		quit(1)
		return
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var worlds := library.list()
	if worlds.size() != 1:
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	app = App.new()
	app.configure({"profile_dir": profile, "world": String(worlds[0]["id"]), "body": "base:human_ro_m"})
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
	g.client.time_rate = 0
	g.game.server.wait_for_disk = true
	view.models.set_wind(0)
	g.weather.set_process(false)
	await pump(50)
	verify(g.client.state == "playing", "native client joins the copied recipe-20 world")
	report = {"raster": [960, 540], "adapter": RenderingServer.get_video_adapter_name(), "sources": {}, "scenes": {}}
	for path: String in ["src/experiment_3d/world_view_3d.gd", "src/experiment_3d/ground_material_3d.gd", "src/experiment_3d/ground.gdshader", "src/experiment_3d/water.gdshader", "src/experiment_3d/foliage.gdshader", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/effects_3d.gd", "src/presentation/game_screen.gd", "src/presentation/weather_view.gd", "src/world/surface_generator.gd", "src/world/settlements.gd", "src/world/world_plan.gd", "src/server/creature_sim.gd", "assets/experiment_3d/catalog.json"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path) if FileAccess.file_exists("res://" + path) else "not-present-in-baseline"
	if night_sweep:
		await gallery()
		clock = 0.0
		g.client.world_time = clock
		world.needs._last_time = 0
		await pump(10)
		await settle()
		frame_rect(Rect2i(26, 4, 18, 15))
		view.eye.size = 16
		for energy: float in [.34, .50, .70, .90]:
			view.environment.environment.ambient_light_energy = energy
			await capture("night-%02d" % roundi(energy * 100))
		await finish_capture()
		return
	var cases := {"chasm": Vector2i(-55, -42)} if diagnose else {"crossing": Vector2i(21, -42), "chasm": Vector2i(-55, -42)}
	if not diagnose:
		var shore := natural_shore()
		verify(shore != Vector2i.MAX, "the saved planet has an unmodified natural shore")
		if shore != Vector2i.MAX: cases["shore"] = shore
	if shore_study: cases = {"shore": cases["shore"]}
	for name: String in cases:
		var at: Vector2i = cases[name]
		await move_to(at + Vector2i(0, 8))
		await settle()
		frame_rect(Rect2i(at - Vector2i(10, 8), Vector2i(20, 16)))
		view.eye.size = 18
		await capture(name)
		report.scenes[name] = {"camera": str(view.eye.transform), "time": clock}
		if name == "chasm":
			var screen := Vector2(752, 328)
			var from := view.eye.project_ray_origin(screen)
			var direction := view.eye.project_ray_normal(screen)
			var best := {"distance": INF}
			for chunk: Node in view._geometry.values():
				for node: Node in chunk.get_children():
					if node is MeshInstance3D: probe_mesh(node.mesh, node.global_transform, from, direction, best)
			report.scenes[name]["former_white_sample"] = best
			print("SNOW_DIAG ", best)
		if timed: report.scenes[name]["render_benchmark"] = await benchmark()
	if shore_study:
		report["shore_study"] = {"normal": [report.scenes.shore.render_benchmark]}
		for i in 2: report.shore_study.normal.append(await benchmark())
		view.sun.rotation_degrees = Vector3(-58, -28, 0)
		report.shore_study["old_sun_orientation"] = []
		for i in 3: report.shore_study.old_sun_orientation.append(await benchmark())
		await capture("shore-old-sun")
		await finish_capture()
		return

	if diagnose:
		await diagnose_floors()
		await finish_capture()
		return
	await gallery()
	for name: String in ["morning", "day", "evening", "night", "rain", "fog", "snow"]:
		clock = {"morning": 5.5, "day": 12.0, "evening": 19.5, "night": 0.0}.get(name, 12.0) * Daylight.HOUR_MS
		if name in ["rain", "fog", "snow"]:
			clock = weather_time(name)
			verify(clock >= 0, "the local climate has real " + name)
		if clock < 0: continue
		g.client.world_time = clock
		world.needs._last_time = int(clock)
		var player: Dictionary = world.present[g.client.character_id]
		for need: String in ["satiety", "warmth", "energy"]: player[need] = Needs.FULL
		player["health"] = world.combat.max_health_of(g.client.character_id)
		player["needs_v"] = int(player.get("needs_v", 0)) + 1
		for creature: Creature in world.creatures.creatures.values(): creature.last_time = int(clock)
		world.world_time = clock
		await pump(15)
		await settle()
		frame_rect(Rect2i(26, 4, 18, 15))
		view.eye.size = 16
		g.weather._t = 3.0
		g.weather._flash_seen = -1
		g.weather.flash = 0
		g.weather._process(0)
		g._update_hud()
		await capture("gallery-" + name)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("weather-" + name + ".png"))
		report.scenes[name] = {"camera": str(view.eye.transform), "time": clock, "rain": g.weather.rain, "snow": g.weather.snow, "fog": g.weather.fog, "sun": view.sun.light_energy, "ambient": view.environment.environment.ambient_light_energy}
		if timed and name in ["day", "rain", "snow"]: report.scenes[name]["render_benchmark"] = await benchmark()
	clock = 12.0 * Daylight.HOUR_MS
	g.client.world_time = clock
	await pump(10)
	verify(view._cell_layer(Vector2i(32, 8), "ground") == "base:water", "water presentation keeps the authoritative ground ID")
	verify(world.is_solid("surface", 32, 8) and not g.client.is_solid(32, 8), "water retains creature blocking and character swimming")
	await move_to(Vector2i(32, 6))
	await settle()
	g.client.move = Vector2i.DOWN
	for step in 100:
		await pump(1)
		if Movement.cell_of(g.client.position).y >= 8: break
	g.client.move = Vector2i.ZERO
	verify(g.client.in_water(g.client.position) and Movement.cell_of(g.client.position).y >= 8, "ordinary character movement enters the rendered water")
	frame_rect(Rect2i(26, 4, 18, 15))
	var target := hit_at(Vector2i(39, 8), 0.0)
	verify(target.get("kind") == "ground" and target.get("id") == "base:water", "the cursor picks the water's original triangles")
	view.burst_at(Vector2(35.5, 12.5) * WorldView.CELL, "chips")
	await pump(4)
	await capture("plant-feedback")
	await finish_capture()

func finish_capture() -> void:
	report.scenario_sha256 = FileAccess.get_sha256(get_script().resource_path)
	report.checks = checks
	report.failures = failures
	report.static_memory_bytes = OS.get_static_memory_usage()
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func diagnose_floors() -> void:
	var originals := []
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment() { ALBEDO = vec3(1.0, 0.0, 1.0); }"
	var debug := ShaderMaterial.new()
	debug.shader = shader
	for chunk: Node in view._geometry.values():
		for node: Node in chunk.get_children():
			if node is not MultiMeshInstance3D: continue
			var mesh: Mesh = node.multimesh.mesh
			for surface in mesh.get_surface_count():
				var mat := mesh.surface_get_material(surface)
				if mat is StandardMaterial3D and mat.albedo_color.is_equal_approx(Color("0b0a0d")):
					originals.append([mesh, surface, mat])
					(mesh as ArrayMesh).surface_set_material(surface, debug)
	print("FLOOR_DIAG meshes=", originals.size())
	await capture("chasm-magenta-floors")
	for entry: Array in originals: (entry[0] as ArrayMesh).surface_set_material(entry[1], entry[2])
	var pixels := view.viewport.get_texture().get_image()
	var screen := Vector2(-1, -1)
	for y in range(160, 500, 12):
		for x in range(200, 800, 12):
			var color := pixels.get_pixel(x, y)
			if minf(color.r, minf(color.g, color.b)) > .99: screen = Vector2(x, y)
		if screen.x >= 0: break
	print("FLOOR_DIAG white=", screen, " env=", view.environment.environment.background_color, " transparent=", view.viewport.transparent_bg)
	if screen.x < 0: return
	var from := view.eye.project_ray_origin(screen)
	var direction := view.eye.project_ray_normal(screen)
	var best := {"distance": INF}
	for chunk: Node in view._geometry.values():
		for node: Node in chunk.get_children():
			if node is MultiMeshInstance3D:
				for i in node.multimesh.instance_count:
					probe_mesh(node.multimesh.mesh, node.global_transform * node.multimesh.get_instance_transform(i), from, direction, best)
			elif node is MeshInstance3D: probe_mesh(node.mesh, node.global_transform, from, direction, best)
	print("FLOOR_DIAG actual_render_triangle=", best)

func probe_mesh(mesh: Mesh, t: Transform3D, from: Vector3, direction: Vector3, best: Dictionary) -> void:
	if mesh == null or is_zero_approx(t.basis.determinant()): return
	if (t * mesh.get_aabb()).intersects_ray(from, direction) == null: return
	var faces := mesh.get_faces()
	for i in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.ray_intersects_triangle(from, direction, t * faces[i], t * faces[i + 1], t * faces[i + 2])
		if hit == null: continue
		var distance := from.distance_to(hit)
		if distance >= best.distance: continue
		best.distance = distance
		best.point = hit
		best.transform = str(t)
		best.bounds = str(mesh.get_aabb())
		best.materials = []
		for surface in mesh.get_surface_count():
			var mat := mesh.surface_get_material(surface)
			best.materials.append(str(mat) + (" " + str(mat.albedo_color) if mat is StandardMaterial3D else (" shader=" + mat.shader.resource_path if mat is ShaderMaterial else "")))

## Find a body of real water beside a dry bank, before making the specimen.
## Sampling the raw land avoids route planning; the saved ground remains final.
func natural_shore() -> Vector2i:
	for radius in range(32, 161, 32):
		for y in range(-radius, radius + 1, 4):
			for x in range(-radius, radius + 1, 4):
				if maxi(absi(x), absi(y)) < radius - 32: continue
				if world.generator.land_at(x, y, false).what != "water": continue
				var wet := 0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if world.generator.land_at(x + dx, y + dy, false).what in ["water", "deep", "shallows"]: wet += 1
				if wet < 7: continue
				var bank := false
				for d: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
					if world.generator.land_at(x + d.x * 4, y + d.y * 4, false).what in ["land", "shore"]: bank = true
				if bank and world._part_at("surface", x, y, "ground") in ["base:water", "base:shallows", "base:deep_water"]: return Vector2i(x, y)
	return Vector2i.MAX

func gallery() -> void:
	await move_to(Vector2i(34, 16))
	await settle()
	var plants := ["base:oak", "base:birch", "base:spruce", "base:berry_bush", "base:bush", "base:dry_bush"]
	for y in range(4, 20):
		for x in range(25, 45):
			var c := world.chunk("surface", x >> 5, y >> 5)
			var ground := "base:grass" if x < 35 else "base:dirt"
			if y >= 7 and y <= 10 and x >= 28 and x <= 40:
				ground = ["base:shallows", "base:water", "base:deep_water", "base:water"][y - 7]
			c.set_cell("ground", x & 31, y & 31, ground)
			for layer: String in ["cover", "structure", "ceiling", "roof"]: c.set_cell(layer, x & 31, y & 31, "")
			c.set_props(x & 31, y & 31, {})
			if y == 12 and x >= 26 and x <= 41 and (x - 26) % 3 == 0: c.set_cell("cover", x & 31, y & 31, plants[(x - 26) / 3])
			world._changed(ServerWorld.chunk_key("surface", x >> 5, y >> 5))
	await pump(30)
	await settle()

func weather_time(kind: String) -> float:
	for quarter in Seasons.YEAR_MS / (Daylight.HOUR_MS / 4):
		var at := quarter * Daylight.HOUR_MS / 4.0
		if Daylight.sun(at) < .6: continue
		var level := 0.0
		match kind:
			"rain": level = Weather.rain(g.client.weather_seed, at, g.client.weather_place(), g.client.climate())
			"fog": level = Weather.fog(g.client.weather_seed, at, g.client.weather_place(), g.client.climate())
			"snow": level = Weather.snow(g.client.weather_seed, at, g.client.weather_place(), g.client.climate())
		if level >= .65: return at
	return -1
