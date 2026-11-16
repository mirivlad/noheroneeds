extends "res://tools/experiment_3d/check_nature_gameplay.gd"
## Identify the actual visible material at a suspicious natural-world raster.
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
	app.configure({"profile_dir": profile, "world": String(entries[0]["id"]), "body": "base:human_ro_m", "time": "17", "weather": "clear"})
	attach_app()
	g = app.game
	g.set_process(false)
	view = g.view as WorldView3D
	world = g.game.world
	g.game.server.wait_for_disk = true
	world.time_rate = 0
	g.client.time_rate = 0
	world.world_time = 12 * Daylight.HOUR_MS
	await pump(50)
	await move_to(Vector2i(47, -61))
	view.yaw = .6
	view.tilt = 49
	await settle()
	await capture("surface-source")
	var rows := []
	for screen: Vector2 in [Vector2(60, 310), Vector2(100, 390), Vector2(140, 455), Vector2(180, 490)]:
		var from := view.eye.project_ray_origin(screen)
		var direction := view.eye.project_ray_normal(screen)
		var best := {"distance": INF, "screen": str(screen)}
		for chunk: Node in view._geometry.values():
			for node: Node in chunk.get_children():
				if node is MultiMeshInstance3D:
					for i in node.multimesh.instance_count:
						probe(node.multimesh.mesh, node.global_transform * node.multimesh.get_instance_transform(i), from, direction, best)
				elif node is MeshInstance3D: probe(node.mesh, node.global_transform, from, direction, best)
		rows.append(best)
		print("NATURE_SURFACE_PROBE ", best)
	FileAccess.open(output.path_join("surfaces.json"), FileAccess.WRITE).store_string(JSON.stringify({"probes": rows, "checks": checks, "failures": failures, "rock_shader_sha256": FileAccess.get_sha256("res://src/experiment_3d/rock.gdshader"), "scenario_sha256": FileAccess.get_sha256(get_script().resource_path), "camera": str(view.eye.transform), "world_time": world.world_time, "raster": str(view.viewport.size)}, "  "))
	app.quit()
	app.free()
	quit(0 if failures.is_empty() else 1)

func probe(mesh: Mesh, transform: Transform3D, from: Vector3, direction: Vector3, best: Dictionary) -> void:
	if mesh == null or is_zero_approx(transform.basis.determinant()): return
	if (transform * mesh.get_aabb()).intersects_ray(from, direction) == null: return
	var faces := mesh.get_faces()
	for i in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.ray_intersects_triangle(from, direction, transform * faces[i], transform * faces[i + 1], transform * faces[i + 2])
		if hit == null or from.distance_to(hit) >= best.distance: continue
		best.distance = from.distance_to(hit)
		best.point = str(hit)
		var cell := Vector2i(floori(hit.x), floori(hit.z))
		best.cell = str(cell)
		best.ground = world._part_at("surface", cell.x, cell.y, "ground")
		best.structure = world._part_at("surface", cell.x, cell.y, "structure")
		best.materials = []
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface)
			best.materials.append(material.shader.resource_path if material is ShaderMaterial else str(material))

func settle() -> void:
	var deadline := Time.get_ticks_msec() + 300000
	var stable := 0
	while Time.get_ticks_msec() < deadline:
		await pump(1)
		var at := Movement.cell_of(g.client.position)
		var ready := true
		for y in range((at.y >> 5) - 2, (at.y >> 5) + 3):
			for x in range((at.x >> 5) - 2, (at.x >> 5) + 3):
				ready = ready and g.client.chunks.has(ServerWorld.chunk_key("surface", x, y))
		stable = stable + 1 if ready and view.pending_chunks() == 0 else 0
		if stable >= 3:
			verify(true, "all 25 native surface chunks are ready for material diagnosis")
			await physics_frame
			await physics_frame
			return
	verify(false, "all 25 native surface chunks are ready for material diagnosis")
