extends SceneTree
## Native benchmark of authoritative requests on a repeatable saved landscape.
## /usr/bin/time -v godot --path . -s res://tools/experiment_3d/measure_world_edits.gd -- /tmp/nhn-edits-run
const SURFACE := "surface"
const TREE := Vector2i(31, 31)
const TREES := [TREE, Vector2i(32, 30), Vector2i(30, 32)]
const BOULDER := Vector2i(30, 30)
const ROCK := Vector2i(32, 33)
const WALL := Vector2i(33, 30)
const CAVE := "depth:-1"
const PASSAGE := Vector2i(32, 33)

class TimedView extends WorldView3D:
	var completed := 0
	var patched := 0
	var finish_us := 0
	func _finish_chunk() -> void:
		var started := Time.get_ticks_usec()
		var partial := _job.has("edits")
		super._finish_chunk()
		finish_us += Time.get_ticks_usec() - started
		if partial: patched += 1
		else: completed += 1

var game: LocalGame
var view: TimedView
var output: String
var frames: Array[float] = []
var mesh_us := 0
var last_frame := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	if OS.get_cmdline_user_args().size() != 1:
		quit(2)
		return
	output = OS.get_cmdline_user_args()[0]
	var db := output.path_join("world.db")
	if FileAccess.file_exists(db):
		printerr("Use a fresh output directory")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	Engine.max_fps = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.size = Vector2i(960, 540)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var profile := PlayerIdentity.load_or_create(output.path_join("player"))
	var person := PortableCharacter.create("Editor", "base:human_m")
	person.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	person.inventory.add("base:axe", 1)
	person.inventory.add("base:pickaxe", 1)
	person.inventory.add("base:plank", 20)
	var file := CharacterFile.export_signed(person, profile, content)
	var opened := Time.get_ticks_usec()
	game = LocalGame.start(db, content, profile, PlayerIdentity.load_or_create(output.path_join("server")), file, {"seed": 431})
	var open_ms := (Time.get_ticks_usec() - opened) / 1000.0
	if game == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	game.world.world_time = 12 * Daylight.HOUR_MS
	game.world.time_rate = 0
	game.world.spawn_position = Vector2i(31, 30) * Movement.UNIT + Vector2i(128, 128)
	game.server.unload_after_ticks = 100000
	game.server.view_chunks = 1
	game.world._last_chunk = null
	game.world._encoded.clear()
	fill()
	view = TimedView.new()
	view.setup(content, game.client)
	view.zoom = 16.875
	root.add_child(view)
	for i in 15: game.step()
	if game.client.state != "playing":
		printerr(game.client.state + ": " + game.client.reject_reason)
		game.close()
		view.free()
		quit(1)
		return
	game.client.geography = null  # fixed terrain for paired edit timings
	await move_to(Vector2i(31, 30))
	var first_mesh_ms := (Time.get_ticks_usec() - opened) / 1000.0
	var first_view := {"open_ms": open_ms, "wall_ms": first_mesh_ms, "chunks": view.completed,
		"view_cpu_ms": mesh_us / 1000.0, "finish_cpu_ms": view.finish_us / 1000.0}
	var edits := []
	for cell: Vector2i in TREES:
		await move_to(cell + Vector2i.UP)
		edits.append_array(await gather(cell, "cover", "base:axe", "base:stump"))
	await move_to(BOULDER + Vector2i.UP)
	edits.append_array(await gather(BOULDER, "cover", "base:pickaxe", ""))
	await move_to(ROCK + Vector2i.LEFT)
	edits.append_array(await gather(ROCK, "structure", "base:pickaxe", ""))
	await move_to(WALL + Vector2i.UP)
	edits.append(await measure({"type": "build", "location": SURFACE, "x": WALL.x, "y": WALL.y,
		"part": "base:wood_wall"}, "structure", "base:wood_wall"))
	edits.append(await measure({"type": "dismantle", "location": SURFACE, "x": WALL.x, "y": WALL.y}, "structure", ""))
	var actor: Dictionary = game.world.present[game.client.character_id]
	actor["location"] = CAVE
	game.world.relocated[game.client.character_id] = true
	await move_to(PASSAGE + Vector2i.LEFT, CAVE)
	edits.append_array(await gather(PASSAGE, "structure", "base:pickaxe", "", CAVE))
	check(not game.world.is_solid(CAVE, PASSAGE.x, PASSAGE.y), "server cave passage is walkable")
	var saved := game.world.sync()
	game.close()
	var store := WorldStore.new()
	if saved and store.open(db):
		var c := ChunkCodec.decode(store.get_chunk(SURFACE, 0, 0))
		saved = c != null and c.get_cell("cover", TREE.x, TREE.y) == "base:stump"
		var cave := ChunkCodec.decode(store.get_chunk(CAVE, 1, 1))
		saved = saved and cave != null and cave.get_cell("structure", PASSAGE.x & 31, PASSAGE.y & 31) == ""
		store.close()
	check(saved, "stump restored from SQLite")
	var report := {"engine": Engine.get_version_info()["string"],
		"adapter": RenderingServer.get_video_adapter_name(), "raster": str(view.viewport.size),
		"first_view": first_view, "edits": edits, "static_bytes": OS.get_static_memory_usage(), "failures": failures}
	FileAccess.open(output.path_join("result.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  ") + "\n")
	view.free()
	Art.clear()
	quit(0 if failures.is_empty() else 1)

