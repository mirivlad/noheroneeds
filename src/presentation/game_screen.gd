class_name GameScreen
extends Node2D
## The game being played: the world, the HUD, the player's controls. Started
## by App with how to play (cfg):
##   {"mode": "local", "world_path", "rules"}  single-player: a local server in
##       this process (LocalGame);
##   {"mode": "host", "world_path", "rules", "port", "max_players"}  a server
##       in this process that others join (HostedGame);
##   {"mode": "connect", "address", "port"}  a dedicated or hosted server.
## Esc asks App for the menu; a lost connection is reported to it.
## Dev options (App passes them through): --walk=DX,DY holds a direction;
## --demo builds a little house through ordinary requests on arrival
## (--demo=outside puts the player at the porch, --demo=upstairs goes up the
## stairs; the player starts inside); --screenshot=PATH --frames=N;
## --time=HOUR sets a local world's clock.
##
## Controls (temporary): WASD/arrows walk, with Ctrl run; 1-3 choose a part,
## R turns it (stairs: up north, east or west); left click
## builds, right click takes down; E picks up what lies near or opens and
## closes a door next to you; G drops one of the chosen material (Tab);
## F goes up the stairs you stand on (or down, if there is no way up),
## Shift+F goes down; Esc opens the menu.

signal menu_requested
## The connection is gone or the server refused us (reason for people).
signal failed(reason: String)
signal screenshot_taken

const PARTS := ["base:wood_wall", "base:stone_wall", "base:wood_door", "base:wood_ceiling",
	"base:thatch_roof", "base:wood_stairs", "base:wood_column", "base:torch"]
const MATERIALS := ["base:plank", "base:stone", "base:log"]

var content: ContentRegistry
var game: LocalGame
var hosted: HostedGame
var client: GameClient
var settings: GameSettings
var audio := AudioDirector.new()
## Danger music (combat, step 10): set by what threatens the player.
var danger := false
## Request id -> sound event to play when it succeeds (own pickups, drops).
var _sound_on_ok := {}
## The menu is open: no controls, and a single-player world stands still.
var paused := false
var _reported := false
var view := WorldView.new()
var camera := Camera2D.new()
var hud := Label.new()
var status := Label.new()
## The second HUD line: hosting address, frame rate, control hints.
var _info := Label.new()
var _accum := 0.0
var _part := 0
## The facing the chosen part will be built in (ADR-0013), turned with R.
var _facing := 0
var _material := 0
var _note := ""
var _opts := {}
var _frames := 0
var _demo_done := false
## The chosen part under the mouse, as it would stand: green if in reach.
var _ghost := Sprite2D.new()
var _slots: Array[Panel] = []

## What the server's refusals mean, for people.
const REASONS := {
	"occupied": "место занято", "blocked": "мешает вода или дерево", "someone_there": "там кто-то стоит",
	"materials": "не хватает материалов", "too_far": "слишком далеко", "no_floor": "здесь нет пола",
	"too_high": "выше строить нельзя (настройка сервера)", "occupied_above": "сверху что-то стоит — сначала уберите",
	"no_opening_above": "лестнице нужно перекрытие над ней или там, куда она ведёт", "stairs_below": "сначала уберите лестницу",
	"not_owner": "это не ваше", "empty": "здесь нечего разбирать", "no_stairs": "здесь нет лестницы",
	"unknown_part": "неизвестная деталь", "nothing_to_use": "здесь нечего открыть", "gone": "уже подобрали",
	"not_enough": "не хватает", "no_such_place": "здесь строить нельзя",
}


