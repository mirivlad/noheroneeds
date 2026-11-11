extends "res://tools/experiment_3d/check_settlements.gd"
## Paired native interior captures. Reuse --profile between before and after;
## the generated building, character and camera poses stay the same.
var shots: Array = []
var extra_checks := false

func shot(name: String, rect: Rect2i, angle: float) -> void:
	view.yaw = angle
	view.tilt = 49
	view.zoom = maxf(20, maxf(rect.size.x, rect.size.y) * 1.35)
	await settle()
	view.yaw = angle
	view.tilt = 49
	view.zoom = maxf(20, maxf(rect.size.x, rect.size.y) * 1.35)
	var middle := Vector2(rect.get_center()) + Vector2.ONE * .5
	var focus := Vector3(middle.x, view.elevation(middle) + g.client.z * WorldView3D.STOREY + .8, middle.y)
	view.eye.size = view.zoom
	view.eye.position = focus + Vector3(0, sin(deg_to_rad(view.tilt)), cos(deg_to_rad(view.tilt))).rotated(Vector3.UP, -angle) * 65
	view.eye.look_at(focus, Vector3.UP)
	Input.warp_mouse(Vector2(15, 500))
	await capture(name)
	shots.append({"name": name, "yaw": angle, "tilt": view.tilt, "zoom": view.zoom,
		"player_cell": str(Movement.cell_of(g.client.position)), "level": g.client.z, "rect": str(rect)})

func run() -> void:
	output = ProjectSettings.globalize_path("res://build/interior-before")
	var profile := ProjectSettings.globalize_path("res://build/interior-fixture")
	for arg in OS.get_cmdline_user_args():
		if arg == "--extras": extra_checks = true
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=")
	DirAccess.make_dir_recursive_absolute(output)
	var library := WorldLibrary.new(profile.path_join("worlds"))
	var wid := "world"
	if not FileAccess.file_exists(library.db_path(wid)):
		wid = library.create("Срез интерьера", {"seed": "431", "starter_kit": true})
		var prepared := ServerWorld.open(library.db_path(wid), ContentRegistry.load_packs(["res://content/base"]),
			{"seed": 431, "preset": "single_continent", "climate": "temperate", "require_planned": true})
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
		printerr("cannot open the disposable interior world")
		app.free()
		quit(1)
		return
	g.set_process(false)
	g.set_process_unhandled_input(false)
	g.set_process_input(false)
	app.set_process_unhandled_input(false)
	root.gui_disable_input = true
	view = g.view as WorldView3D
	world = g.game.world
	world.time_rate = 0
	g.game.server.wait_for_disk = true
	await pump(50)
	verify(g.client.state == "playing", "real LocalGame client joins")
	var settlements := world.generator.settlements
	var district := settlements._district_of(0, settlements.home_plan()["centre"])
	var inns := settlements.inns.of_cluster(0, district.x, district.y).filter(func(p: Dictionary) -> bool: return p["site"] == "inn")
	verify(not inns.is_empty(), "fixture has a generated two-storey inn")
	if inns.is_empty():
		app.quit()
		app.free()
		quit(1)
		return
	var plan: Dictionary = inns[0]
	var rect: Rect2i = plan["rect"]
	var door: Vector2i = plan["door"]
	await move_to(door + Vector2i(0, -3))
	await settle()
	# Compare the fixed interior with the own character; moving NPCs would
	# add unrelated differences between the two renderer runs.
	for c: Creature in world.creatures.creatures.values().duplicate():
		world.creatures.remove(c.id)
	await pump(20)
	await shot("ground-se", rect, -.6)
	await shot("ground-sw", rect, .6)
	await shot("ground-nw", rect, .6 + PI / 2)
	var stairs := Vector2i.MAX
	for at: Vector2i in plan["cells"]:
		if plan["cells"][at].get("structure", "") == "base:wood_stairs": stairs = at
	await move_to(stairs + Vector2i.DOWN)
	var up := await request({"type": "climb", "location": "surface", "x": stairs.x, "y": stairs.y, "dir": "up"})
	verify(up.get("ok", false), "use the generated real stair")
	if up.get("ok", false):
		var bed: Dictionary = plan["beds"][0]
		await move_to(Vector2i(int(bed["x"]), int(bed["y"])) + Vector2i.DOWN)
		await shot("upper-se", rect, -.6)
		await shot("upper-sw", rect, .6)
		if extra_checks: check_surroundings(plan)
		if extra_checks: await check_occlusion(rect)
		await move_to(stairs + Vector2i.UP)
		var down := await request({"type": "climb", "location": g.client.location, "x": stairs.x, "y": stairs.y, "dir": "down"})
		verify(down.get("ok", false), "return through the same real stair")
	await move_to(door + Vector2i(0, 3))
	if extra_checks:
		await settle()
		verify(view._cut == Rect2i(), "leaving the building disables interior cutaway")
		check_street_exterior(plan)
		await shot("outside-restored", rect, -.6)
	var report := {"surface_generator_version": SurfaceGenerator.VERSION, "settlement_generator_version": Settlements.VERSION, "seed": 431, "preset": "single_continent", "climate": "temperate", "building": plan["id"],
		"template": plan["template"], "controlled_setup": "disposable saved world; NPCs removed for stable comparisons; normal client/server chunks and generated furnishings",
		"adapter": RenderingServer.get_video_adapter_name(), "shots": shots, "checks": checks, "failures": failures,
		"view_sha256": FileAccess.get_sha256("res://src/experiment_3d/world_view_3d.gd"),
		"harness_sha256": FileAccess.get_sha256("res://tools/experiment_3d/check_interior_cutaway.gd"),
		"scenario": get_script().resource_path, "scenario_sha256": FileAccess.get_sha256(get_script().resource_path),
		"server_sha256": FileAccess.get_sha256("res://src/server/game_server.gd")}
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	quit(0 if failures.is_empty() else 1)

