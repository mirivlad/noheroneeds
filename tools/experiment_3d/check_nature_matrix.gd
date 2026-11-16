extends "res://tools/experiment_3d/check_rocks.gd"
## Final native biome/season matrix in a disposable, normally generated world.
## Location proposals are from locate_nature_biomes.gd; server cells stay intact.
var seed_value := 431

func run() -> void:
	var points_path := ""
	output = ProjectSettings.globalize_path("res://build/nature-final/matrix-431")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="): seed_value = int(arg.trim_prefix("--seed="))
		if arg.begins_with("--points="): points_path = arg.trim_prefix("--points=")
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=").simplify_path()
	if not output.begins_with(ProjectSettings.globalize_path("res://build/nature-final/")):
		printerr("A disposable output below build/nature-final is required")
		quit(1)
		return
	var located: Variant = JSON.parse_string(FileAccess.get_file_as_string(points_path))
	if not located is Dictionary or not located.has(str(seed_value)):
		printerr("Biome coordinates for this seed are required")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(seed_value, "small", "temperate", content)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := library.create("Матрица природы", {"seed": str(seed_value), "starter_kit": true, "world_plan": plan.to_dict()})
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
	g.client.time_rate = 0
	g.game.server.wait_for_disk = true
	view.models.set_wind(0)
	await pump(50)
	verify(g.client.state == "playing", "native LocalGame joins seed " + str(seed_value))
	verify(RenderingServer.get_current_rendering_method() == "gl_compatibility", "GL Compatibility retained")
	report = {"seed": seed_value, "raster": [960, 540], "adapter": RenderingServer.get_video_adapter_name(), "scenes": {}, "sources": {}}
	for path: String in ["src/experiment_3d/world_view_3d.gd", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/plant_meshes_3d.gd", "src/experiment_3d/rock_cells_3d.gd", "src/experiment_3d/mineral_meshes_3d.gd", "src/experiment_3d/terrain_shape_3d.gd", "src/experiment_3d/ground.gdshader", "src/experiment_3d/water.gdshader", "src/experiment_3d/foliage.gdshader", "src/presentation/weather_view.gd", "src/world/surface_generator.gd", "src/world/settlements.gd", "src/server/creature_sim.gd", "content/base/terrain.json", "assets/experiment_3d/catalog.json"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path)
	var points: Dictionary = located[str(seed_value)]["points"]
	for name: String in ["base:forest", "base:meadow", "base:steppe", "base:mountains", "river_bank", "base:swamp"]:
		if not points.has(name) or points[name].size() != 2:
			verify(false, "a natural location exists for " + name)
			continue
		var coords: Array = points[name]
		var at := Vector2i(int(coords[0]), int(coords[1]))
		await move_to(at)
		await settle()
		at = natural_frame(at, name)
		var foot := free_near(at)
		verify(foot != Vector2i.MAX, "walkable ground near " + name)
		if foot == Vector2i.MAX: continue
		await move_to(foot)
		await settle()
		var biome := world.generator.biome_id_at(at.x, at.y)
		if name.begins_with("base:"): verify(biome == name, "real biome is " + name)
		else: verify(float(world.generator._river_near(at.x, at.y)[0]) < 10, "a natural river bank")
		var key := ServerWorld.chunk_key("surface", at.x >> 5, at.y >> 5)
		var chunk := world.chunk("surface", at.x >> 5, at.y >> 5)
		var before := Hash.sha256(ChunkCodec.encode(chunk)).hex_encode()
		var tick_before := world.tick
		for strength: float in [0.0, 1.0]:
			view.models.set_wind(strength)
			for i in 20: view.update_view(1.0, 1.0 / 60)
		view.models.set_wind(0)
		verify(world.tick == tick_before and Hash.sha256(ChunkCodec.encode(chunk)).hex_encode() == before, "decorative rendering does not alter server cells at " + name)
		for season in 4:
			set_clock(season * Seasons.SEASON_MS + 3 * Daylight.DAY_MS + 12 * Daylight.HOUR_MS)
			await pump(15)
			await settle()
			frame_rect(Rect2i(at - Vector2i(10, 8), Vector2i(20, 16)))
			view.eye.size = 19
			var label := name.trim_prefix("base:") + "-" + str(season)
			await capture(label)
			verify(view._actors.has(g.client.character_id), "RO character retained in " + label)
			report.scenes[label] = {"cell": [at.x, at.y], "player_cell": [foot.x, foot.y], "biome": biome, "season": season, "time": clock, "warmth": world.generator.geography.climate_at(at.x, at.y).x, "freezing": Seasons.freezing(clock, world.generator.geography.climate_at(at.x, at.y).x), "camera": str(view.eye.transform), "ground": world._part_at("surface", at.x, at.y, "ground"), "chunks": view._geometry.size(), "server_chunk_sha256": before, "received_chunk": g.client.chunks.has(key)}
		write_report()
	set_clock(12 * Daylight.HOUR_MS)
	var way := world._spawn_way()
	await move_to(way)
	var result := await request({"type": "climb", "location": "surface", "x": way.x, "y": way.y})
	verify(result.get("ok", false) and g.client.location == "depth:-1", "ordinary transition into the natural dungeon")
	if g.client.location == "depth:-1":
		await settle()
		frame_rect(Rect2i(way - Vector2i(10, 8), Vector2i(20, 16)))
		await capture("dungeon")
		verify(view._actors.has(g.client.character_id), "RO character retained underground")
		report.scenes.dungeon = {"cell": [way.x, way.y], "location": g.client.location, "camera": str(view.eye.transform), "time": clock}
	write_report()
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func set_clock(value: float) -> void:
	clock = value
	world.needs._last_time = int(clock)
	world.world_time = clock
	g.client.world_time = clock
	var player: Dictionary = world.present[g.client.character_id]
	for need: String in ["satiety", "warmth", "energy"]: player[need] = Needs.FULL
	player["health"] = world.combat.max_health_of(g.client.character_id)
	player["needs_v"] = int(player.get("needs_v", 0)) + 1
	for creature: Creature in world.creatures.creatures.values(): creature.last_time = int(clock)

func natural_frame(proposal: Vector2i, biome: String) -> Vector2i:
	# Sample only terrain already received around the proposal. A village yard
	# with a forest biome label is not a useful forest acceptance scene.
	var best := proposal
	var best_score := -INF
	var best_trees := 0
	for y in range(-48, 49, 8):
		for x in range(-48, 49, 8):
			var at := proposal + Vector2i(x, y)
			var sample := world.generator.land_at(at.x, at.y, false)
			if sample.what != "land": continue
			if biome.begins_with("base:") and world.generator.biome_ids[int(sample.biome)] != biome: continue
			if biome == "river_bank" and float(world.generator._river_near(at.x, at.y)[0]) >= 10: continue
			var built := 0
			var trees := 0
			var received := true
			for dy in range(-8, 9):
				for dx in range(-10, 11):
					var cell := at + Vector2i(dx, dy)
					var ground := g.client.cell_at("surface", cell, "ground")
					if ground == "": received = false
					var part := g.content.get_def(g.client.cell_at("surface", cell, "structure"))
					if not part.is_empty() and not bool(part.get("natural", false)): built += 1
					if g.client.cell_at("surface", cell, "cover") in ["base:oak", "base:maple", "base:birch", "base:spruce", "base:fir"]: trees += 1
			if not received: continue
			var matching := 0
			for offset: Vector2i in [Vector2i.ZERO, Vector2i(-8,-6), Vector2i(8,-6), Vector2i(-8,6), Vector2i(8,6)]:
				var here := at + offset
				var near := world.generator.land_at(here.x, here.y, false)
				if biome.begins_with("base:") and world.generator.biome_ids[int(near.biome)] == biome and near.what == "land": matching += 1
			var score := -built * 100.0 + matching * 10.0 - Vector2(at - proposal).length() * .01
			if biome == "base:forest": score += trees
			if score > best_score:
				best_score = score
				best = at
				best_trees = trees
	if biome == "base:forest": verify(best_trees >= 5, "forest frame contains a natural stand of trees")
	print("NATURE_FRAME_SELECTION ", biome, " proposal=", proposal, " selected=", best, " trees=", best_trees)
	return best

func free_near(at: Vector2i) -> Vector2i:
	for radius in range(0, 9):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if maxi(absi(x), absi(y)) != radius: continue
				var here := at + Vector2i(x, y)
				if not world.is_solid("surface", here.x, here.y): return here
	return Vector2i.MAX

func write_report() -> void:
	report.checks = checks
	report.failures = failures
	report.scenario_sha256 = FileAccess.get_sha256(get_script().resource_path)
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