## Sets the game up; "" on success, else what went wrong (for people).
func start(cfg: Dictionary, registry: ContentRegistry, me: PlayerIdentity, server_identity: PlayerIdentity,
		character_file: PackedByteArray, player_settings: GameSettings, dev := {}) -> String:
	content = registry
	settings = player_settings
	_opts = dev
	match String(cfg.get("mode", "local")):
		"connect":
			var t := ENetTransport.new()
			if t.start_client(String(cfg["address"]), int(cfg["port"])) != OK:
				return "не удалось начать подключение к %s:%d" % [cfg["address"], cfg["port"]]
			client = GameClient.new(t, me, character_file, content)
		"host":
			hosted = HostedGame.start(String(cfg["world_path"]), content, me, server_identity, character_file,
				int(cfg["port"]), int(cfg.get("max_players", 8)), {"seed": WorldLibrary.seed_of(cfg.get("rules", {}))})
			if not hosted.ok():
				return hosted.error
			WorldLibrary.apply_rules(cfg.get("rules", {}), hosted.world)
			client = hosted.client
		_:
			DirAccess.make_dir_recursive_absolute(String(cfg["world_path"]).get_base_dir())
			game = LocalGame.start(String(cfg["world_path"]), content, me, server_identity, character_file,
				{"seed": WorldLibrary.seed_of(cfg.get("rules", {}))})
			if game == null:
				return "не удалось открыть мир"
			WorldLibrary.apply_rules(cfg.get("rules", {}), game.world)
			if _opts.has("time"):  # dev only: --time=HOUR sets the world's clock
				var day_start := game.world.world_time - game.world.world_time % Daylight.DAY_MS
				game.world.world_time = day_start + int(float(_opts["time"]) * Daylight.HOUR_MS)
			client = game.client
	view.setup(content, client)
	add_child(view)
	audio.setup(content, client, view)
	add_child(audio)
	view.on_step = func(at: Vector2) -> void: audio.step_at(client.location, at)
	camera.position_smoothing_enabled = false
	add_child(camera)
	var layer := CanvasLayer.new()
	add_child(layer)
	for l: Label in [hud, status, _info]:
		l.add_theme_font_override("font", Art.font())
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", Art.TEXT)
		l.add_theme_color_override("font_outline_color", Art.INK)
		l.add_theme_constant_override("outline_size", 4)
		layer.add_child(l)
	hud.position = Vector2(6, 2)
	status.position = Vector2(6, 252)
	_info.position = Vector2(6, 16)
	_info.add_theme_color_override("font_color", Art.TEXT_DIM)
	_ghost.centered = false
	_ghost.z_index = 20
	_ghost.visible = false
	add_child(_ghost)
	_build_hotbar(layer)
	apply_settings()
	return ""


func _notification(what: int) -> void:
	# Parts made up front but never added (a start that failed) are freed too.
	if what == NOTIFICATION_PREDELETE:
		for n: Node in [view, camera, hud, status, _info, _ghost, audio]:
			if is_instance_valid(n) and n.get_parent() == null:
				n.free()


## The music this moment calls for (App's MusicDirector follows it):
## danger, then home (under a roof, on a building's level), then night
## (outdoors, by the world's time), else
## explore — fields and woods are one mood, so walking through glades and
## trees does not keep changing the melody.
func music_mood() -> String:
	if danger:
		return "danger"
	if client == null or not client.has_position:
		return "explore"
	if audio.indoors or client.z > 0:
		return "home"
	if client.has_time and Daylight.is_night(client.world_time):
		return "night"  # the world's own night, not the player's clock
	return "explore"


## The view and HUD parts of the player's settings.
func apply_settings() -> void:
	var z := float(settings.get_value("view_zoom"))
	camera.zoom = Vector2(z, z)


## Ends the game: the world is saved and closed, connections dropped.
func close() -> void:
	if game:
		game.close()
		game = null
	elif hosted:
		hosted.close()
		hosted = null
	elif client:
		client.transport.close()
	client = null