func fill() -> void:
	for cy in range(-2, 5):
		for cx in range(-2, 5):
			var chunk := Chunk.new()
			for y in Chunk.SIZE:
				for x in Chunk.SIZE:
					var at := Vector2i(cx, cy) * Chunk.SIZE + Vector2i(x, y)
					chunk.set_cell("ground", x, y, "base:grass")
					if not Rect2i(25, 25, 14, 14).has_point(at) and posmod(hash(at), 5) == 0:
						chunk.set_cell("cover", x, y, "base:spruce" if posmod(hash(at), 2) == 0 else "base:oak")
			var key := ServerWorld.chunk_key(SURFACE, cx, cy)
			game.world._chunks[key] = chunk
			game.world._needed[key] = 0
	for cell: Vector2i in TREES:
		put(cell, "cover", "base:oak")
		props(cell, {"cover": {"work": 13 if cell == TREE else 14}})
	put(BOULDER, "cover", "base:boulder")
	props(BOULDER, {"cover": {"work": 3}})
	props(ROCK, {"work": 3})
	for y in range(33, 37):
		for x in range(32, 36):
			put(Vector2i(x, y), "structure", "base:rock")
	for cy in range(-2, 4):
		for cx in range(-2, 4):
			var cave := Chunk.new()
			for y in Chunk.SIZE:
				for x in Chunk.SIZE: cave.set_cell("ground", x, y, "base:cave_floor")
			var key := ServerWorld.chunk_key(CAVE, cx, cy)
			game.world._chunks[key] = cave
			game.world._needed[key] = 0
	var passage := game.world.chunk(CAVE, 1, 1)
	for y in range(1, 5):
		for x in range(4):
			passage.set_cell("structure", x, y, "base:rock")
	passage.set_props(PASSAGE.x & 31, PASSAGE.y & 31, {"work": 3})

func put(cell: Vector2i, layer: String, id: String) -> void:
	game.world.chunk(SURFACE, cell.x >> 5, cell.y >> 5).set_cell(layer, cell.x & 31, cell.y & 31, id)

func props(cell: Vector2i, value: Dictionary) -> void:
	game.world.chunk(SURFACE, cell.x >> 5, cell.y >> 5).set_props(cell.x & 31, cell.y & 31, value)

func frame(network: bool) -> void:
	await process_frame
	var now := Time.get_ticks_usec()
	var dt := (now - last_frame) / 1000000.0 if last_frame > 0 else 1.0 / 60
	last_frame = now
	frames.append(dt * 1000.0)
	if network: game.step()
	var began := Time.get_ticks_usec()
	view.update_view(1.0, dt)
	mesh_us += Time.get_ticks_usec() - began

