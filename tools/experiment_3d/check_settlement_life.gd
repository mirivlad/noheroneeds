extends "res://tools/experiment_3d/check_settlements.gd"
## Controlled life-cycle capture using real saved cells, LocalGame and native GPU.
## godot --path . --audio-driver Dummy -s res://tools/experiment_3d/check_settlement_life.gd -- --out=build/settlement-life-review

var village := ""
var history: Array = []
var cleared_animals := 0


func day() -> void:
	var player: Dictionary = world.present[g.client.character_id]
	player["satiety"] = Needs.FULL
	player["warmth"] = Needs.FULL
	player["energy"] = Needs.FULL
	player["health"] = world.combat.max_health_of(g.client.character_id)
	world.time_rate = Daylight.DAY_MS
	world.advance_time()
	world.time_rate = 0
	world.economy.store(village)
	world.settlement_life.step(village)
	var s := world.settlement_population.state(village)
	history.append({"day": world.world_time / Daylight.DAY_MS, "population": s["population"],
		"leaving": (s["leaving"] as Dictionary).size(), "departed": (s["departed"] as Dictionary).size(),
		"condition": world.economy.development(village).duplicate(true)})


func fund(coins: int) -> void:
	var store := world.economy.store(village)
	store["coins"] = coins
	for item: String in world.economy.needs(village):
		store["stock"][item] = 10000
	for item: String in ["base:log", "base:plank", "base:stone", "base:cloth"]:
		store["stock"][item] = 10000
	world.economy._save(village)


func house_frame(rect: Rect2i, name: String) -> void:
	await settle()
	frame_rect(rect.grow(3))
	Input.warp_mouse(Vector2(20, root.size.y / 2))
	await pump(2)
	# pump updates the follow camera, so position the evidence camera last.
	frame_rect(rect.grow(3))
	await capture(name)


