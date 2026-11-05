extends "res://tools/experiment_3d/check_runtime.gd"
## Native captures of generated villages and their actual houses. Disposable
## profile only; no prefab scene and no edits to the player's worlds.
## godot --path . -s res://tools/experiment_3d/check_settlements.gd -- --out=build/settlement-review --seed=431 --count=4

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/settlement-review")
	var seed_value := 431
	var climate := "temperate"
	var count := 4
	var tradition := ""
	var scale := ""
	var selected_village := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--seed="): seed_value = int(arg.trim_prefix("--seed="))
		if arg.begins_with("--climate="): climate = arg.trim_prefix("--climate=")
		if arg.begins_with("--count="): count = clampi(int(arg.trim_prefix("--count=")), 1, 12)
		if arg.begins_with("--tradition="): tradition = arg.trim_prefix("--tradition=")
		if arg.begins_with("--scale="): scale = arg.trim_prefix("--scale=")
		if arg.begins_with("--village="): selected_village = arg.trim_prefix("--village=")
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var world_id := library.create("Поселения", {"seed": str(seed_value), "starter_kit": true})
	var prepared := ServerWorld.open(library.db_path(world_id), ContentRegistry.load_packs(["res://content/base"]),
		{"seed": seed_value, "climate": climate, "require_planned": true})
	if prepared == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	prepared.close()
	app = App.new()
	app.configure({"renderer": "3d", "profile_dir": profile, "world": world_id, "time": "10", "weather": "clear"})
	root.add_child(app)
	g = app.game
	if g == null:
		printerr("capture could not open its disposable world")
		app.free()
		quit(1)
		return
	g.set_process(false)
	view = g.view as WorldView3D
	world = g.game.world
	verify(world.generator.geography is PlannedGeography and (world.generator.geography as PlannedGeography).plan.climate == climate, "the saved world uses the requested climate")
	world.time_rate = 0
	g.game.server.wait_for_disk = true
	await pump(50)
	var home := world.generator.settlements.home_plan()
	var villages := []
	if (tradition == "" or home["tradition"] == tradition) and (scale == "" or home["scale"] == scale):
		villages.append(home)
	if selected_village != "":
		villages.clear()
		var chosen := world.generator.settlements.plan_by_id(selected_village)
		if not chosen.is_empty():
			villages.append(chosen)
	if selected_village == "" and (villages.is_empty() or (home["homes"] as Array).size() < count):
		for plan: Dictionary in world.generator.settlements.plans_near(home["centre"], 700 if tradition != "" or scale != "" else 400):
			if plan["id"] != home["id"] and (tradition == "" or plan["tradition"] == tradition) and (scale == "" or plan["scale"] == scale):
				villages.append(plan)
	if villages.is_empty():
		printerr("No settlement of tradition: ", tradition)
		app.quit()
		app.free()
		quit(1)
		return
	view.yaw = .6
	view.tilt = 49
	var report := {"seed": seed_value, "climate": climate, "surface_version": SurfaceGenerator.VERSION,
		"requested_tradition": tradition, "requested_scale": scale, "architecture_version": Settlements.VERSION, "adapter": RenderingServer.get_video_adapter_name(), "settlements": [], "houses": []}
	report["source_sha256"] = {}
	for path: String in ["src/world/settlements.gd", "src/world/settlement_layout.gd", "src/world/settlement_architecture.gd", "src/world/surface_generator.gd", "src/experiment_3d/world_view_3d.gd", "src/experiment_3d/terrain_shape_3d.gd", "src/experiment_3d/building_modules_3d.gd", "src/server/creature_sim.gd", "src/sim/creature.gd", "tools/experiment_3d/check_settlements.gd", "src/building/build_rules.gd", "src/server/game_server.gd", "src/server/server_world.gd", "content/base/structures.json"]:
		report["source_sha256"][path] = FileAccess.get_sha256("res://" + path)
	var made := 0
	for plan: Dictionary in villages:
		if made >= count: break
		report["settlements"].append({"id": plan["id"], "layout": plan["layout"], "scale": plan["scale"], "tradition": plan["tradition"], "environment": plan["environment"]})
		await move_to(Vector2i((plan["bounds"] as Rect2i).get_center().x, (plan["centre"] as Vector2i).y + 1))
		view.zoom = 50
		await settle()
		Input.warp_mouse(Vector2(20, root.size.y / 2))
		await pump(2)
		frame_rect(plan["bounds"])
		await capture("settlement-" + str(villages.find(plan)))
		await move_to((plan["fire"] as Vector2i) + Vector2i(2, 2))
		await settle()
		frame_rect((plan["square"] as Rect2i).grow(9))
		await capture("public-ground-" + str(villages.find(plan)))
		if made == 0:
			report["caravan"] = await capture_caravan(plan)
		for house: Dictionary in plan["homes"]:
			if made >= count: break
			var rect: Rect2i = house["rect"]
			await move_to((house["door"] as Vector2i) + (ContentRegistry.FACINGS[SettlementArchitecture.facing(house["architecture"])] as Vector2i) * 3)
			view.zoom = maxf(16, maxf(rect.size.x, rect.size.y) * 2.0)
			await settle()
			Input.warp_mouse(Vector2(20, root.size.y / 2))
			await pump(2)
			# Centre the review camera on the whole building, while the actual
			# player remains outside so its cutaway does not hide the roof.
			view.yaw = .6
			view.tilt = 49
			view.zoom = maxf(18, maxf(rect.size.x, rect.size.y) * 2.0)
			view.eye.size = view.zoom
			var middle := Vector2(rect.get_center())
			var focus := Vector3(middle.x, view.elevation(middle) + 1.5, middle.y)
			var offset := Vector3(0, sin(deg_to_rad(view.tilt)), cos(deg_to_rad(view.tilt))).rotated(Vector3.UP, -view.yaw) * 65
			view.eye.position = focus + offset
			view.eye.look_at(focus, Vector3.UP)
			await capture("house-%02d" % made)
			if made == 0 and int(house["architecture"]["storeys"]) > 1:
				var stair := SettlementArchitecture.local_cell(house["architecture"], SettlementArchitecture._stairs(house["architecture"])) + rect.position
				await move_to(stair)
				var result := await request({"type": "climb", "location": "surface", "x": stair.x, "y": stair.y})
				verify(result.get("ok", false), "climb a generated house in the native client")
				await pump(20)
				await settle()
				await capture("upper-interior")
				result = await request({"type": "climb", "location": g.client.location, "x": stair.x, "y": stair.y, "dir": "down"})
				verify(result.get("ok", false), "return through the real stair opening")
			report["houses"].append({"village": plan["id"], "building": house["building_id"], "shape": house["shape"],
				"tradition": house["tradition"], "scale": plan["scale"], "storeys": house["architecture"]["storeys"], "seed": str(house["seed"]), "rect": str(rect), "wealth": house["wealth"]})
			print("SETTLEMENT_CAPTURE ", made, " ", house["shape"], " ", house["tradition"], " ", rect)
			made += 1
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if made == count and failures.is_empty() else 1)