func _process(delta: float) -> void:
	if client == null:
		return
	client.move = _direction() if not paused else Vector2i.ZERO
	client.run = not paused and (_opts.has("run") or Input.is_physical_key_pressed(KEY_CTRL))
	# A single-player world stands still while the menu is open; a server
	# others play on cannot.
	_accum += 0.0 if paused and game else delta
	var tick := 1.0 / Movement.TICK_RATE
	var steps := 0
	while _accum >= tick and steps < 4:
		if game:
			game.step()
		elif hosted:
			hosted.step()
		else:
			client.step()
		_accum -= tick
		steps += 1
	if _accum > tick * 4:
		_accum = 0.0
	if _opts.has("demo") and not _demo_done and client.state == "playing" and client.has_position:
		_demo_done = true
		if game:
			game.world.grant(client.character_id, "base:plank", 60)  # dev only: enough for the demo
		for x in range(-3, 4):
			for y in [-4, 2]:
				var part := "base:wood_door" if x == 0 and y == 2 else ("base:stone_wall" if y == -4 else "base:wood_wall")
				client.request({"type": "build", "location": client.location, "x": x, "y": y, "part": part})
		for y in range(-3, 2):
			for x in [-3, 3]:
				client.request({"type": "build", "location": client.location, "x": x, "y": y, "part": "base:wood_wall"})
		# A ceiling over the room, thatch over its back row, stairs to the floor above.
		for y in range(-3, 2):
			for x in range(-2, 3):
				var part := "base:thatch_roof" if y == -3 else "base:wood_ceiling"
				client.request({"type": "build", "location": client.location, "x": x, "y": y, "part": part})
		client.request({"type": "build", "location": client.location, "x": 1, "y": 0, "part": "base:wood_stairs"})
		# Beside the house: a wall with a walk on top, stairs up to it from
		# both ends, turned east and west (ADR-0013).
		for x in range(-1, 2):
			client.request({"type": "build", "location": client.location, "x": x, "y": 4, "part": "base:wood_wall"})
			client.request({"type": "build", "location": client.location, "x": x, "y": 4, "part": "base:wood_ceiling"})
		client.request({"type": "build", "location": client.location, "x": -2, "y": 4, "part": "base:wood_stairs", "facing": "e"})
		client.request({"type": "build", "location": client.location, "x": 2, "y": 4, "part": "base:wood_stairs", "facing": "w"})
		client.request({"type": "drop", "item": "base:stone", "count": 2})
		for x in [-2, 2]:  # torches by the door (ADR-0014)
			client.request({"type": "build", "location": client.location, "x": x, "y": 3, "part": "base:torch"})
	if _opts.get("demo") == "" and _frames == 30:
		client.request({"type": "use", "location": client.location, "x": 0, "y": 2})
	if _opts.get("demo") == "outside" and _frames == 40 and game:
		game.world.move_character(client.character_id, Vector2i(128, 7 * 256 + 128))  # dev only: before the house
	if _opts.get("demo") == "behind" and _frames == 40 and game:
		game.world.move_character(client.character_id, Vector2i(128, -5 * 256 + 200))  # dev only: behind the back wall
	if _opts.get("demo") == "upstairs" and _frames == 40:
		client.request({"type": "climb", "location": client.location, "x": 1, "y": 0})
	if _opts.get("demo") == "upstairs" and _frames == 60 and client.z == 1:
		# Part of the first level roofed over: floor and ceiling side by side.
		for y in range(-3, 0):
			for x in range(-2, 1):
				client.request({"type": "build", "location": client.location, "x": x, "y": y, "part": "base:wood_ceiling"})
	view.update_view(_accum / tick, delta)
	if client.has_position:
		camera.position = view.own_pixel_position(_accum / tick).round()
	_update_hud()
	_update_ghost()
	_frames += 1
	if not _reported and client.state in ["disconnected", "rejected"]:
		_reported = true
		failed.emit("сервер отказал: " + client.reject_reason if client.state == "rejected" else "связь с сервером потеряна")
	if _opts.has("screenshot") and _frames >= int(_opts.get("frames", "120")):
		get_viewport().get_texture().get_image().save_png(String(_opts["screenshot"]))
		screenshot_taken.emit()


func _unhandled_input(event: InputEvent) -> void:
	if paused or client == null:
		return
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		menu_requested.emit()
		return
	if event is InputEventKey and event.pressed:
		var k: int = (event as InputEventKey).keycode
		if k >= KEY_1 and k < KEY_1 + PARTS.size():
			_part = k - KEY_1
			_facing = 0
		elif k == KEY_R:
			var turns := _turns()
			if not turns.is_empty():
				_facing = (_facing + 1) % turns.size()
		elif k == KEY_TAB:
			_material = (_material + 1) % MATERIALS.size()
		elif k == KEY_G and client.state == "playing":
			_sound_on_ok[client.request({"type": "drop", "item": MATERIALS[_material], "count": 1})] = "drop"
		elif k == KEY_E and client.state == "playing":
			_use_nearest()
		elif k == KEY_F and client.state == "playing":
			_climb_nearest("down" if (event as InputEventKey).shift_pressed else "up")
	elif event is InputEventMouseButton and event.pressed and client.state == "playing":
		var op := {"location": client.location}
		var cell: Vector2i
		if event.button_index == MOUSE_BUTTON_LEFT:
			cell = _build_cell()
			op["type"] = "build"
			op["part"] = PARTS[_part]
			if not _turns().is_empty():
				op["facing"] = _turns()[_facing % _turns().size()]
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			cell = view.pick(get_global_mouse_position())  # what the mouse points at
			op["type"] = "dismantle"
		else:
			return
		op["x"] = cell.x
		op["y"] = cell.y
		client.request(op)