func move_to(cell: Vector2i, location := SURFACE) -> void:
	game.world.move_character(game.client.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	for i in 900:
		await frame(i % 3 == 0)
		if i > 9 and game.client.location == location and view.pending_chunks() == 0 and view.has_geometry_at(location, cell): return
	check(false, "settled at " + str(cell))

func gather(cell: Vector2i, layer: String, tool: String, after: String, location := SURFACE) -> Array:
	game.client.hold(tool)
	for i in 18: game.step()
	var measurements := []
	for i in 12:
		var row := await measure({"type": "gather", "location": location, "x": cell.x, "y": cell.y,
			"layer": layer, "item": tool}, layer, after)
		measurements.append(row)
		if row["changed"] or not row["ok"]: break
		for j in 18: game.step()
	check(game.client.cell_at(location, cell, layer) == after, "gathered " + str(cell))
	return measurements

func measure(op: Dictionary, layer: String, after: String) -> Dictionary:
	var started := Time.get_ticks_usec()
	var complete_before := view.completed
	var patched_before := view.patched
	var view_before := mesh_us
	var finish_before := view.finish_us
	var writer_before := game.world.writer.busy_usec()
	var bytes_before: int = game.server.transport.bytes_sent[Transport.Channel.BULK]
	game.server.take_stats()
	frames.clear()
	var cell := Vector2i(op.x, op.y)
	var location := String(op.location)
	var key := game.client.chunk_key(location, cell.x >> 5, cell.y >> 5)
	var previous: Chunk = game.client.chunks.get(key)
	var old := game.client.cell_at(location, cell, layer)
	var request := game.client.request(op)
	var data_at := 0
	var ack_at := 0
	var visible_at := 0
	var end_at := 0
	var ok := false
	var picked: Dictionary = {}
	for i in 900:
		await frame(i % 3 == 0)
		var now := Time.get_ticks_usec()
		if data_at == 0 and game.client.chunks.get(key) != previous: data_at = now
		if ack_at == 0 and game.client.results.has(request):
			ack_at = now
			ok = game.client.results[request].get("ok", false)
			game.client.results.erase(request)
		if visible_at == 0 and game.client.cell_at(location, cell, layer) != old:
			picked = top_pick(cell)
			if picked.get("id", "") == after or (after == "" and picked.get("kind") == "ground"):
				visible_at = now
		if ack_at > 0 and view.pending_chunks() == 0 and (visible_at > 0 or game.client.cell_at(location, cell, layer) == old):
			end_at = now
			break
	check(ok, "acknowledged " + str(op))
	check(end_at > 0, "geometry and picking settled " + str(op) + " picked=" + str(picked))
	frames.sort()
	var row := {"op": op.type, "location": location, "layer": layer, "cell": str(cell), "old": old, "ok": ok, "changed": visible_at > 0,
		"ack_ms": elapsed(started, ack_at), "client_ms": elapsed(started, data_at),
		"visible_ms": elapsed(started, visible_at), "after_ack_ms": elapsed(ack_at, visible_at),
		"settled_ms": elapsed(started, end_at), "chunks_rebuilt": view.completed - complete_before, "chunks_patched": view.patched - patched_before,
		"writer_cpu_wall_ms": (game.world.writer.busy_usec() - writer_before) / 1000.0,
		"bulk_bytes": game.server.transport.bytes_sent[Transport.Channel.BULK] - bytes_before,
		"view_cpu_ms": (mesh_us - view_before) / 1000.0, "finish_cpu_ms": (view.finish_us - finish_before) / 1000.0,
		"p95_ms": frames[ceili(frames.size() * .95) - 1], "p99_ms": frames[ceili(frames.size() * .99) - 1],
		"max_ms": frames[-1], "frames": frames.size(), "fps": 1000.0 * frames.size() / frames.reduce(func(a, b): return a + b, 0.0),
		"server": game.server.take_stats()}
	print(JSON.stringify(row))
	return row

func top_pick(cell: Vector2i) -> Dictionary:
	var at := Vector2(cell) + Vector2.ONE * .5
	var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, 500, at.y), Vector3(at.x, -100, at.y))
	q.hit_back_faces = true
	var exclude: Array[RID] = []
	for actor: BillboardActor3D in view._actors.values():
		exclude.append(actor.body.get_rid())
	q.exclude = exclude
	var hit := view.space.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty(): return {}
	var targets: Array = hit.collider.get_meta("targets", [])
	var index := int(hit.get("face_index", -1))
	return targets[index] if index >= 0 and index < targets.size() else {}

func elapsed(started: int, ended: int) -> float:
	return (ended - started) / 1000.0 if ended > 0 and started > 0 else -1.0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		printerr(label)
