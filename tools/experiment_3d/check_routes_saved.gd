extends "res://tools/experiment_3d/check_routes.gd"
## Only disposable copies of real pre-change profiles are accepted.
func run() -> void:
	var profile := ""
	var expected := 19
	output = ProjectSettings.globalize_path("res://build/routes/compatibility")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=").simplify_path()
		if arg.begins_with("--version="): expected = int(arg.trim_prefix("--version="))
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	if not profile.begins_with(ProjectSettings.globalize_path("res://build/routes/")) or expected not in [18, 19]:
		printerr("Only a copied recipe 18/19 profile below build/routes is accepted")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var worlds := library.list()
	if worlds.size() != 1:
		quit(1)
		return
	app = App.new()
	app.configure({"profile_dir": profile, "world": String(worlds[0]["id"]), "body": "base:human_ro_m", "time": "12", "weather": "clear"})
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
	verify(g.client.state == "playing", "old world joins through the real client")
	verify(world.generator.generation_version == expected and world.loader._generator.generation_version == expected and g.client.surface_generation_version == expected and view._land.generation_version == expected, "saved recipe reaches simulation, loader and rendering")
	verify(world.store.read_meta("surface_generator_version") == str(expected), "opening did not upgrade saved metadata")
	verify(not world.store.get_chunk("surface", 0, -2).is_empty(), "the original visited crossing chunk exists in the save")
	verify(world._part_at("surface", 21, -42, "ground") == "base:hanging_bridge", "saved bridge remains authoritative")
	# This distant cell was not visited by either baseline capture profile.
	var at := Vector2i(224, -156)
	verify(world.store.get_chunk("surface", at.x >> 5, at.y >> 5).is_empty(), "test crossing starts in unexplored territory")
	verify(world.generator.land_at(at.x, at.y)["what"] == "bridge", "saved recipe still predicts its old distant bridge")
	var current := SurfaceGenerator.new(431, g.content, (world.generator.geography as PlannedGeography).plan)
	verify(current.land_at(at.x, at.y)["what"] != "bridge", "new worlds would use a different route decision here")
	verify(world._part_at("surface", at.x, at.y, "ground") == "base:hanging_bridge", "unexplored old land is generated with its saved recipe")
	await move_to(at + Vector2i(0, 7))
	await settle()
	pose(at)
	await capture("preserved-old-crossing")
	verify(view._cell_layer(at, "ground") == "base:hanging_bridge", "the client receives the preserved old bridge")
	var result := {"checks": checks, "failures": failures, "saved_surface_version": expected, "source_sha256": FileAccess.get_sha256(get_script().resource_path)}
	result["sources"] = {}
	for path: String in ["src/world/surface_generator.gd", "src/world/settlements.gd", "src/server/creature_sim.gd", "src/experiment_3d/world_view_3d.gd", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/ground.gdshader", "src/experiment_3d/water.gdshader", "src/experiment_3d/foliage.gdshader"]:
		result.sources[path] = FileAccess.get_sha256("res://" + path)
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(result, "  "))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)
