extends "res://tools/experiment_3d/check_rocks.gd"
## Opens only a disposable COPY of the baseline-native profile; never a user save.
func run() -> void:
	var profile := ""
	output = ProjectSettings.globalize_path("res://build/rocks/compatibility")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=")
		if arg.begins_with("--out=" ): output = arg.trim_prefix("--out=")
	if not profile.begins_with(ProjectSettings.globalize_path("res://build/rocks/")):
		printerr("Only a disposable rock-review profile copy is accepted")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var worlds := library.list()
	if worlds.size() != 1:
		printerr("Expected one existing baseline world")
		quit(1)
		return
	var wid := String(worlds[0]["id"])
	app = App.new()
	app.configure({"profile_dir": profile, "world": wid, "body": "base:human_ro_m", "time": "12", "weather": "clear"})
	root.add_child(app)
	root.min_size = Vector2i(960, 540)
	root.max_size = Vector2i(960, 540)
	root.size = Vector2i(960, 540)
	root.unresizable = true
	g = app.game
	verify(g != null, "baseline main save opens in the candidate")
	if g == null:
		app.free()
		quit(1)
		return
	g.set_process(false)
	g.set_process_input(false)
	g.set_process_unhandled_input(false)
	view = g.view as WorldView3D
	world = g.game.world
	world.time_rate = 0
	g.game.server.wait_for_disk = true
	view.models.set_wind(0)
	await pump(50)
	var at := Vector2i(32, 11)
	verify(world._part_at("surface", at.x, at.y, "structure") == "base:rock", "original server rock survives loading without regeneration")
	await mine_edge(at)
	var db := library.db_path(wid)
	var content := g.content
	app.quit()
	app.free()
	await process_frame
	var reopened := ServerWorld.open(db, content, {"require_planned": true})
	verify(reopened != null, "save reopens after mining")
	if reopened:
		verify(reopened._part_at("surface", at.x, at.y, "structure") == "" and not reopened.is_solid("surface", at.x, at.y), "saved mined opening has priority over procedural rock on reload")
		reopened.close()
	var result := {"checks": checks, "failures": failures, "source_world": "native baseline main 829a3cb",
		"source_sha256": FileAccess.get_sha256(get_script().resource_path), "mined_cell": [at.x, at.y]}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(result, "  "))
	Art.clear()
	quit(0 if failures.is_empty() else 1)
