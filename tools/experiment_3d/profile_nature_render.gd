extends "res://tools/experiment_3d/measure_nature_frame_latency.gd"
## Controlled within-scene rendering probes. No production source is changed.
var material_shaders: Array = []
var small_casters: Array = []
var decor_casters: Array = []
var opaque: Shader
var results: Array = []

func run() -> void:
	var profile := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=").simplify_path()
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=").simplify_path()
	if not profile.begins_with(ProjectSettings.globalize_path("res://build/nature-final/")) or not output.begins_with(ProjectSettings.globalize_path("res://build/nature-final/")):
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var entries := library.list()
	app = App.new()
	app.configure({"profile_dir": profile, "world": String(entries[0]["id"]), "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	root.add_child(app)
	root.min_size = Vector2i(960, 540)
	root.max_size = Vector2i(960, 540)
	root.size = Vector2i(960, 540)
	root.unresizable = true
	game = app.game
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	game.settings.values["keyboard_walk"] = false
	game.set_process_input(false)
	game.set_process_unhandled_input(false)
	root.gui_disable_input = true
	await phase("probe_initial", 300, true)
	expected_cell = Vector2i(46, -61)
	game.game.world.move_character(game.client.character_id, expected_cell * Movement.UNIT + Vector2i(128, 128))
	await phase("probe_selected", 300, true)
	game.view.yaw = .6
	game.view.tilt = 49
	game.view.zoom = 28
	for i in 120: await process_frame
	game._opts["perf"] = true
	await phase("normal_cpu_profile", 10)
	game._opts.erase("perf")
	game.set_process(false)
	var view := game.view as WorldView3D
	var lines := PackedStringArray()
	for line: String in ModelLibrary3D.FOLIAGE.code.split("\n"):
		if line.strip_edges().begins_with("ALPHA =") or line.strip_edges().begins_with("ALPHA_SCISSOR_THRESHOLD ="): continue
		lines.append(line)
	opaque = Shader.new()
	opaque.code = "\n".join(lines)
	for material: Variant in view.models._materials.values():
		if not material is ShaderMaterial or material.shader != ModelLibrary3D.FOLIAGE: continue
		if material.get_shader_parameter("vertex_colors") != true or material.get_shader_parameter("has_tex") == true: continue
		material_shaders.append([material, material.shader])
	var grasses := []
	for variant in 3: grasses.append(view.models.decorative_grass(variant))
	for chunk: Node in view._geometry.values():
		for node: Node in chunk.get_children():
			if not node is MultiMeshInstance3D: continue
			var mesh: Mesh = node.multimesh.mesh
			if mesh in grasses: decor_casters.append([node, node.cast_shadow])
			var low_foliage := false
			for surface in mesh.get_surface_count():
				var mat := mesh.surface_get_material(surface)
				if mat is ShaderMaterial and mat.shader == ModelLibrary3D.FOLIAGE and float(mat.get_shader_parameter("height")) < 1.8:
					low_foliage = true
			if low_foliage: small_casters.append([node, node.cast_shadow])
	RenderingServer.viewport_set_measure_render_time(view.viewport.get_viewport_rid(), true)
	await sample("original")
	var near20_changed := near_shadows(20.0)
	await sample("low-foliage-near20m")
	set_shadows(small_casters, true)
	set_opaque(true)
	await sample("procedural-opaque")
	set_opaque(false)
	set_shadows(decor_casters, false)
	await sample("decor-no-shadows")
	set_shadows(decor_casters, true)
	set_shadows(small_casters, false)
	await sample("low-foliage-no-shadows")
	set_shadows(small_casters, true)
	set_opaque(true)
	set_shadows(decor_casters, false)
	await sample("opaque-and-decor-no-shadows")
	set_shadows(decor_casters, true)
	set_opaque(false)
	await sample("original-repeat")
	# A matched still isolates the opaque-pipeline change from wind deformation.
	view.models.set_wind(0)
	await picture("original-still")
	set_opaque(true)
	await picture("opaque-still")
	set_opaque(false)
	near_shadows(20.0)
	await picture("near20-still")
	set_shadows(small_casters, true)
	var report := {"cases": results, "failures": failures, "near20_changed": near20_changed, "opaque_materials": material_shaders.size(), "decor_casters": decor_casters.size(), "low_foliage_casters": small_casters.size(),
		"raster": str(view.viewport.size), "camera": str(view.eye.transform), "adapter": RenderingServer.get_video_adapter_name(), "scenario_sha256": FileAccess.get_sha256(get_script().resource_path), "sources": {}}
	for path: String in ["src/experiment_3d/world_view_3d.gd", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/foliage.gdshader", "src/experiment_3d/rock.gdshader"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path)
	FileAccess.open(output.path_join("render-probes.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	app.quit()
	app.free()
	quit(0 if failures.is_empty() else 1)

func set_opaque(enabled: bool) -> void:
	for entry: Array in material_shaders:
		(entry[0] as ShaderMaterial).shader = opaque if enabled else entry[1]

func set_shadows(entries: Array, restore: bool) -> void:
	for entry: Array in entries:
		(entry[0] as GeometryInstance3D).cast_shadow = entry[1] if restore else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func sample(label: String) -> void:
	for i in 120:
		await process_frame
		await RenderingServer.frame_post_draw
	var values: Array = []
	var cpu: Array = []
	var gpu: Array = []
	var last := Time.get_ticks_usec()
	var rid := game.view.viewport.get_viewport_rid()
	for i in 360:
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		values.append((now - last) / 1000.0)
		last = now
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	var row := summarize(values)
	row["case"] = label
	row["viewport_cpu_ms"] = summarize(cpu)
	row["viewport_gpu_ms"] = summarize(gpu)
	row["draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	row["primitives"] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	row["actors"] = game.view._actors.size()
	row["chunks"] = game.view._geometry.size()
	results.append(row)
	print("NATURE_RENDER_PROBE ", JSON.stringify(row))

func near_shadows(radius: float) -> int:
	var p := Vector2(game.client.position) / Movement.UNIT
	var changed := 0
	for entry: Array in small_casters:
		var node := entry[0] as MultiMeshInstance3D
		var bounds := node.global_transform * node.multimesh.get_aabb()
		var nearest := Vector2(clampf(p.x, bounds.position.x, bounds.end.x), clampf(p.y, bounds.position.z, bounds.end.z))
		if nearest.distance_squared_to(p) > radius * radius:
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			changed += 1
	return changed
