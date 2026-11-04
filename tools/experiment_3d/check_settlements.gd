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
		"requested_tradition": tradition, "requested_scale": scale, "architecture_version": Settlements.VERSION, "adapter": RenderingServer.get_video_adapter_name(), "houses": []}
	var made := 0
	for plan: Dictionary in villages:
		if made >= count: break
		await move_to((plan["fire"] as Vector2i) + Vector2i(2, 2))
		view.zoom = 50
		await settle()
		Input.warp_mouse(Vector2(20, root.size.y / 2))
		await pump(2)
		await capture("settlement-" + str(villages.find(plan)))
		for house: Dictionary in plan["homes"]:
			if made >= count: break
			var rect: Rect2i = house["rect"]
			await move_to((house["door"] as Vector2i) + Vector2i(0, 3))
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
				var stair := SettlementArchitecture._stairs(house["architecture"]) + rect.position
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
	for i in 360:
		await pump(1)
		if i >= 30 and view.pending_chunks() == 0 and not view._geometry.is_empty():
			stable += 1
			if stable >= 3:
				break
		else:
			stable = 0
	await physics_frame
	await physics_frame
	await pump(3)
