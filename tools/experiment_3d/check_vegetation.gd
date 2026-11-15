extends "res://tools/experiment_3d/check_settlements.gd"
## Paired native captures in a disposable LocalGame; never opens a player's save.
const PLANTS := ["tall_grass", "clover", "reeds", "cattail", "wheat_crop", "carrot_crop", "bush", "berry_bush", "dry_bush"]
var clock := 12.0 * Daylight.HOUR_MS
var seed_value := 431
var skip_gameplay := false
var reuse_profile := ""
var gameplay_only := false

func pump(n: int) -> void:
	for i in n:
		if world: world.world_time = clock
		await super.pump(1)

func run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	output = ProjectSettings.globalize_path("res://build/vegetation/before")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--seed="): seed_value = int(arg.trim_prefix("--seed="))
		if arg == "--skip-gameplay": skip_gameplay = true
		if arg.begins_with("--profile="): reuse_profile = arg.trim_prefix("--profile=")
		if arg == "--gameplay-only": gameplay_only = true
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	if reuse_profile != "":
		if not reuse_profile.begins_with(ProjectSettings.globalize_path("res://build/vegetation/")):
			printerr("Only a disposable vegetation-review profile is accepted")
			quit(1)
			return
		profile = reuse_profile
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := "world" if reuse_profile != "" else library.create("Растительность", {"seed": str(seed_value), "starter_kit": true})
	var prepared := ServerWorld.open(library.db_path(wid), ContentRegistry.load_packs(["res://content/base"]), {"seed": seed_value, "require_planned": true})
	if prepared == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	prepared.close()
	app = App.new()
	app.configure({"profile_dir": profile, "world": wid, "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	root.add_child(app)
	g = app.game
	if g == null:
		printerr("Could not join disposable vegetation world")
		app.free()
		quit(1)
		return
	g.set_process(false)
	g.set_process_input(false)
	g.set_process_unhandled_input(false)
	root.gui_disable_input = true
	view = g.view as WorldView3D
	world = g.game.world
	world.time_rate = 0
	# Freeze animation for the paired stills; gameplay checks exercise wind below.
	if view.models.has_method("set_wind"): view.models.call("set_wind", 0.0)
	g.game.server.wait_for_disk = true
	await pump(50)
	verify(g.client.state == "playing", "real LocalGame client joined")
	verify(RenderingServer.get_current_rendering_method() == "gl_compatibility", "GL Compatibility retained")
	var home := Vector2i.ZERO  # fixed review coordinates, independent of last saved player position
	var meadow := home + Vector2i(24, 24)
	var frame_times: Array[float] = []
	if not gameplay_only:
		await move_to(meadow)
		await settle()
		frame_rect(Rect2i(meadow - Vector2i(10, 7), Vector2i(20, 14)))
		await capture("meadow")
		for i in 180:
			var start := Time.get_ticks_usec()
			await pump(1)
			frame_times.append((Time.get_ticks_usec() - start) / 1000.0)
	else:
		frame_times.resize(180)
	frame_times.sort()
	var plot := home + Vector2i(48, 16)
	await move_to(plot + Vector2i(8, 4))
	await settle()
	# Controlled planted specimens use ordinary cover IDs in this review world.
	# No such layout or resource is added to actual world generation.
	for y in range(-3, 14):
		for x in range(-3, 23):
			var at := plot + Vector2i(x, y)
			var c := world.chunk("surface", at.x >> 5, at.y >> 5)
			c.set_cell("ground", at.x & 31, at.y & 31, "base:grass")
			for layer: String in ["cover", "structure", "roof", "ceiling"]: c.set_cell(layer, at.x & 31, at.y & 31, "")
			if x >= 0 and x < 18 and x % 2 == 0 and y >= 0 and y < 12 and y % 2 == 0:
				c.set_cell("cover", at.x & 31, at.y & 31, "base:" + PLANTS[x / 2])
			c.set_props(at.x & 31, at.y & 31, {})
			world._changed(ServerWorld.chunk_key("surface", at.x >> 5, at.y >> 5))
	await pump(30)
	await settle()
	frame_rect(Rect2i(plot - Vector2i(2, 2), Vector2i(22, 15)))
	await capture("specimens")
	# A second view gives the silhouettes enough screen space to judge them.
	frame_rect(Rect2i(plot - Vector2i(1, 1), Vector2i(13, 7)))
	view.eye.size = 12
	await capture("plants-close")
	frame_rect(Rect2i(plot + Vector2i(11, -1), Vector2i(8, 7)))
	view.eye.size = 10
	await capture("bushes-close")
	if not skip_gameplay: await check_gather_and_growth(plot)
	var report := {"checks": checks, "failures": failures, "seed": seed_value, "home": str(home), "meadow": str(meadow), "plot": str(plot), "world_time": clock,
		"adapter": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(), "logical_size": str(root.size), "raster_size": str(view.viewport.size),
		"frame_p50_ms": frame_times[90], "frame_p95_ms": frame_times[170], "frame_worst_ms": frame_times[-1], "static_memory_bytes": OS.get_static_memory_usage(), "scenario_sha256": FileAccess.get_sha256(get_script().resource_path)}
	report["sources"] = {}
	for path: String in ["assets/experiment_3d/catalog.json", "content/base/terrain.json", "src/experiment_3d/plant_meshes_3d.gd", "src/experiment_3d/model_library_3d.gd", "src/experiment_3d/foliage.gdshader", "src/experiment_3d/world_view_3d.gd", "src/app/game_settings.gd"]:
		if FileAccess.file_exists("res://" + path): report.sources[path] = FileAccess.get_sha256("res://" + path)
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func check_gather_and_growth(plot: Vector2i) -> void:
	var at := plot + Vector2i(14, 0)
	await move_to(at + Vector2i.DOWN)
	await settle()
	var picked := hit_at(at, .3)
	verify(picked.get("cell") == at and picked.get("id") == "base:berry_bush", "mouse ray selects the actual berry bush: " + str(picked))
	frame_rect(Rect2i(at - Vector2i(2, 2), Vector2i(5, 5)))
	view.eye.size = 6
	await capture("berry-ripe")
	g._choose_slot(8)
	g._update_hud()  # ordinary game processing is paused in this capture harness
	await pump(8)
	verify(world.held_of(g.client.character_id) == "", "choose an empty hotbar slot before gathering by hand")
	var count := int(g.client.inventory().get("base:berries", 0))
	var r := await request({"type": "gather", "location": "surface", "x": at.x, "y": at.y, "layer": "cover", "item": ""})
	verify(r.get("ok", false) and int(g.client.inventory().get("base:berries", 0)) == count + 3, "normal server gather gives the existing three berries: " + str(r))
	if not r.get("ok", false): return
	await settle()
	verify(view._cell_layer(at, "cover") == "base:bush", "received harvest rebuilds the same bare bush")
	frame_rect(Rect2i(at - Vector2i(2, 2), Vector2i(5, 5)))
	view.eye.size = 6
	await capture("berry-harvested")
	clock += 49 * Daylight.HOUR_MS
	world.world_time = clock
	world.growth.catch_up("surface", at.x >> 5, at.y >> 5, world.chunk("surface", at.x >> 5, at.y >> 5))
	await pump(30)
	await settle()
	verify(view._cell_layer(at, "cover") == "base:berry_bush", "berries return through the existing server growth state")
	frame_rect(Rect2i(at - Vector2i(2, 2), Vector2i(5, 5)))
	view.eye.size = 6
	await capture("berry-restored")
	# Palette captures use the same server specimen and only the client's clock.
	for season in 4:
		g.client.world_time = season * Seasons.SEASON_MS + 12 * Daylight.HOUR_MS
		view.update_view(1, 0)
		for i in 200:
			view.update_view(1, 0)
			await process_frame
			if view.pending_chunks() == 0: break
		frame_rect(Rect2i(plot + Vector2i(11, -1), Vector2i(8, 7)))
		view.eye.size = 10
		await capture("season-" + str(season))
	app.settings.set_value("vegetation_wind", 1.0)
	g.apply_settings()
	verify(is_equal_approx(view.models.wind_strength, 1.0), "wind intensity applies immediately through normal settings")
	app.settings.set_value("vegetation_wind", 0.0)
	g.apply_settings()
	verify(is_zero_approx(view.models.wind_strength), "zero disables the wind on existing materials")
	app._on_menu_requested()
	app.menu.show_settings()
	await capture("settings")

func hit_at(cell: Vector2i, height := .4) -> Dictionary:
	var at := Vector2(cell) + Vector2.ONE * .5
	var point := Vector3(at.x, view.elevation(at) + height, at.y)
	# unproject_position returns physical raster pixels; screen_point takes
	# logical UI coordinates, including on fractionally scaled native windows.
	g.mouse_at = view.screen_point(view.eye.unproject_position(point) / view._pixel)
	g._update_target()
	return g.target