func run() -> void:
	output = ProjectSettings.globalize_path("res://build/settlement-life-review")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var world_id := library.create("Жизнь поселения", {"seed": "7", "starter_kit": true})
	var db := library.db_path(world_id)
	var registry := ContentRegistry.load_packs(["res://content/base"])
	var prepared := ServerWorld.open(db, registry,
		{"seed": 7, "preset": "small", "climate": "temperate", "require_planned": true})
	if prepared == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	var villages := prepared.generator.settlements.villages(0, 0, 0)
	if villages.is_empty():
		prepared.close()
		printerr("fixture has no village")
		quit(1)
		return
	village = String(villages[0]["id"])
	prepared.close()
	app = App.new()
	app.configure({"renderer": "3d", "profile_dir": profile, "world": world_id, "time": "10", "weather": "clear"})
	root.add_child(app)
	g = app.game
	if g == null:
		app.free()
		quit(1)
		return
	g.set_process(false)
	view = g.view as WorldView3D
	world = g.game.world
	world.time_rate = 0
	g.game.server.wait_for_disk = true
	await pump(50)
	verify(g.client.state == "playing", "native client joins its actual saved planet")
	verify(RenderingServer.get_video_adapter_name().contains("RX 580"), "native Radeon RX 580")
	var plan := world.generator.settlements.plan_by_id(village)
	var geography := world.store.read_meta("world_plan")
	await move_to(plan["fire"] + Vector2i(2, 2))
	await settle()
	# A funded deterministic scenario, not an assertion that this happens
	# unaided in a random village. Keep all original production definitions.
	fund(10000)
	for home: Dictionary in plan["homes"]:
		var bed: Vector2i = home["bed"]
		world.chunk("surface", bed.x >> 5, bed.y >> 5)
	for c: Creature in world.creatures.creatures.values().duplicate():
		if String(world.content.get_def(c.kind).get("behavior", "")) == "predator":
			world.creatures.remove(c.id)
	for i in 8:
		day()
		if not (world.settlement_life.state(village)["project"] as Dictionary).is_empty():
			break
	var state := world.settlement_population.state(village)
	var project: Dictionary = state["project"]
	verify(not project.is_empty(), "funded prosperous village begins a real house")
	if project.is_empty():
		app.quit()
		app.free()
		quit(1)
		return
	var rect_data: Array = project["rect"]
	var rect := Rect2i(int(rect_data[0]), int(rect_data[1]), int(rect_data[2]), int(rect_data[3]))
	var door_data: Array = project["door"]
	var door := Vector2i(int(door_data[0]), int(door_data[1]))
	var outward: Vector2i = ContentRegistry.FACINGS[SettlementArchitecture.facing({"turns": project["turns"]})]
	await move_to(door + outward * 4)
	await house_frame(rect, "01-foundation")
	verify(int(project["stage"]) == 0, "foundation is the first paid stage")
	# Livestock can genuinely delay a wall; clear only this disposable
	# capture plot after recording the foundation, without changing AI rules.
	for animal: Creature in world.creatures.creatures.values().duplicate():
		if not animal.job.has("village") and rect.grow(3).has_point(animal.cell()):
			world.creatures.remove(animal.id)
			cleared_animals += 1
	day()
	await house_frame(rect, "02-walls")
	verify(int(project["stage"]) == 1, "the following day adds real walls")
	day()
	await house_frame(rect, "03-inhabited")
	verify((state["homes"] as Array).size() == 1, "the third stage completes a saved house")
	if (state["homes"] as Array).is_empty():
		app.quit()
		app.free()
		quit(1)
		return
	var record: Dictionary = state["homes"][0]
	var resident_id := String(record.get("resident", ""))
	verify(world.creatures.has(resident_id), "the finished house has a real worker")
	if not world.creatures.has(resident_id):
		app.quit()
		app.free()
		quit(1)
		return
	var person := world.creatures.get_creature(resident_id)
	var person_name := String(person.job["name"])
	var health := person.health
	var slot := str(int(person.job["home"]))
	fund(0)
	for i in 10:
		day()
		if (state["leaving"] as Dictionary).has(slot):
			break
	verify((state["leaving"] as Dictionary).has(slot), "sustained distress starts the new resident's departure")
	var start := person.pos
	var moved := false
	var journey_ticks := 0
	for i in 2400:
		if not world.creatures.has(resident_id):
			break
		await pump(1)
		moved = moved or person.pos != start
		journey_ticks += 1
	verify(moved and not world.creatures.has(resident_id), "native server AI walks the resident out through real doors")
	for i in SettlementPopulation.ABANDON_DAYS:
		day()
	var departure: Dictionary = (state["departed"] as Dictionary).get(slot, {})
	verify(not departure.is_empty() and not (departure.get("damage", []) as Array).is_empty(), "empty home loses actual roof cells")
	var damage: Array = (departure.get("damage", []) as Array).duplicate(true)
	await house_frame(rect, "04-abandoned")
	fund(500)
	for i in 8:
		day()
		if world.creatures.has(resident_id):
			break
	verify(world.creatures.has(resident_id), "recovery returns the same UUID after paid repairs")
	if world.creatures.has(resident_id):
		var returned := world.creatures.get_creature(resident_id)
		verify(String(returned.job["name"]) == person_name and returned.health == health, "name and health are preserved")
		await move_to(door + outward * 4)
		await house_frame(rect, "05-restored")
		verify(g.client.entities.has(resident_id), "the native client receives the returned worker")
	for row: Array in damage:
		verify(world._part_at(String(row[0]), int(row[1]), int(row[2]), "roof") == String(row[3]), "a paid roof patch is restored")
	verify(world.sync(), "the life-cycle operation reaches SQLite")
	var population := int(state["population"])
	var report := {"controlled_setup": true, "setup": "funded real stores, accelerated day boundaries, nearby predators and plot livestock removed; witness vitals replenished at day boundaries; original economic definitions and normal server AI", "seed": 7,
		"preset": "small", "climate": "temperate", "village": village, "building": record["building"], "rect": str(rect),
		"adapter": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"resident_uuid": resident_id, "resident_name": person_name, "health": health, "journey_ticks": journey_ticks,
		"cleared_plot_animals": cleared_animals, "roof_damage": damage, "history": history, "source_sha256": {}}
	for path: String in ["src/server/settlement_life.gd", "src/server/settlement_population.gd", "src/server/creature_sim.gd", "src/server/village_economy.gd", "src/server/server_world.gd", "src/experiment_3d/world_view_3d.gd", "tools/experiment_3d/check_settlement_life.gd"]:
		report["source_sha256"][path] = FileAccess.get_sha256("res://" + path)
	app.quit()
	app.free()
	await process_frame
	var reopened := ServerWorld.open(db, registry)
	verify(reopened != null, "captured world reopens normally")
	if reopened:
		verify(reopened.store.read_meta("world_plan") == geography, "life-cycle preserves the geographical snapshot")
		verify(int(reopened.settlement_population.state(village)["population"]) == population, "population survives reopening")
		verify(not reopened.store.entity(resident_id).is_empty(), "the same returned entity is durable")
		for row: Array in damage:
			verify(reopened._part_at(String(row[0]), int(row[1]), int(row[2]), "roof") == String(row[3]), "restored roof survives reopening")
		reopened.close()
	report["checks"] = checks
	report["failures"] = failures
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	Art.clear()
	quit(0 if failures.is_empty() else 1)