## E: the nearest thing on the ground within reach, else a door next to us.
func _use_nearest() -> void:
	var best := ""
	var best_d := float(ServerWorld.PICKUP_REACH)
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") == "item":
			var dist := Vector2(client.position).distance_to(Vector2(int(e["x"]), int(e["y"])))
			if dist <= best_d:
				best = id
				best_d = dist
	if best != "":
		_sound_on_ok[client.request({"type": "pickup", "entity": best})] = "pickup"
		return
	var me := Movement.cell_of(client.position)
	for dy in [0, -1, 1]:
		for dx in [0, 1, -1]:
			var cell: Vector2i = me + Vector2i(dx, dy)
			var cx := floori(cell.x / 32.0)
			var cy := floori(cell.y / 32.0)
			var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, cx, cy))
			if c and content.get_def(c.get_cell("structure", cell.x - cx * 32, cell.y - cy * 32)).get("openable", false):
				client.request({"type": "use", "location": client.location, "x": cell.x, "y": cell.y})
				return


## F: the stairs nearest to the player, if any in reach: up (Shift+F: down)
## when that way is there, else the other way. Stairs above stairs lead both
## ways from one cell, so the choice is the player's.
func _climb_nearest(prefer: String) -> void:
	var me := Movement.cell_of(client.position)
	for d: Vector2i in [Vector2i.ZERO, Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		var ways := _ways_at(me + d)
		if ways.is_empty():
			continue
		var dir: String = prefer if ways.has(prefer) else ways[0]
		client.request({"type": "climb", "location": client.location, "x": me.x + d.x, "y": me.y + d.y, "dir": dir})
		return
	_note = "рядом нет лестницы"


## Which ways lead on from a cell: "up" (stairs here), "down" (stairs below).
func _ways_at(cell: Vector2i) -> Array:
	var cx := floori(cell.x / float(Chunk.SIZE))
	var cy := floori(cell.y / float(Chunk.SIZE))
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, cx, cy))
	if c == null:
		return []
	var lx := cell.x - cx * Chunk.SIZE
	var ly := cell.y - cy * Chunk.SIZE
	var ways := []
	var part := c.get_cell("structure", lx, ly)
	if part != "" and content.get_def(part).get("role") == "stairs":
		ways.append("up")
	if c.get_props(lx, ly).get("stairs_down", false):
		ways.append("down")
	return ways


## The facings the chosen part may be built in ([] if it does not turn).
func _turns() -> Array:
	return content.get_def(PARTS[_part]).get("rotations", [])


## Where a click would build: the cell under the mouse, or for ceilings and
## roofs the cell whose cover would be drawn there (covers sit a cell higher).
func _build_cell() -> Vector2i:
	var m := get_global_mouse_position()
	var cell := Vector2i(floori(m.x / WorldView.CELL), floori(m.y / WorldView.CELL))
	if Terrain.layer_for_role(String(content.get_def(PARTS[_part]).get("role", ""))) != "structure":
		cell.y += 1
	return cell