## An actual retained partition, not a synthetic render-only wall.
func check_occlusion(rect: Rect2i) -> void:
	var original := Movement.cell_of(g.client.position)
	var found := false
	for cell: Vector2i in view._cut_cells:
		if content_role(cell) != "wall": continue
		var interior := true
		for d: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
			if not view._cut_cells.has(cell + d): interior = false
		if not interior: continue
		for d: Vector2i in [Vector2i.LEFT, Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN]:
			var own := cell + d
			if g.client.cell_at(g.client.location, own, "structure") != "": continue
			await move_to(own)
			view.yaw = atan2(float(d.x), float(-d.y))
			view.tilt = 25
			view.zoom = 16
			await pump(15)
			await physics_frame
			view._update_own_silhouette()
			if not is_instance_valid(view._own_silhouette) or not view._own_silhouette.visible: continue
			verify(not view._near_wall(cell), "the occluding internal partition keeps its full height")
			verify(view._own_silhouette.get_parent() == view._actors[g.client.character_id], "silhouette reuses only the own character's doll")
			var middle := Vector2(rect.get_center()) + Vector2.ONE * .5
			var focus := Vector3(middle.x, view.elevation(middle) + g.client.z * WorldView3D.STOREY + .8, middle.y)
			view.eye.size = 24.3
			view.eye.position = focus + Vector3(0, sin(deg_to_rad(view.tilt)), cos(deg_to_rad(view.tilt))).rotated(Vector3.UP, -view.yaw) * 65
			view.eye.look_at(focus, Vector3.UP)
			view._update_own_silhouette()
			await capture("upper-occluded")
			found = true
			break
		if found: break
	verify(found, "own character remains visible behind a real internal partition")
	await move_to(original)

func content_role(cell: Vector2i) -> String:
	return String(world.content.get_def(g.client.cell_at(g.client.location, cell, "structure")).get("role", ""))

func check_street_exterior(plan: Dictionary) -> void:
	var upper := world.levels.level(plan["id"], 1)
	var expected_roofs := 0
	var received_roofs := 0
	var expected_walls := 0
	var received_walls := 0
	for cell: Vector2i in plan["upper"]:
		var roof := world._part_at(upper, cell.x, cell.y, "roof")
		if roof != "":
			expected_roofs += 1
			if g.client.cell_at(upper, cell, "roof") == roof: received_roofs += 1
		var wall := world._part_at(upper, cell.x, cell.y, "structure")
		if world.content.get_def(wall).get("role") in ["wall", "window", "door"]:
			expected_walls += 1
			if g.client.cell_at(upper, cell, "structure") == wall: received_walls += 1
	verify(expected_roofs > 0 and received_roofs == expected_roofs, "the actual saved upper roof reaches the street client")
	verify(expected_walls > 0 and received_walls == expected_walls, "the actual saved upper walls reach the street client")
	var drawn_roofs := 0
	var drawn_walls := 0
	for key: String in view._geometry:
		if key.get_slice("|", 0) != upper: continue
		for node: Node in (view._geometry[key] as Node).get_children():
			if not node.has_meta("parts"): continue
			var parts: Array = node.get_meta("parts")
			for i in parts.size():
				if (node as MultiMeshInstance3D).multimesh.get_instance_transform(i).basis.determinant() == 0: continue
				if parts[i][1] == "cover": drawn_roofs += 1
				if parts[i][1] == "wall": drawn_walls += 1
	verify(drawn_roofs == expected_roofs, "all upper roof modules are rendered outdoors")
	verify(drawn_walls == expected_walls, "all upper wall modules are rendered outdoors")

func check_surroundings(plan: Dictionary) -> void:
	var street := false
	for key: String in view._geometry:
		if key.get_slice("|", 0) == "surface" and (view._geometry[key] as Node3D).visible: street = true
	verify(street, "street geometry remains visible from inside an upper floor")
	var door: Vector2i = plan["door"]
	verify(not view._part_hidden(door + Vector2i(0, 3), "object", "surface"), "street scenery is retained outside the building contour")
	verify(not view._part_hidden(door, "wall", "surface"), "lower exterior walls keep their full height")
	verify(not view._part_hidden(door + Vector2i.UP, "cover", "surface"), "lower ceiling stays under the current floor")
	var other_roof := false
	for key: String in g.client.chunks:
		if key.get_slice("|", 0) != "surface": continue
		var origin := Vector2i(int(key.get_slice("|", 1)), int(key.get_slice("|", 2))) * Chunk.SIZE
		var c: Chunk = g.client.chunks[key]
		for y in Chunk.SIZE:
			for x in Chunk.SIZE:
				var cell := origin + Vector2i(x, y)
				if not (plan["rect"] as Rect2i).has_point(cell) and c.get_cell("roof", x, y) != "" and not view._part_hidden(cell, "cover", "surface"):
					other_roof = true
	verify(other_roof, "neighbouring buildings retain their actual roofs")
