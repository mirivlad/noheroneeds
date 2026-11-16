extends "res://tools/experiment_3d/check_rocks.gd"
## Native crossings, trail movement and wide-deck comparison in disposable worlds.
const CASES := {"useful": Vector2i(21, -42), "former-cut": Vector2i(-55, -42), "small-region": Vector2i(-17, -31)}

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/routes/native")
	var timed := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg == "--baseline": baseline = true
		if arg == "--bench": timed = true
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := library.create("Переходы 431", {"seed": "431", "starter_kit": true, "world_plan": plan.to_dict()})
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
	verify(world.generator.generation_version == SurfaceGenerator.VERSION and g.client.surface_generation_version == world.generator.generation_version and view._land.generation_version == world.generator.generation_version, "server, loader and client use the world's recipe")
	report = {"seed": 431, "preset": "small", "time_ms": clock, "raster": [960, 540], "adapter": RenderingServer.get_video_adapter_name(), "surface_version": world.generator.generation_version, "sources": {}, "scenes": {}}
	for path: String in ["src/world/surface_generator.gd", "src/world/settlements.gd", "src/world/bridge_routes.gd", "src/experiment_3d/world_view_3d.gd", "content/base/terrain.json", "src/world/world_plan.gd"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path) if FileAccess.file_exists("res://" + path) else "not-present-in-baseline"
	for name: String in CASES:
		var cell: Vector2i = CASES[name]
		await move_to(cell + Vector2i(0, 8))
		await settle()
		pose(cell)
		await capture(name)
		var ground := world._part_at("surface", cell.x, cell.y, "ground")
		var sample := world.generator.land_at(cell.x, cell.y)
		var scene := {"cell": [cell.x, cell.y], "camera": str(view.eye.transform), "ground": ground, "procedural_kind": sample["what"]}
		if baseline:
			verify(sample["what"] == "bridge", "baseline has the old " + name + " bridge")
		else:
			var data: Dictionary = world.generator.call("_bridge_data", cell.x, cell.y, Vector2i.DOWN)
			scene["route"] = describe(data)
			verify(data["accepted"] == (name == "useful"), "route criterion classifies " + name)
			if name == "useful": verify(ground == "base:hanging_bridge", "useful crossing remains in authoritative terrain")
			elif ground == "base:hanging_bridge":
				var purposeful := false
				for road: Dictionary in world.generator.settlements.roads_touching(cell.x >> 5, cell.y >> 5):
					if road["cells"].has(cell): purposeful = true
				verify(purposeful, "a rejected procedural deck can only remain on a validated settlement road")
			else:
				verify(ground == "base:chasm", "unjustified deck is absent from real terrain")
		if timed: scene["render_benchmark"] = await benchmark()
		report.scenes[name] = scene
	var good := Vector2i(21, -42)
	await move_to(Vector2i(21, -44))
	await settle()
	verify(await walk_cell(Vector2i(21, -42)), "ordinary movement reaches the middle of the deck")
	pose(good)
	await capture("feet-on-deck")
	verify(await walk_cell(Vector2i(21, -39)), "ordinary client movement crosses the useful bridge")
	if not baseline:
		var route: Dictionary = world.generator.call("_bridge_data", good.x, good.y, Vector2i.DOWN)
		for path: Array in route["paths"]:
			await move_to(path[0])
			await settle()
			var walked := true
			for i in range(1, path.size()):
				if not await walk_cell(path[i]):
					walked = false
					break
			verify(walked, "ordinary movement follows a complete generated approach")
	pose(good)
	await capture("walked-crossing")
	# Controlled three-lane specimen: same authoritative cells in both builds.
	await move_to(Vector2i(21, -35))
	await settle()
	for y in range(-47, -35):
		for x in range(16, 27):
			var chunk := world.chunk("surface", x >> 5, y >> 5)
			chunk.set_cell("ground", x & 31, y & 31, "base:chasm" if y >= -43 and y <= -40 else "base:grass")
			for layer: String in ["structure", "cover", "ceiling", "roof"]: chunk.set_cell(layer, x & 31, y & 31, "")
			chunk.set_props(x & 31, y & 31, {})
			if y >= -43 and y <= -40 and x >= 20 and x <= 22: chunk.set_cell("ground", x & 31, y & 31, "base:hanging_bridge")
			world._changed(ServerWorld.chunk_key("surface", x >> 5, y >> 5))
	await pump(30)
	await settle()
	pose(good)
	view.eye.size = 12
	await capture("wide-deck")
	report.scenes["wide-deck"] = {"camera": str(view.eye.transform)}
	if timed: report.scenes["wide-deck"]["render_benchmark"] = await benchmark()
	if not baseline: verify(view.call("_hanging_axis", good) == Vector2i.DOWN, "wide deck follows the actual span")
	report.checks = checks
	report.failures = failures
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func pose(cell: Vector2i) -> void:
	# Underlying relief is unchanged by route acceptance: the camera remains
	# identical even when a former bridge becomes a chasm again.
	view.yaw = .6
	view.tilt = 49
	view.eye.size = 18
	var focus := Vector3(cell.x + .5, world.generator.metres_at(cell.x, cell.y) + 1.2, cell.y + .5)
	var offset := Vector3(0, sin(deg_to_rad(view.tilt)), cos(deg_to_rad(view.tilt))).rotated(Vector3.UP, -view.yaw) * 65
	view.eye.position = focus + offset
	view.eye.look_at(focus, Vector3.UP)

func walk_cell(cell: Vector2i) -> bool:
	var target := cell * Movement.UNIT + Vector2i(128, 128)
	for i in 120:
		var delta := target - g.client.position
		if absi(delta.x) <= Movement.WALK * .65 and absi(delta.y) <= Movement.WALK * .65:
			g.client.move = Vector2i.ZERO
			await pump(2)
			return Movement.cell_of(g.client.position) == cell
		g.client.move = Vector2i(signi(delta.x) if absi(delta.x) > Movement.WALK * .65 else 0, signi(delta.y) if absi(delta.y) > Movement.WALK * .65 else 0)
		await pump(1)
	g.client.move = Vector2i.ZERO
	return false

func describe(data: Dictionary) -> Dictionary:
	var out := {"accepted": data["accepted"]}
	for key: String in ["reason", "regions", "detour_steps"]:
		if data.has(key): out[key] = data[key]
	if data.has("paths"):
		out["paths"] = []
		for path: Array in data["paths"]:
			var cells := []
			for at: Vector2i in path: cells.append([at.x, at.y])
			out["paths"].append(cells)
	return out