func _update_ghost() -> void:
	var v := content.visual_of(PARTS[_part])
	if client.state != "playing" or v.is_empty() or _opts.has("screenshot"):
		_ghost.visible = false
		return
	var cell := _build_cell()
	_ghost.texture = view.texture(v["atlas_path"])
	_ghost.region_enabled = true
	var facing := String(_turns()[_facing % _turns().size()]) if not _turns().is_empty() else ""
	var turned: String = v.get("mirror", {}).get(facing, facing)
	var r: Array = v.get("rotations", {}).get(turned, v["rect"])
	_ghost.region_rect = Rect2(r[0], r[1], r[2], r[3])
	_ghost.flip_h = v.get("mirror", {}).has(facing)
	if v["mode"] == "cover":
		_ghost.position = Vector2(cell.x * WorldView.CELL, cell.y * WorldView.CELL - WorldView.COVER_LIFT)
	else:
		_ghost.position = Vector2(cell.x * WorldView.CELL, (cell.y + 1) * WorldView.CELL) - Vector2(v["origin"][0], v["origin"][1])
	var centre := Vector2(cell.x * 256 + 128, cell.y * 256 + 128)
	var near := Vector2(client.position).distance_to(centre) <= ServerWorld.BUILD_REACH
	_ghost.modulate = Color(0.6, 1.0, 0.6, 0.6) if near else Color(1.0, 0.45, 0.45, 0.5)
	_ghost.visible = true


func _build_hotbar(layer: CanvasLayer) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	for i in PARTS.size():
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(20, 20)
		var icon := TextureRect.new()
		var v := content.visual_of(PARTS[i])
		if not v.is_empty():
			var at := AtlasTexture.new()
			at.atlas = view.texture(v["atlas_path"])
			at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
			icon.texture = at
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(2, 2)
		icon.size = Vector2(16, 16)
		slot.add_child(icon)
		bar.add_child(slot)
		_slots.append(slot)
	bar.position = Vector2(240 - PARTS.size() * 11, 228)
	layer.add_child(bar)


func _direction() -> Vector2i:
	if _opts.has("walk"):
		var p := String(_opts["walk"]).split(",")
		return Vector2i(int(p[0]), int(p[1]))
	var d := Vector2i.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		d.x -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		d.x += 1
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		d.y -= 1
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		d.y += 1
	return d


func _update_hud() -> void:
	for rid: String in client.results.keys():
		var r: Dictionary = client.results[rid]
		_note = "готово" if r.get("ok") else "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
		if r.get("ok") and _sound_on_ok.has(rid):
			audio.play(_sound_on_ok[rid], "", null)
		_sound_on_ok.erase(rid)
		client.results.erase(rid)
	var cell := Movement.cell_of(client.position)
	var state: String = {"playing": "", "connecting": "подключение…", "joining": "вход…", "disconnected": "нет связи",
		"rejected": "отказ: " + client.reject_reason}.get(client.state, client.state)
	var inv := client.inventory()
	var bag := PackedStringArray()
	for id: String in MATERIALS:
		var mark := ">" if id == MATERIALS[_material] else " "
		bag.append("%s%s %d" % [mark, content.get_def(id).get("name", id), int(inv.get(id, 0))])
	var level := "Поверхность  0" if client.z == 0 else "Этаж  %+d" % client.z
	var clock := "День %d  %s     " % [Daylight.day_of(int(client.world_time)), Daylight.clock_text(client.world_time)] \
		if client.has_time else ""
	hud.text = clock + level + "     " + "  ".join(bag)
	var info := PackedStringArray()
	if hosted:
		info.append("сервер: порт %d%s" % [hosted.port, _lan_address()])
	if settings.get_value("show_fps"):
		info.append("%d к/с" % Engine.get_frames_per_second())
	if settings.get_value("show_hints"):
		info.append("Ctrl — бег, ЛКМ/ПКМ — строить/разобрать, E — взять, F — лестница, Esc — меню")
	_info.text = "   ".join(info)
	var note := _note
	if client.has_position and _ways_at(Movement.cell_of(client.position)).size() == 2:
		note = "F — вверх, Shift+F — вниз   " + _note
	var part_name := String(content.get_def(PARTS[_part]).get("name", ""))
	if not _turns().is_empty():
		part_name += " " + String({"n": "↑", "e": "→", "s": "↓", "w": "←"}.get(_turns()[_facing % _turns().size()], "")) + " (R)"
	status.text = "%s  [%d] %s  (%d, %d)  %s" % [state, _part + 1, part_name, cell.x, cell.y, note]
	for i in _slots.size():
		_slots[i].self_modulate = Color(1.6, 1.4, 0.8) if i == _part else Color(0.7, 0.7, 0.7)


## Where others on the local network reach this host (first private IPv4).
static func _lan_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return ", адрес " + a
	return ""
