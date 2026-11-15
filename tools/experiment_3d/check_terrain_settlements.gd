extends "res://tools/experiment_3d/check_settlements.gd"
## Reproduce M.I.R.V. in a disposable planned world. No player save is opened.
func run() -> void:
	output = ProjectSettings.globalize_path("res://build/settlement-placement/native")
	var plan_path := ProjectSettings.globalize_path("res://build/settlement-placement/mirv-plan.json")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--plan="): plan_path = arg.trim_prefix("--plan=")
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.from_dict(JSON.parse_string(FileAccess.get_file_as_string(plan_path)))
	if plan == null:
		printerr("A saved WorldPlan JSON is required for this comparison")
		quit(1)
		return
	var report := {"plan_sha256": FileAccess.get_sha256(plan_path), "seed": plan.seed_value,
		"preset": plan.preset, "climate": plan.climate, "generator": Settlements.VERSION, "districts": [], "roads": [], "settlements": []}
	report["source_sha256"] = {}
	for path: String in ["src/world/settlements.gd", "src/world/surface_generator.gd", "src/world/settlement_terrain_layout.gd", "src/experiment_3d/terrain_shape_3d.gd", "tools/experiment_3d/check_terrain_settlements.gd"]:
		report["source_sha256"][path] = FileAccess.get_sha256("res://" + path)
	var settlement_cells := {}
	var checked_road_cells := 0
	var road_collisions := []
	var generator := SurfaceGenerator.new(plan.seed_value, content, plan)
	for y in range(-1, 2):
		for x in range(-1, 2):
			var villages := []
			for p: Dictionary in generator.settlements.villages(0, x, y):
				settlement_cells.merge(p.cells, true)
				villages.append({"id": p.id, "centre": [p.centre.x, p.centre.y], "bounds": [p.bounds.position.x, p.bounds.position.y, p.bounds.size.x, p.bounds.size.y], "adaptive": p.get("adaptive", false), "buildings": p.buildings.size(), "fields": p.fields.size()})
			report.districts.append({"district": [x, y], "villages": villages})
			print("DISTRICT ", x, ",", y, " villages=", villages.size())
	for district: Vector2i in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.UP]:
		for road: Dictionary in generator.settlements.roads_of(0, district.x, district.y):
			var path := []
			for at: Vector2i in road.cells:
				checked_road_cells += 1
				var part := String(settlement_cells.get(at, {}).get("structure", ""))
				var sample := generator.land_at(at.x, at.y)
				if (part != "" and content.get_def(part).get("solid", true)) or sample.what == "deep" or (sample.what == "rock" and not sample.get("cliff", false)):
					road_collisions.append({"road": road.id, "cell": [at.x, at.y], "part": part, "terrain": sample.what})
			for at: Vector2i in road.path: path.append([at.x, at.y])
			report.roads.append({"from": road.from, "to": road.to, "path": path})
	report["checked_road_cells"] = checked_road_cells
	report["road_collisions"] = road_collisions
	verify(road_collisions.is_empty(), "all road cells avoid solid buildings, deep water and crags")
	FileAccess.open(output.path_join("overview.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	var profile := output.path_join("profile-" + str(Time.get_unix_time_from_system()) + "-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := library.create("Планировка по местности", {"seed": str(plan.seed_value), "world_plan": plan.to_dict()})
	var prepared := ServerWorld.open(library.db_path(wid), content, {"seed": plan.seed_value, "world_plan": plan.to_dict(), "require_planned": true})
	if prepared == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	prepared.close()
	app = App.new()
	app.configure({"profile_dir": profile, "world": wid, "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	root.add_child(app)
	g = app.game
	if g == null or g.game == null:
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
	await pump(50)
	verify(g.client.state == "playing", "real LocalGame client joined")
	for id: String in ["base:village@0,0#3", "base:village@0,0#2"]:
		var village := world.generator.settlements.plan_by_id(id)
		verify(not village.is_empty() and village.get("adaptive", false), "terrain-fitted settlement: " + id)
		if village.is_empty(): continue
		await move_to(village.fire + Vector2i(2, 2))
		await settle()
		frame_rect(village.bounds.grow(4))
		await capture("settlement-" + str(report.settlements.size()))
		report.settlements.append({"id": id, "adaptive": village.get("adaptive", false), "scale": village.scale, "buildings": village.buildings.size(), "fields": village.fields.size()})
		if report.settlements.size() == 1: report.caravan = await capture_caravan(village)
	report.checks = checks
	report.failures = failures
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)
