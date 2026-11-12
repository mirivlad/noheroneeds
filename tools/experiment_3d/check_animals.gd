extends "res://tools/experiment_3d/check_horse_candidate.gd"
## Native default-content review in an isolated LocalGame. Never opens a user save.
## --before injects the retained LPC definitions only for a controlled comparison.
const SPECIES := ["horse","deer","cow","bear","polar_bear","wolf","fox","arctic_fox","hare","sheep","chicken","cave_rat","cave_spider"]
var before := false
var review_animals: Array[Creature] = []

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/animal_sprites/game-review")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg=="--before": before = true
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-"+str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := library.create("Животные — проверка",{"seed":"431","starter_kit":true})
	var prepared := ServerWorld.open(library.db_path(wid),ContentRegistry.load_packs(["res://content/base"]),{"seed":431,"require_planned":true})
	verify(prepared!=null,"disposable world opened with real game content")
	if prepared==null:
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
	verify(g.client.state=="playing","real LocalGame client joined")
	if before:
		var old: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://build/animal_sprites/lpc-before.json"))
		for definition: Dictionary in old.defs:
			definition.atlas_path = "res://content/base/"+String(definition.atlas)
			for alt: Dictionary in definition.get("alternates",[]): alt.atlas_path = "res://content/base/"+String(alt.atlas)
			view.content.visuals[definition["for"]] = definition
	var home := world.generator.settlements.home_plan()
	var berth: Vector2i = home.parking[0]
	await move_to(berth+Vector2i(8,8))
	await settle()
	for creature: Creature in world.creatures.creatures.values().duplicate(): world.creatures.remove(creature.id)
	# Remove foreground cover in the arranged review area; terrain relief and
	# generated buildings stay real. Only this disposable world is changed.
	for y in range(berth.y-6,berth.y+19):
		for x in range(berth.x-4,berth.x+42):
			var chunk := world.chunk("surface",x>>5,y>>5)
			chunk.set_cell("cover",posmod(x,32),posmod(y,32),"")
			world.note_grown("surface",x>>5,y>>5)
	for i in SPECIES.size()+2:
		var kind: String = SPECIES[i] if i<SPECIES.size() else ["horse","deer"][i-SPECIES.size()]
		var cell := berth+Vector2i(4+(i%5)*3,6+(i/5)*4)
		var animal := spawn_variant("base:"+kind,cell,400+i,1 if i>=SPECIES.size() else 0)
		world.creatures._schedule(animal,world.tick+1000000)
		animal.face = Vector2i.RIGHT
		animal.target = Creature.NO_TARGET
		animal.changed()
		review_animals.append(animal)
	var driver := world.creatures._spawn("base:villager","surface",berth,CreatureSim.villager_looks(RandomNumberGenerator.new()),700)
	driver.job = {"profession":"base:trader","purse":600,"name":"Проверка упряжи"}
	driver.face = Vector2i.UP
	world.creatures._make_caravan(driver,"cart")
	var horse := world.creatures.get_creature(String(driver.job.horse))
	for creature: Creature in [driver,horse]:
		world.creatures._schedule(creature,world.tick+1000000)
		creature.target = Creature.NO_TARGET
		creature.changed()
	await pump(45)
	await settle()
	pose_view(berth+Vector2i(9,7),-.35,30)
	await pump(3)
	pose_view(berth+Vector2i(9,7),-.35,30)
	if before:
		for actor: BillboardActor3D in view._actors.values(): actor.ground_shadow.hide()
	await capture("gallery")
	if not before:
		for animal: Creature in review_animals:
			var actor := view._actors.get(animal.id) as BillboardActor3D
			verify(actor!=null and actor.doll is RoSprite,"default RO animal: "+animal.kind)
			if actor==null or not actor.doll is RoSprite: continue
			verify(actor.ground_shadow.visible,"contact shadow: "+animal.kind)
			var doll := actor.doll as RoSprite
			for clip: String in doll._visual.clips:
				for row in 8:
					for index in int(doll._visual.clips[clip].frames):
						doll.pinned = [clip,row,index]
						doll._frame({},0)
						await process_frame
						await RenderingServer.frame_post_draw
						var used := actor.viewport.get_texture().get_image().get_used_rect()
						verify(used.has_area() and used.position.x>0 and used.position.y>0 and used.end.x<384 and used.end.y<384,"GPU frame %s/%s/%d/%d"%[animal.kind,clip,row,index])
			doll.pinned = []
		await pump(3)
	var wagon := view._actors[driver.id] as BillboardActor3D
	var puller := view._actors[horse.id] as BillboardActor3D
	verify(wagon.cart!=null and wagon.harness!=null,"real caravan has dynamic shafts and reins")
	if not before:
		verify(not wagon.ground_shadow.visible and puller.ground_shadow.visible,"only the grounded horse has a contact shadow")
		for angle in 8:
			pose_view(berth+Vector2i(0,-1),angle*PI/4,12)
			await pump(6)
			pose_view(berth+Vector2i(0,-1),angle*PI/4,12)
			await capture("harness-%d"%angle)
		for elevation_angle in [35.0,65.0]:
			pose_view(berth+Vector2i(0,-1),-.6,12,elevation_angle)
			await pump(6)
			pose_view(berth+Vector2i(0,-1),-.6,12,elevation_angle)
			await capture("harness-tilt-%d"%int(elevation_angle))
		# A bent, server-owned heading exercises horse/cart independence.
		driver.job.caravan_heading = [0,-1]
		driver.job.horse_heading = [1,-1]
		world.creatures._move_caravan_horse(driver)
		world.creatures._cold[driver.id] = true
		await pump(35)
		pose_view(berth+Vector2i(0,-1),-.6,12)
		await pump(6)
		pose_view(berth+Vector2i(0,-1),-.6,12)
		await capture("harness-bend")
		verify(puller.facing.distance_to(wagon.facing)>.2,"horse and wagon keep distinct headings in a bend")
		await record_motion(berth,driver)
		pose_view(berth+Vector2i(18,9),-.35,30)
		await capture("gallery-moving")
		var animal := review_animals[0]
		var start := animal.pos
		world.creatures._go(animal,"flee",animal.cell()+Vector2i(16,0),true)
		world.creatures._movers[animal.id] = true
		await pump(25)
		verify(animal.pos.distance_to(start)>Movement.UNIT/2,"the server actually moves the running horse")
		verify(bool(g.client.entities[animal.id].get("running",false)),"the real client receives running state")
		var running_actor := view._actors[animal.id] as BillboardActor3D
		verify(running_actor.doll._walk>0 and running_actor.doll._running,"the real moving horse plays a distance-driven run")
		pose_view(animal.cell(),-.6,12)
		await capture("horse-running")
		# Same native scene, exact shadow on/off comparison.
		pose_view(berth+Vector2i(9,7),-.35,30)
		await pump(3)
		pose_view(berth+Vector2i(9,7),-.35,30)
		await capture("shadows-on")
		for actor: BillboardActor3D in view._actors.values(): actor.ground_shadow.hide()
		await capture("shadows-off")
	var report := {"seed":431,"controlled_setup":true,"default_content":not before,"lpc_comparison":before,
		"adapter":RenderingServer.get_video_adapter_name(),"checks":checks,"failures":failures,
		"scenario_sha256":FileAccess.get_sha256(get_script().resource_path),
		"content_sha256":FileAccess.get_sha256("res://content/base/animal_visuals.json")}
	FileAccess.open(output.path_join("capture.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func pose_view(cell: Vector2i, angle: float, size: float, elevation_angle := 49.0) -> void:
	view.yaw = angle
	view.tilt = elevation_angle
	view.zoom = size
	view.eye.size = size
	var middle := Vector2(cell)+Vector2.ONE*.5
	var focus := Vector3(middle.x,view.elevation(middle)+1,middle.y)
	view.eye.position = focus+Vector3(0,sin(deg_to_rad(elevation_angle)),cos(deg_to_rad(elevation_angle))).rotated(Vector3.UP,-angle)*65
	view.eye.look_at(focus,Vector3.UP)

func spawn_variant(kind: String, cell: Vector2i, seed_value: int, desired: int) -> Creature:
	var count: int = view.content.visual_of(kind).get("alternates",[]).size()+1
	for attempt in 64:
		var animal := world.creatures._spawn(kind,"surface",cell,{},seed_value)
		if posmod(animal.id.hash(),count)==mini(desired,count-1): return animal
		world.creatures.remove(animal.id)
	verify(false,"a stable visual variant was selected")
	return null

func record_motion(berth: Vector2i, driver: Creature) -> void:
	Engine.max_fps = 20
	var cart_start := driver.pos
	world.creatures._go(driver,"travel",driver.cell()+Vector2i(12,0),false)
	world.creatures._movers[driver.id] = true
	for running: bool in [false,true]:
		for animal: Creature in review_animals:
			world.creatures._go(animal,"flee" if running else "wander",animal.cell()+Vector2i(12,0),running)
			world.creatures._movers[animal.id] = true
		for frame in 24:
			await pump(1)
			pose_view(berth+Vector2i(12,9),-.35,30)
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join(("run" if running else "walk")+"-%02d.png"%frame))
	for animal: Creature in review_animals:
		animal.target = Creature.NO_TARGET
		animal.running = false
		world.creatures._cold[animal.id] = true
		world.creatures._movers.erase(animal.id)
	for frame in 24:
		await pump(1)
		pose_view(driver.cell()+Vector2i(2,-1),-.6,14)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("cart-%02d.png"%frame))
	verify(driver.pos.distance_to(cart_start)>Movement.UNIT,"the actual server caravan moves through its turn")
	var horse := view._actors[String(driver.job.horse)] as BillboardActor3D
	verify(horse.doll._walk>0,"the harness follows an actually walking horse")
	driver.target = Creature.NO_TARGET
	world.creatures._cold[driver.id] = true
	world.creatures._movers.erase(driver.id)
	Engine.max_fps = 60
	await pump(25)

## One real server tick and its presentation step. This is an offline capture
## at the game's 20 Hz, not a rendering-performance benchmark.
func pump(n: int) -> void:
	for i in n:
		g.game.step()
		view.update_view(1.0,1.0/Movement.TICK_RATE)
		last_frame_us = Time.get_ticks_usec()
		await process_frame
