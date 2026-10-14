extends Node2D
## The game client window. Single-player by default: a local server in this
## process (LocalGame). With --connect=HOST:PORT it joins a dedicated server.
## --profile=NAME keeps identity, character and local world apart (default
## "default"), e.g. for development runs.
## Dev options: --screenshot=PATH --frames=N saves a frame and quits;
## --walk=DX,DY holds a direction (for screenshots of movement);
## --demo builds a little house through ordinary requests on arrival
## (--demo=outside puts the player at the porch, --demo=upstairs goes up the
## stairs; the player starts inside).
##
## Controls (temporary): WASD/arrows walk; 1-3 choose a part; left click
## builds, right click takes down; E picks up what lies near or opens and
## closes a door next to you; G drops one of the chosen material (Tab);
## F goes up or down the stairs you stand on.

const PARTS := ["base:wood_wall", "base:stone_wall", "base:wood_door", "base:wood_ceiling",
	"base:thatch_roof", "base:wood_stairs", "base:wood_column"]
const LOCAL_KIT := {"base:plank": 120, "base:stone": 30, "base:log": 20}
const MATERIALS := ["base:plank", "base:stone", "base:log"]

var content: ContentRegistry
var game: LocalGame
var client: GameClient
var view := WorldView.new()
var camera := Camera2D.new()
var hud := Label.new()
var status := Label.new()
var _accum := 0.0
var _part := 0
var _material := 0
var _note := ""
var _opts := {}
var _frames := 0
var _demo_done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_opts[kv[0]] = kv[1] if kv.size() > 1 else ""
	content = ContentRegistry.load_packs(["res://content/base"])
	if not content.errors.is_empty():
		push_error("content: " + "; ".join(content.errors))
		get_tree().quit(1)
		return
	var me := PlayerIdentity.load_or_create(_user("identity"))
	var file := _character_file(me)
	if _opts.has("connect"):
		var hp := String(_opts["connect"]).split(":")
		var t := ENetTransport.new()
		t.start_client(hp[0], int(hp[1]) if hp.size() > 1 else 24680)
		client = GameClient.new(t, me, file, content)
	else:
		var path := _user("worlds/local/world.db")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		game = LocalGame.start(path, content, me,
			PlayerIdentity.load_or_create(_user("local_server_identity")), file)
		game.world.starter_kit = LOCAL_KIT
		client = game.client
	view.setup(content, client)
	add_child(view)
	camera.position_smoothing_enabled = false
	add_child(camera)
	var layer := CanvasLayer.new()
	add_child(layer)
	var font: Font = load("res://assets/fonts/monogram.ttf")
	for l: Label in [hud, status]:
		l.add_theme_font_override("font", font)
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", Color("f2e6c8"))
		l.add_theme_color_override("font_outline_color", Color("1e1824"))
		l.add_theme_constant_override("outline_size", 4)
		layer.add_child(l)
	hud.position = Vector2(6, 2)
	status.position = Vector2(6, 252)


func _process(delta: float) -> void:
	if client == null:
		return
	client.move = _direction()
	_accum += delta
	var tick := 1.0 / Movement.TICK_RATE
	var steps := 0
	while _accum >= tick and steps < 4:
		if game:
			game.step()
		else:
			client.step()
		_accum -= tick
		steps += 1
	if _accum > tick * 4:
		_accum = 0.0
	if _opts.has("demo") and not _demo_done and client.state == "playing" and client.has_position:
		_demo_done = true
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
		client.request({"type": "drop", "item": "base:stone", "count": 2})
	if _opts.get("demo") == "" and _frames == 30:
		client.request({"type": "use", "location": client.location, "x": 0, "y": 2})
	if _opts.get("demo") == "outside" and _frames == 40 and game:
		game.world.move_character(client.character_id, Vector2i(128, 4 * 256 + 128))  # dev only: to the porch
	if _opts.get("demo") == "upstairs" and _frames == 40:
		client.request({"type": "climb", "location": client.location, "x": 1, "y": 0})
	view.update_view(_accum / tick, delta)
	if client.has_position:
		camera.position = view.own_pixel_position(_accum / tick).round()
	_update_hud()
	_frames += 1
	if _opts.has("screenshot") and _frames >= int(_opts.get("frames", "120")):
		get_viewport().get_texture().get_image().save_png(String(_opts["screenshot"]))
		_quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var k: int = (event as InputEventKey).keycode
		if k >= KEY_1 and k < KEY_1 + PARTS.size():
			_part = k - KEY_1
		elif k == KEY_TAB:
			_material = (_material + 1) % MATERIALS.size()
		elif k == KEY_G and client.state == "playing":
			client.request({"type": "drop", "item": MATERIALS[_material], "count": 1})
		elif k == KEY_E and client.state == "playing":
			_use_nearest()
		elif k == KEY_F and client.state == "playing":
			var me := Movement.cell_of(client.position)
			client.request({"type": "climb", "location": client.location, "x": me.x, "y": me.y})
	elif event is InputEventMouseButton and event.pressed and client.state == "playing":
		var cell := (get_global_mouse_position() / WorldView.CELL).floor()
		var op := {"location": client.location, "x": int(cell.x), "y": int(cell.y)}
		if event.button_index == MOUSE_BUTTON_LEFT:
			op["type"] = "build"
			op["part"] = PARTS[_part]
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			op["type"] = "dismantle"
		else:
			return
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
		client.request({"type": "pickup", "entity": best})
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit()


func _quit() -> void:
	if game:
		game.close()
		game = null
	elif client:
		client.transport.close()
	get_tree().quit()


func _user(rel: String) -> String:
	return ProjectSettings.globalize_path("user://profiles/%s/%s" % [_opts.get("profile", "default"), rel])


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
		_note = "готово" if r.get("ok") else "нельзя: " + String(r.get("reason", "?"))
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
	hud.text = level + "     " + "  ".join(bag)
	status.text = "%s  [%d] %s  (%d, %d)  %s" % [state, _part + 1, content.get_def(PARTS[_part]).get("name", ""),
		cell.x, cell.y, _note]


## The player's character: made once with default looks, kept as a signed file.
func _character_file(me: PlayerIdentity) -> PackedByteArray:
	var path := _user("characters/main.nhnchar")
	if FileAccess.file_exists(path):
		var existing := FileAccess.get_file_as_bytes(path)
		if CharacterFile.read(existing, content).ok:
			return existing
	var c := PortableCharacter.create("Путник", "base:humanoid_adult")
	c.styles = {"hair": "base:hair_short", "face": "base:face_soft", "eyes": "base:eyes_round"}
	c.colors = {"skin": "#eab295", "hair": "#8a3a20", "eyes": "#2f7a52"}
	var file := CharacterFile.export_signed(c, me, content)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(file)
	f.close()
	return file
