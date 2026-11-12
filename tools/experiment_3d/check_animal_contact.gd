extends "res://tools/experiment_3d/check_animals.gd"
## A close native day/night and pannier check in a previously generated review profile.
func run() -> void:
	var profile := ""
	output = ProjectSettings.globalize_path("res://build/animal_sprites/contact-review")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=")
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	if not profile.begins_with(ProjectSettings.globalize_path("res://build/animal_sprites/")):
		printerr("Only a disposable animal-review profile is accepted")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	app = App.new()
	app.configure({"profile_dir":profile,"world":"world","body":"base:human_ro_m","time":"12","weather":"clear"})
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
	await pump(40)
	await settle()
	for creature: Creature in world.creatures.creatures.values().duplicate(): world.creatures.remove(creature.id)
	var cell := Movement.cell_of(g.client.position)
	var loose := world.creatures._spawn("base:horse","surface",cell+Vector2i(3,0),{},800)
	var driver := world.creatures._spawn("base:villager","surface",cell+Vector2i(-2,0),CreatureSim.villager_looks(RandomNumberGenerator.new()),801)
	driver.job = {"profession":"base:trader","purse":600,"name":"Вьючная лошадь"}
	driver.face = Vector2i.RIGHT
	world.creatures._make_caravan(driver,"pack")
	var horse := world.creatures.get_creature(String(driver.job.horse))
	for creature: Creature in [loose,driver,horse]:
		world.creatures._schedule(creature,world.tick+1000000)
		creature.target = Creature.NO_TARGET
		creature.changed()
	await pump(35)
	verify((view._actors[horse.id] as BillboardActor3D).packs!=null,"the original panniers attach to the new horse")
	for hour in [12,0]:
		# Capture lighting via the actual client clock and renderer, without
		# advancing this frozen review world between the paired images.
		g.client.world_time = hour*Daylight.HOUR_MS
		view.update_view(1.0,1.0/Movement.TICK_RATE)
		pose_view(cell+Vector2i(1,0),-.6,12)
		await process_frame
		for actor: BillboardActor3D in view._actors.values():
			actor.facing = Vector2.RIGHT
			actor.doll.turn_to(Vector2.RIGHT.rotated(-view.yaw))
			verify(actor.ground_shadow.visible,"a grounded actor has a contact shadow")
		await capture("%02d-on"%hour)
		for actor: BillboardActor3D in view._actors.values(): actor.ground_shadow.hide()
		await capture("%02d-off"%hour)
		for actor: BillboardActor3D in view._actors.values(): actor.ground_shadow.show()
	# A separated, side-facing gallery for visual review; the actors still
	# come through the ordinary server replicas and default content.
	for creature: Creature in world.creatures.creatures.values().duplicate(): world.creatures.remove(creature.id)
	var figures: Array[Creature] = []
	for i in SPECIES.size()+2:
		var kind: String = SPECIES[i] if i<SPECIES.size() else ["horse","deer"][i-SPECIES.size()]
		var at := cell+Vector2i((i%5)*4-8,(i/5)*5-5)
		var creature := spawn_variant("base:"+kind,at,850+i,1 if i>=SPECIES.size() else 0)
		world.creatures._schedule(creature,world.tick+1000000)
		creature.target = Creature.NO_TARGET
		figures.append(creature)
	await pump(35)
	for creature: Creature in figures:
		(view._actors[creature.id] as BillboardActor3D).tell_heading(Vector2.RIGHT)
	await pump(6)
	g.client.world_time = 12*Daylight.HOUR_MS
	view.update_view(1.0,1.0/Movement.TICK_RATE)
	pose_view(cell,-.6,26)
	await capture("gallery-side")
	FileAccess.open(output.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"scenario_sha256":FileAccess.get_sha256(get_script().resource_path)},"\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)
