extends "res://tools/experiment_3d/check_rocks.gd"
## Real-game mineral comparison and normal depletion. All writes go to a
## disposable profile below --out; never open a user's world.
const MINERALS := ["base:boulder", "base:pebbles", "base:iron_outcrop", "base:copper_outcrop", "base:silver_outcrop", "base:gold_outcrop"]
func run() -> void:
	output = ProjectSettings.globalize_path("res://build/geology/native")
	var timed := false
	var render_only := false
	var reuse_profile := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg == "--baseline": baseline = true
		if arg == "--bench": timed = true
		if arg == "--render-only": render_only = true
		if arg.begins_with("--profile="): reuse_profile = arg.trim_prefix("--profile=").simplify_path()
	if reuse_profile != "" and not reuse_profile.begins_with(ProjectSettings.globalize_path("res://build/geology/")):
		printerr("Only a disposable geology profile is accepted")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var profile := reuse_profile if reuse_profile != "" else output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := ""
	if reuse_profile != "":
		var worlds := library.list()
		if worlds.size() != 1:
			printerr("Expected one geology review world")
			quit(1)
			return
		wid = String(worlds[0]["id"])
	else:
		wid = library.create("Геология 431", {"seed": "431", "starter_kit": true, "world_plan": plan.to_dict()})
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
	verify(g.client.state == "playing", "native LocalGame joined with matching protocol")
	verify(root.size == Vector2i(960, 540), "fixed native window and render raster")
	if not baseline:
		verify(world.generator.get("generation_version") == 19 and g.client.get("surface_generation_version") == 19 and view._land.get("generation_version") == 19, "simulation, client terrain and loader agree on new-world recipe")
	report = {"seed": 431, "preset": "small", "raster": [960, 540], "time_ms": clock, "adapter": RenderingServer.get_video_adapter_name(), "sources": {}, "scenes": {}, "capture_script_sha256": FileAccess.get_sha256(get_script().resource_path)}
	for path: String in ["src/world/surface_generator.gd", "src/server/server_world.gd", "src/server/game_server.gd", "src/client/game_client.gd", "src/network/protocol.gd", "src/experiment_3d/mineral_meshes_3d.gd", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/world_view_3d.gd", "src/experiment_3d/ground.gdshader", "assets/experiment_3d/catalog.json", "content/base/terrain.json"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path) if FileAccess.file_exists("res://" + path) else "not-present-in-baseline"
	var crag := Vector2i(-22, -43)
	await move_to(crag)
	await settle()
	frame_rect(Rect2i(crag - Vector2i(12, 8), Vector2i(24, 16)))
	view.eye.size = 19
	await capture("natural-rocky")
	report.scenes["natural-rocky"] = {"cell": [crag.x, crag.y], "camera": str(view.eye.transform)}
	if timed: report.scenes["natural-rocky"]["render_benchmark"] = await benchmark()
	var plot := Vector2i(28, 8)
	await move_to(plot + Vector2i(8, 15))
	await settle()
	for y in range(-2, 18):
		for x in range(-2, 21):
			var at := plot + Vector2i(x, y)
			var chunk := world.chunk("surface", at.x >> 5, at.y >> 5)
			chunk.set_cell("ground", at.x & 31, at.y & 31, "base:gravel")
			for layer: String in ["structure", "cover", "ceiling", "roof"]: chunk.set_cell(layer, at.x & 31, at.y & 31, "")
			chunk.set_props(at.x & 31, at.y & 31, {})
			if x >= 1 and x <= 16 and (x - 1) % 3 == 0 and y >= 2 and y <= 12 and y % 2 == 0:
				chunk.set_cell("cover", at.x & 31, at.y & 31, MINERALS[(y - 2) / 2])
			world._changed(ServerWorld.chunk_key("surface", at.x >> 5, at.y >> 5))
	await pump(30)
	await settle()
	frame_rect(Rect2i(plot - Vector2i(2, 2), Vector2i(24, 20)))
	view.eye.size = 21
	await capture("mineral-gallery")
	report.scenes["mineral-gallery"] = {"camera": str(view.eye.transform), "plot": [plot.x, plot.y]}
	if timed: report.scenes["mineral-gallery"]["render_benchmark"] = await benchmark()
	if not baseline and not render_only:
		for row in range(2, 6): await mine_mineral(plot + Vector2i(1, 2 + row * 2), MINERALS[row])
		frame_rect(Rect2i(plot - Vector2i(2, 2), Vector2i(24, 20)))
		view.eye.size = 21
		await capture("depleted-outcrops")
	var db := library.db_path(wid)
	app.quit()
	app.free()
	await process_frame
	if not baseline and not render_only:
		var again := ServerWorld.open(db, content, {"require_planned": true})
		verify(again != null, "mineral world reopens after gathering")
		if again:
			for row in range(2, 6):
				var at := plot + Vector2i(1, 2 + row * 2)
				verify(again._part_at("surface", at.x, at.y, "cover") == "", "saved depleted " + MINERALS[row] + " stays empty")
			again.close()
	report.checks = checks
	report.render_only = render_only
	report.failures = failures
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func mine_mineral(at: Vector2i, id: String) -> void:
	await move_to(at + Vector2i.DOWN)
	await settle()
	g.hotbar.put(0, "base:pickaxe", -1)
	g._choose_slot(0)
	g._update_hud()
	await pump(8)
	var point := Vector2(at) + Vector2.ONE * .5
	g.mouse_at = view.screen_point(view.eye.unproject_position(Vector3(point.x, view.elevation(point) + .23, point.y)) / view._pixel)
	g._update_target()
	verify(g.target.get("cell") == at and g.target.get("id") == id and g.target.get("layer") == "cover", "cursor selects " + id)
	var drops: Dictionary = g.content.get_def(id)["gather"]["drops"]
	var old := {}
	for item: String in drops: old[item] = world.inventory(g.client.character_id).count(item)
	for i in 40:
		await request({"type": "gather", "location": "surface", "x": at.x, "y": at.y, "layer": "cover", "item": "base:pickaxe"})
		await pump(25)
		if world._part_at("surface", at.x, at.y, "cover") == "": break
	await settle()
	verify(world._part_at("surface", at.x, at.y, "cover") == "" and view._cell_layer(at, "cover") == "", "ordinary mining depletes " + id)
	for item: String in drops: verify(world.inventory(g.client.character_id).count(item) == old[item] + int(drops[item]), "unchanged yield " + item)