func settle() -> void:
	# A real upper floor may occupy only one chunk. Waiting for nine chunks
	# there can never succeed. Require a stable completed render instead.
	var stable := 0
	var complete := false
	for i in 1800:
		await pump(1)
		# Captures can spend extra build time; gameplay keeps its normal frame budget.
		for pass_index in 4:
			view.update_view(1.0, 0.0)
		var streamed := true
		if g.client.location == "surface":
			var at := Movement.cell_of(g.client.position)
			for y in range((at.y >> 5) - 2, (at.y >> 5) + 3):
				for x in range((at.x >> 5) - 2, (at.x >> 5) + 3):
					streamed = streamed and g.client.chunks.has(ServerWorld.chunk_key("surface", x, y))
		if i >= 30 and streamed and view.pending_chunks() == 0 and not view._geometry.is_empty():
			stable += 1
			if stable >= 3:
				complete = true
				break
		else:
			stable = 0
	if not complete:
		var session := g.game.server._session_of(g.client.character_id)
		print("CAPTURE_UNSETTLED ", {"position": g.client.position, "received": g.client.chunks.keys(), "pending": view.pending_chunks(), "streamed_at": session.streamed_at, "unfinished": session.streaming_unfinished})
	verify(complete, "all expected chunks received and native geometry settled")
	await physics_frame
	await physics_frame
	await pump(3)


func frame_rect(rect: Rect2i) -> void:
	view.yaw = .6
	view.tilt = 49
	view.zoom = maxf(24, Vector2(rect.size).length() * .8)
	view.eye.size = view.zoom
	var middle := Vector2(rect.get_center())
	var focus := Vector3(middle.x, view.elevation(middle) + 1.5, middle.y)
	var offset := Vector3(0, sin(deg_to_rad(view.tilt)), cos(deg_to_rad(view.tilt))).rotated(Vector3.UP, -view.yaw) * 65
	view.eye.position = focus + offset
	view.eye.look_at(focus, Vector3.UP)


## A controlled native scene uses real server entities, a real route and the
## generated berth. Movement of two arrivals is covered by the integration test.
func capture_caravan(plan: Dictionary) -> Dictionary:
	var settlements := world.generator.settlements
	var district := settlements._district_of(0, plan["centre"])
	var route := {}
	for candidate: Dictionary in settlements.roads_of(0, district.x, district.y):
		if candidate["from"] == plan["id"] or candidate["to"] == plan["id"]:
			route = candidate
			break
	if route.is_empty():
		print("CAPTURE_NO_CARAVAN: this settlement has no connected route")
		return {"captured": false, "reason": "no connected route"}
	var berth: Vector2i = plan["parking"][0]
	await move_to(berth + Vector2i(7, 2))
	await settle()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world.world_seed, plan["id"], "review-caravan"])
	var trader := world.creatures._spawn("base:villager", "surface", berth, CreatureSim.villager_looks(rng), rng.randi())
	var source := String(route["to"]) if route["from"] == plan["id"] else String(route["from"])
	trader.route = {"road": route["key"], "i": 0, "step": 1 if route["to"] == plan["id"] else -1}
	trader.job = {"profession": "base:trader", "purse": 600, "name": "Обоз", "from": source, "toward": plan["id"]}
	trader.last_time = world.world_time
	world.creatures._make_caravan(trader, "cart")
	trader.job["caravan_heading"] = [0, -1]
	trader.job["horse_heading"] = [0, -1]
	world.creatures._move_caravan_horse(trader)
	world.creatures._caravan_arrive(trader)
	world.creatures._caravan_at_stop(trader, "arriving")
	verify(trader.job.get("caravan_state", "") == "trading", "a real server caravan fits and trades at the generated berth")
	await pump(35)
	await settle()
	frame_rect(Rect2i(berth - Vector2i(10, 10), Vector2i(25, 23)))
	await capture("caravan")
	return {"captured": true, "driver": trader.id, "route": route["id"], "from": source, "toward": plan["id"], "berth": str(berth), "controlled_setup": true}
