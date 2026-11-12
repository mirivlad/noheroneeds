extends "res://tools/experiment_3d/check_settlements.gd"
## Native LocalGame review only. Candidate visual is injected in memory;
## content JSON, server definitions and the player's saves are not changed.
var candidate_path := "res://build/animal_sprites/quaternius-checked/Horse/visual.json"

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/animal_sprites/native")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--visual="): candidate_path = arg.trim_prefix("--visual=")
	DirAccess.make_dir_recursive_absolute(output)
	var visual: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(candidate_path))
	verify(not visual.is_empty() and visual.get("format") == "ro", "candidate is an eight-direction RO sheet")
	if visual.is_empty():
		quit(1)
		return
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := library.create("Лошадь — художественная проба", {"seed":"431","starter_kit":true})
	var prepared := ServerWorld.open(library.db_path(wid), ContentRegistry.load_packs(["res://content/base"]), {"seed":431,"require_planned":true})
	if prepared == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	prepared.close()
	app = App.new()
	app.configure({"profile_dir":profile,"world":wid,"body":"base:human_ro_m","time":"12","weather":"clear"})
	root.add_child(app)
	g = app.game
	g.set_process(false)
	g.set_process_input(false)
	g.set_process_unhandled_input(false)
	app.set_process_unhandled_input(false)
	root.gui_disable_input = true
	view = g.view as WorldView3D
	world = g.game.world
	world.time_rate = 0
	g.game.server.wait_for_disk = true
	await pump(50)
	verify(g.client.state == "playing", "real LocalGame client joined")
	verify(view.content.visual_of("base:horse").get("format") == "lpc", "default horse remains LPC")
	view.content.visuals["review:horse"] = visual
	var home := world.generator.settlements.home_plan()
	var berth: Vector2i = home["parking"][0]
	await move_to(berth + Vector2i(4,7))
	await settle()
	for creature: Creature in world.creatures.creatures.values().duplicate():
		world.creatures.remove(creature.id)
	var old_horse := world.creatures._spawn("base:horse","surface",berth+Vector2i(0,4),{},71)
	var new_horse := world.creatures._spawn("base:horse","surface",berth+Vector2i(4,4),{"body_plan":"review:horse"},72)
	var driver := world.creatures._spawn("base:villager","surface",berth,CreatureSim.villager_looks(RandomNumberGenerator.new()),73)
	driver.job = {"profession":"base:trader","purse":600,"name":"Проба упряжи"}
	driver.face = Vector2i.UP
	world.creatures._make_caravan(driver,"cart")
	var harnessed := world.creatures.get_creature(driver.job["horse"])
	harnessed.looks = {"body_plan":"review:horse"}
	for creature: Creature in [old_horse,new_horse,driver,harnessed]:
		creature.next_think = 1 << 30
		creature.target = Creature.NO_TARGET
		creature.state = "idle"
		creature.face = Vector2i.RIGHT if creature in [old_horse,new_horse] else Vector2i.UP
		creature.changed()
	await pump(40)
	await settle()
	verify(view._actors.has(old_horse.id) and view._actors.has(new_horse.id), "both horses received from authoritative server")
	verify(view._actors.has(harnessed.id), "actual caravan horse received")
	var candidate := (view._actors[new_horse.id] as BillboardActor3D).doll as RoSprite
	verify(candidate != null, "candidate uses existing RoSprite in native world")
	if candidate:
		for clip: String in visual["clips"]:
			for row in 8:
				for i in int(visual["clips"][clip]["frames"]):
					candidate.pinned = [clip,row,i]
					candidate._frame({},0)
					var sprite := candidate.get_child(0) as Sprite2D
					await process_frame
					await RenderingServer.frame_post_draw
					var used := (view._actors[new_horse.id] as BillboardActor3D).viewport.get_texture().get_image().get_used_rect()
					verify(sprite.visible and sprite.region_rect.size == Vector2(visual["frame"][0],visual["frame"][1])
						and used.has_area() and used.position.x>0 and used.position.y>0 and used.end.x<384 and used.end.y<384,
						"candidate frame %s/%d/%d draws without viewport clipping" % [clip,row,i])
		candidate.pinned = []
	await pump(3)
	for angle in [-.6,.6]:
		frame_review(berth+Vector2i(2,2),angle)
		await pump(6)
		frame_review(berth+Vector2i(2,2),angle)
		await capture("horses-" + ("se" if angle < 0 else "sw"))
	frame_review(berth+Vector2i(0,-1),-.6,12)
	await pump(6)
	frame_review(berth+Vector2i(0,-1),-.6,12)
	await capture("harness-close")
	verify((view._actors[driver.id] as BillboardActor3D).cart != null, "existing cart GLB attached to server driver")
	var report := {"stage":"art candidate; default game content unchanged","seed":431,"berth":str(berth),
		"adapter":RenderingServer.get_video_adapter_name(),"checks":checks,"failures":failures,
		"visual":candidate_path,"visual_sha256":FileAccess.get_sha256(candidate_path),
		"atlas_sha256":FileAccess.get_sha256(visual["atlas_path"]),
		"scenario_sha256":FileAccess.get_sha256(get_script().resource_path)}
	FileAccess.open(output.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func frame_review(cell: Vector2i, angle: float, size := 17.0) -> void:
	view.yaw = angle
	view.tilt = 49
	view.zoom = size
	view.eye.size = size
	var middle := Vector2(cell)+Vector2.ONE*.5
	var focus := Vector3(middle.x,view.elevation(middle)+1,middle.y)
	view.eye.position = focus+Vector3(0,sin(deg_to_rad(49)),cos(deg_to_rad(49))).rotated(Vector3.UP,-angle)*65
	view.eye.look_at(focus,Vector3.UP)

func settle() -> void:
	# Follow the normal one-update-per-frame lifecycle. The previous capture
	# crashed inside the harness that forced four extra updates per frame.
	var stable := 0
	var complete := false
	for i in 1800:
		await pump(1)
		var streamed := true
		var at := Movement.cell_of(g.client.position)
		for y in range((at.y >> 5)-2,(at.y >> 5)+3):
			for x in range((at.x >> 5)-2,(at.x >> 5)+3):
				streamed = streamed and g.client.chunks.has(ServerWorld.chunk_key("surface",x,y))
		if i>=30 and streamed and view.pending_chunks()==0 and not view._geometry.is_empty():
			stable += 1
			if stable>=3:
				complete = true
				break
		else:
			stable = 0
	verify(complete,"all expected chunks received and native geometry settled")
	await physics_frame
	await physics_frame
	await pump(3)
