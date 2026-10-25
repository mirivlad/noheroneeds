extends SceneTree
## Real window + GPU + LocalGame/GameClient integration, isolated disposable world.
## godot --path . -s res://tools/experiment_3d/check_runtime.gd -- --out=/tmp/nhn-3d-runtime
var app: App
var g: GameScreen
var view: WorldView3D
var world: ServerWorld
var output := ""
var checks := 0
var failures: Array[String] = []
var dug := Vector2i.ZERO
var last_frame_us := 0

func _initialize() -> void:
	call_deferred("run")

func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
	print(("PASS " if ok else "FAIL ") + label)

func pump(n: int) -> void:
	for i in n:
		g.game.step()
		var now := Time.get_ticks_usec()
		view.update_view(1.0, (now - last_frame_us) / 1000000.0 if last_frame_us > 0 else 1.0 / 60)
		last_frame_us = now
		await process_frame

func request(op: Dictionary) -> Dictionary:
	var rid := g.client.request(op)
	for i in 120:
		await pump(1)
		if g.client.results.has(rid):
			var result: Dictionary = g.client.results[rid]
			g.client.results.erase(rid)
			return result
	return {"ok": false, "reason": "timeout"}

func move_to(cell: Vector2i) -> void:
	world.move_character(g.client.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	await pump(8)

func settle() -> void:
	for i in 900:
		await pump(1)
		if view.pending_chunks() == 0 and view._geometry.size() >= 9:
			break
	await physics_frame
	await physics_frame
	await pump(3)

func capture(name: String) -> void:
	g._update_hud()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func hit_at(cell: Vector2i, height := .4) -> Dictionary:
	var p := Vector2(cell) + Vector2.ONE * .5
	var point := Vector3(p.x, view.elevation(p) + (0 if g.client.z < 0 else g.client.z * 2) + height, p.y)
	var screen := view.eye.unproject_position(point)
	var world_point := view.screen_point(screen)
	g.mouse_at = world_point
	g._update_target()
	var result := g.target
	return result

func run() -> void:
	output = ProjectSettings.globalize_path("user://experiment-3d-validation")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-" + str(Time.get_unix_time_from_system()).replace(".", "-"))
	var lib := WorldLibrary.new(profile.path_join("worlds"))
	var world_id := lib.create("Проверка 3D", {"seed": "431", "starter_kit": true})
	var prepared := ServerWorld.open(lib.db_path(world_id), ContentRegistry.load_packs(["res://content/base"]), {"seed": 431})
	prepared.close()
	app = App.new()
	app.configure({"renderer": "3d", "profile_dir": profile, "world": world_id, "time": "10"})
	root.add_child(app)
	g = app.game
	g.set_process(false)
	view = g.view as WorldView3D
	world = g.game.world
	g.game.server.wait_for_disk = true
	await pump(50)
	verify(g.client.state == "playing", "real LocalGame server joined")
	verify(RenderingServer.get_video_adapter_name().contains("RX 580"), "native Radeon RX 580 device")
	verify(RenderingServer.get_current_rendering_method() == "gl_compatibility", "existing GL Compatibility renderer")
	var start := g.client.position
	g.client.move = Vector2i.RIGHT
	await pump(5)
	g.client.move = Vector2i.ZERO
	verify(g.client.position != start, "walking through existing movement prediction and server")
	var home := world.generator.settlements.home_plan()
	var fire: Vector2i = home["fire"]
	await move_to(fire + Vector2i(2, 0))
	view.yaw = .6
	view.tilt = 49
	await settle()
	verify(view._geometry.size() >= 9, "real client chunks built and retained")
	verify(view._actors.has(g.client.character_id), "own LPC actor in 3D")
	await capture("village")
	# Drop/pickup travel through GameClient and the authoritative server.
	var count := int(g.client.inventory().get("base:stone", 0))
	var r := await request({"type": "drop", "item": "base:stone", "count": 1})
	verify(r.get("ok", false), "drop item request accepted")
	var item := ""
	for id: String in g.client.entities:
		if g.client.entities[id].get("kind") == "item" and g.client.entities[id].get("item") == "base:stone":
			item = id
			break
	verify(item != "" and view._actors.has(item), "dropped item has a Sprite3D")
	r = await request({"type": "pickup", "entity": item})
	verify(r.get("ok", false) and int(g.client.inventory().get("base:stone", 0)) == count, "pickup returns actual inventory")
	# Pick and talk to an actual generated dweller; no synthetic NPC.
	var npc := ""
	for id: String in g.client.entities:
		if String(g.client.entities[id].get("profession", "")) != "":
			npc = id
			break
	verify(npc != "", "generated village dweller received")
	if npc != "":
		var e: Dictionary = g.client.entities[npc]
		var at := Movement.cell_of(Vector2i(int(e["x"]), int(e["y"])))
		await move_to(at + Vector2i.DOWN)
		r = await request({"type": "talk", "creature": npc})
		verify(r.get("ok", false), "existing talk request accepted by generated NPC")
	# Natural tree: find one with an accessible neighbor.
	var tree := find_part("surface", fire, "cover", "chopping")
	verify(not tree.is_empty(), "natural tree found in original chunks")
	if not tree.is_empty():
		await move_to(tree[1])
		await settle()
		g.hotbar.put(0, "base:axe", -1)
		g._choose_slot(0)
		g._update_hud()
		await pump(3)
		var at: Vector2i = tree[0]
		var picked := hit_at(at, 1)
		verify(picked.get("cell") == at and picked.get("layer") == "cover", "3D ray picks natural tree at rotated camera")
		verify(Actions.primary(g.actions).get("id") == "gather", "existing mouse action resolves 3D tree")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		g._mouse(click)
		click.pressed = false
		g._mouse(click)
		await pump(20)
		for i in 20:
			r = await request({"type": "gather", "location": "surface", "x": at.x, "y": at.y, "layer": "cover", "item": "base:axe"})
			await pump(20)
			if world._part_at("surface", at.x, at.y, "cover") == "base:stump":
				break
		verify(world._part_at("surface", at.x, at.y, "cover") == "base:stump", "tree felled by normal server work rules")
		await settle()
		verify(view._cell_layer(at, "cover") == "base:stump", "changed client chunk replaces 3D tree with stump")
		await capture("forest")
	# Build and use a door on actual free land next to the player.
	var me := Movement.cell_of(g.client.position)
	var spot := me
	for offset: Vector2i in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
		if not world.is_solid("surface", me.x + offset.x, me.y + offset.y):
			spot = me + offset
			break
	g._blueprint = "base:wood_door"
	g.mouse_at = (Vector2(spot) + Vector2.ONE * .5) * WorldView.CELL
	verify(g._build_cell() == spot, "3D blueprint uses picked cell without 2D roof lift")
	var build_click := InputEventMouseButton.new()
	build_click.button_index = MOUSE_BUTTON_LEFT
	build_click.pressed = true
	g._mouse(build_click)
	build_click.pressed = false
	g._mouse(build_click)
	g._blueprint = ""
	await pump(8)
	verify(world._part_at("surface", spot.x, spot.y, "structure") == "base:wood_door", "existing blueprint mouse clicks build normal door")
	await settle()
	var door_pick := hit_at(spot, .9)
	verify(door_pick.get("cell") == spot and door_pick.get("id") == "base:wood_door", "3D ray picks built door")
	r = await request({"type": "use", "location": "surface", "x": spot.x, "y": spot.y})
	verify(r.get("ok", false), "existing door use request accepted")
	await settle()
	verify(view.props_at(spot).get("open", false), "3D door rebuild sees open state")
	# Surface transition is the real generator's persisted spawn cave mouth.
	var way := world._spawn_way()
	await move_to(way)
	r = await request({"type": "climb", "location": "surface", "x": way.x, "y": way.y})
	verify(r.get("ok", false) and g.client.location == "depth:-1", "existing natural cave transition to depth -1")
	view.zoom = 18
	view.tilt = 65
	await settle()
	await capture("cave-before")
	var rock := find_part("depth:-1", way, "structure", "mining")
	verify(not rock.is_empty(), "natural mineable cave wall found")
	if not rock.is_empty():
		dug = rock[0]
		await move_to(rock[1])
		g.hotbar.put(0, "base:pickaxe", -1)
		g._choose_slot(0)
		g._update_hud()
		await pump(3)
		var picked := hit_at(dug, 1.0)
		verify(picked.get("cell") == dug and picked.get("kind") == "part", "3D ray picks actual underground rock")
		var old_part := view._cell_layer(dug, "structure")
		r = await request({"type": "gather", "location": "depth:-1", "x": dug.x, "y": dug.y, "item": "base:pickaxe"})
		verify(r.get("ok", false), "normal pickaxe request mines natural wall: " + str(r))
		await settle()
		verify(view._cell_layer(dug, "structure") == "", "3D geometry consumes mined cell update")
		var remains := false
		var key := ServerWorld.chunk_key("depth:-1", floori(dug.x / 32.0), floori(dug.y / 32.0))
		var root_chunk: Node = view._geometry[key]
		for node: Node in root_chunk.get_children():
			if node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh.mesh == view.models.mesh_for(old_part, g.content.get_def(old_part)):
				var mm := (node as MultiMeshInstance3D).multimesh
				for i in mm.instance_count:
					var at := mm.get_instance_transform(i).origin
					remains = remains or Vector2(at.x, at.z).distance_to(Vector2(dug) + Vector2.ONE * .5) < .01
		verify(not remains, "mined wall removed from rendered object instances")
		await capture("cave-after")
	# An ordinary build request makes a lower working and return ladder.
	await move_to(way)
	var shaft := way + Vector2i.ONE
	r = await request({"type": "build", "location": "depth:-1", "x": shaft.x, "y": shaft.y, "part": "base:mine_shaft"})
	verify(r.get("ok", false), "existing mine shaft construction on depth -1")
	await move_to(shaft)
	r = await request({"type": "climb", "location": "depth:-1", "x": shaft.x, "y": shaft.y})
	verify(r.get("ok", false) and g.client.location == "depth:-2", "existing shaft transition to depth -2")
	await settle()
	await capture("depth-2")
	r = await request({"type": "climb", "location": "depth:-2", "x": shaft.x, "y": shaft.y})
	verify(r.get("ok", false) and g.client.location == "depth:-1", "return through existing ladder")
	await move_to(way)
	r = await request({"type": "climb", "location": "depth:-1", "x": way.x, "y": way.y})
	verify(r.get("ok", false) and g.client.location == "surface", "return to surface")
	var db := app.worlds.db_path(world_id)
	app.quit()
	app.free()
	await process_frame
	var reopened := ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	verify(reopened._part_at("depth:-1", dug.x, dug.y, "structure") == "", "mined wall stays absent after save and reopening")
	reopened.close()
	var report := {"checks": checks, "failures": failures, "adapter": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method()}
	FileAccess.open(output.path_join("runtime.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("EXPERIMENT_3D_RUNTIME " + JSON.stringify(report))
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func find_part(location: String, from: Vector2i, layer: String, tool: String) -> Array:
	for radius in range(1, 40):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var cell := from + Vector2i(dx, dy)
				var part := world._part_at(location, cell.x, cell.y, layer)
				if String(g.content.get_def(part).get("gather", {}).get("tool", "")) != tool:
					continue
				for d: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN]:
					if not world.is_solid(location, cell.x + d.x, cell.y + d.y):
						return [cell, cell + d]
	return []
