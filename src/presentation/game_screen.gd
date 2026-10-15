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
## Controls (ADR-0021): what is in the hands and what the cursor points at
## decide what a click does (Actions): WASD/arrows walk, Ctrl runs; 1-9 or the
## wheel choose the quick slot in the hands, Q snatches the weapon (and back),
## I the things to put into the slots, G drops one of what is in the hands;
## the left button does the main thing (strike, shoot, dig, fell, look), the
## right one opens the list of all that can be done; E the quick one (open,
## pick up, climb); B the building catalogue: a blueprint under the cursor,
## the left button (drag for a row or an area) builds, R turns it, the right
## button lets it go; F the stairs or a way between depths (Shift+F down);
## J jumps off an edge; M the world map, - and = the minimap; Esc the menu.

signal menu_requested
## The connection is gone or the server refused us (reason for people).
signal failed(reason: String)
signal screenshot_taken

## Shown in the HUD: the common building materials.
const MATERIALS := ["base:plank", "base:stone", "base:log"]
## Most cells one drag of a blueprint builds at once.
const DRAG_MAX := 64

var content: ContentRegistry
## Attack requests in flight, deaths already told (-1: none seen yet).
var hotbar := Hotbar.new()
var catalog := BuildCatalog.new()
var inventory_panel := InventoryPanel.new()
## The context menu (right button) and the actions it lists.
var _menu := PopupMenu.new()
var _menu_actions: Array[Dictionary] = []
## The blueprint under the cursor ("" none; BuildCatalog.DEMOLISH: taking apart),
## where a drag began (NO_CELL: none).
var _blueprint := ""
var _drag_from := NO_CELL
const NO_CELL := Vector2i(1 << 30, 1 << 30)
## Q: the slot of the weapon last held, and the slot before it.
var _weapon_slot := -1
var _back_slot := 0
## What the cursor points at, and what can be done there with what is held.
var target := {}
var actions: Array[Dictionary] = []
var _cursor_aim := false
var _hotbar_loaded := false
var painter := MapPainter.new()
var minimap := Minimap.new()
var world_map := WorldMap.new()
## Where one last walked: a jump goes that way.
var _last_dir := Vector2i(0, 1)
var _attacks := {}
var _deaths_seen := -1
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
## The facing the blueprint will be built in (ADR-0013), turned with R.
var _facing := 0
var _note := ""
var _opts := {}
var _frames := 0
var _demo_done := false
## The blueprint under the mouse, as it would stand: green if in reach.
var _ghost := Sprite2D.new()

## What the server's refusals mean, for people.
const REASONS := {
	"occupied": "место занято", "blocked": "мешает вода, стена или дерево", "someone_there": "там кто-то стоит",
	"materials": "не хватает материалов", "too_far": "слишком далеко", "no_floor": "здесь нет пола",
	"too_high": "выше строить нельзя (настройка сервера)", "occupied_above": "сверху что-то стоит — сначала уберите",
	"no_opening_above": "лестнице нужно перекрытие над ней или там, куда она ведёт", "stairs_below": "сначала уберите лестницу",
	"not_owner": "это не ваше", "empty": "здесь нечего разбирать", "no_stairs": "здесь нет лестницы",
	"unknown_part": "неизвестная деталь", "nothing_to_use": "здесь нечего открыть", "gone": "уже подобрали",
	"not_enough": "не хватает", "no_such_place": "здесь строить нельзя",
	"no_ammo": "нет стрел", "not_carried": "этого нет при себе", "not_a_weapon": "это не оружие",
	"nothing_to_jump_from": "прыгать можно с этажа", "not_an_edge": "пол продолжается — идите",
	"roof_below": "внизу крыша", "bad_request": "не получилось",
	"no_tool": "этим этого не сделать", "nothing_to_gather": "здесь нечего добыть", "natural": "это не разобрать — только выкопать", "not_buildable": "это не строится",
	"underground": "под землёй вверх не строят: выше — другая глубина", "wrong_place": "здесь это не ставят",
	"blocked_below": "внизу что-то построено", "too_deep": "глубже нельзя (настройка сервера)",
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
	_build_tools(layer)
	painter.setup(content, view, client)
	minimap.setup(painter, client)
	minimap.position = Vector2(480 - Minimap.SIZE - 4, 34)
	layer.add_child(minimap)
	var map_layer := CanvasLayer.new()
	map_layer.layer = 5
	add_child(map_layer)
	world_map.setup(painter, client)
	map_layer.add_child(world_map)
	_set_cursor()
	apply_settings()
	return ""


## The cursor: a crosshair when a click would strike or shoot, else the
## corners of a square.
func _set_cursor() -> void:
	var combat := _cursor_aim
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var ink := Color(0.1, 0.08, 0.07)
	var light := Color(0.98, 0.94, 0.82) if not combat else Color(1.0, 0.45, 0.35)
	for pass_ in 2:
		var c := ink if pass_ == 0 else light
		var o := 1 if pass_ == 0 else 0  # the outline one pixel round
		if combat:
			for d in range(-9 - o, 10 + o):
				if absi(d) > 3 - o:
					for w in range(-o, o + 1):
						img.set_pixel(16 + d, 16 + w, c)
						img.set_pixel(16 + w, 16 + d, c)
			img.set_pixel(16, 16, c)
		else:
			for corner: Vector2i in [Vector2i(6, 6), Vector2i(25, 6), Vector2i(6, 25), Vector2i(25, 25)]:
				var sx := 1 if corner.x < 16 else -1
				var sy := 1 if corner.y < 16 else -1
				for d in range(-o, 6 + o):
					for w in range(-o, o + 1):
						img.set_pixel(corner.x + d * sx, corner.y + w, c)
						img.set_pixel(corner.x + w, corner.y + d * sy, c)
	Input.set_custom_mouse_cursor(ImageTexture.create_from_image(img), Input.CURSOR_ARROW, Vector2(16, 16))


func _exit_tree() -> void:
	Input.set_custom_mouse_cursor(null)  # the menu has its own


func _notification(what: int) -> void:
	# Parts made up front but never added (a start that failed) are freed too.
	if what == NOTIFICATION_PREDELETE:
		for n: Node in [view, camera, hud, status, _info, _ghost, audio, minimap, world_map, hotbar, catalog,
				inventory_panel, _menu]:
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
	painter.refresh()
	client.move = _direction() if not paused and not world_map.visible else Vector2i.ZERO
	if client.move != Vector2i.ZERO:
		_last_dir = client.move
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
				var facing := ""
				if absi(x) == 2:  # windows to the front, a loophole to the back (ADR-0015)
					part = "base:wood_window" if y == 2 else "base:loophole"
					facing = "s" if y == 2 else "n"
				client.request({"type": "build", "location": client.location, "x": x, "y": y, "part": part, "facing": facing})
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
	if _opts.get("demo") == "fight" and game:  # dev only: a wolf, a hurt deer, an arrow (ADR-0019)
		var me := Vector2i(0, 7)
		if _frames == 40:
			game.world.move_character(client.character_id, me * 256 + Vector2i(128, 128))
			var deer := game.world.creatures._spawn("base:deer", "surface", me + Vector2i(-3, 0), {}, 1)
			game.world.combat.hurt(deer.id, 4, "")
			game.world.creatures._spawn("base:wolf", "surface", me + Vector2i(4, -1), {}, 2)
			game.world.combat.hurt(client.character_id, 6, "")
		if _frames == 100:
			client.request({"type": "attack", "item": "base:bow", "x": (me.x + 10) * 256, "y": me.y * 256 + 128})
	if _opts.get("demo") == "cave" and game:  # dev only: down the way near the spawn point (ADR-0017)
		var way := game.world._spawn_way()
		if _frames == 40:
			game.world.move_character(client.character_id, way * 256 + Vector2i(128, 128))
		if _frames == 50:
			client.request({"type": "climb", "location": "surface", "x": way.x, "y": way.y})
		if _frames == 70:
			game.world.grant(client.character_id, "base:log", 2)
			client.request({"type": "build", "location": client.location, "x": way.x + 1, "y": way.y + 1, "part": "base:torch"})
	if _opts.has("open_map") and _frames == int(_opts.get("frames", "120")) - 8:  # dev: a picture of the map
		world_map.open()
	if _opts.has("ui") and _frames == int(_opts.get("frames", "120")) - 8:  # dev: a picture of a panel
		match String(_opts["ui"]):
			"catalog":
				catalog.open(client.inventory())
			"inventory":
				inventory_panel.show_for(client.inventory(), hotbar.selected)
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
	_update_target()
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
	if event is InputEventKey and event.pressed and world_map.visible:
		var mk: int = (event as InputEventKey).keycode
		if mk == KEY_ESCAPE or mk == KEY_M:
			world_map.close()
		else:
			world_map.key(mk)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if catalog.visible or inventory_panel.visible or _blueprint != "":
			_close_tools()
			return
		menu_requested.emit()
		return
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		_key((event as InputEventKey).keycode, (event as InputEventKey).shift_pressed)
	elif event is InputEventMouseButton:
		_mouse(event as InputEventMouseButton)


func _key(k: int, shift: bool) -> void:
	var slot := k - KEY_1
	if k >= KEY_1 and k <= KEY_9:
		_choose_slot(slot)
	elif k == KEY_Q:
		_snatch_weapon()
	elif k == KEY_I:
		if inventory_panel.visible:
			inventory_panel.visible = false
		else:
			catalog.visible = false
			inventory_panel.show_for(client.inventory(), hotbar.selected)
	elif k == KEY_B:
		if catalog.visible:
			catalog.visible = false
		else:
			inventory_panel.visible = false
			catalog.open(client.inventory())
	elif k == KEY_M:
		world_map.open()
	elif k == KEY_MINUS or k == KEY_KP_SUBTRACT:
		minimap.zoom(1)  # farther out
	elif k == KEY_EQUAL or k == KEY_KP_ADD:
		minimap.zoom(-1)
	elif k == KEY_R and _blueprint != "":
		var turns := _turns()
		if not turns.is_empty():
			_facing = (_facing + 1) % turns.size()
	elif client.state != "playing":
		return
	elif k == KEY_J:
		_sound_on_ok[client.request({"type": "jump", "dx": _last_dir.x, "dy": _last_dir.y})] = "climb"
	elif k == KEY_G:
		var held := hotbar.held(client.inventory())
		if held != "":
			_sound_on_ok[client.request({"type": "drop", "item": held, "count": 1})] = "drop"
	elif k == KEY_E:
		var q := Actions.quick(actions)
		if not q.is_empty():
			_do(q)
		else:
			_use_nearest()
	elif k == KEY_F:
		_climb_nearest("down" if shift else "up")


func _mouse(b: InputEventMouseButton) -> void:
	if b.button_index == MOUSE_BUTTON_WHEEL_UP or b.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if b.pressed:
			_choose_slot(posmod(hotbar.selected + (-1 if b.button_index == MOUSE_BUTTON_WHEEL_UP else 1), Hotbar.SLOTS))
		return
	if client.state != "playing":
		return
	if _blueprint != "":
		if b.button_index == MOUSE_BUTTON_RIGHT and b.pressed:
			_blueprint = ""  # the blueprint is let go
			_drag_from = NO_CELL
		elif b.button_index == MOUSE_BUTTON_LEFT and _blueprint == BuildCatalog.DEMOLISH and b.pressed:
			var t := view.pick_target(get_global_mouse_position())
			if t.get("kind") == "part":
				var c: Vector2i = t["cell"]
				client.request({"type": "dismantle", "location": client.location, "x": c.x, "y": c.y, "layer": t["layer"]})
		elif b.button_index == MOUSE_BUTTON_LEFT and b.pressed:
			_drag_from = _build_cell()
		elif b.button_index == MOUSE_BUTTON_LEFT and not b.pressed and _drag_from != NO_CELL:
			for cell in _drag_cells(_drag_from, _build_cell()):
				var op := {"type": "build", "location": client.location, "x": cell.x, "y": cell.y, "part": _blueprint}
				if not _turns().is_empty():
					op["facing"] = _turns()[_facing % _turns().size()]
				client.request(op)
			_drag_from = NO_CELL
		return
	if not b.pressed:
		return
	if b.button_index == MOUSE_BUTTON_LEFT:
		var p := Actions.primary(actions)
		if not p.is_empty():
			_do(p)
	elif b.button_index == MOUSE_BUTTON_RIGHT:
		_open_menu()


## Does an action: sends its request, or looks (inspect).
func _do(a: Dictionary) -> void:
	if not a.get("enabled", true):
		_note = String(a.get("why", "нельзя"))
		return
	if a.get("local") == "inspect":
		_note = Actions.describe(content, target)
		return
	var rid := client.request(a["request"])
	match String(a["id"]):
		"strike", "shoot", "swing":
			_attacks[rid] = true
			if a["id"] != "shoot":
				audio.play("swing", String(a["request"].get("item", "")), null)
			var item := String(a["request"].get("item", ""))
			if item != "":
				_weapon_slot = hotbar.items.find(item)
		"pickup":
			_sound_on_ok[rid] = "pickup"


func _open_menu() -> void:
	_menu.clear()
	_menu_actions = actions.duplicate()
	var title := Actions.describe(content, target)
	if title != "":
		_menu.add_separator(title)
	for i in _menu_actions.size():
		var a: Dictionary = _menu_actions[i]
		var label := String(a["name"]) + ("  (E)" if a.get("quick", false) else "") + ("  (ЛКМ)" if a.get("primary", false) else "")
		_menu.add_item(label, i)
		if not a.get("enabled", true):
			_menu.set_item_disabled(_menu.get_item_index(i), true)
			_menu.set_item_tooltip(_menu.get_item_index(i), String(a.get("why", "")))
	_menu.position = Vector2i(get_viewport().get_mouse_position() * get_viewport().get_screen_transform().get_scale())
	_menu.reset_size()
	_menu.popup()


func _choose_slot(slot: int) -> void:
	if slot != hotbar.selected:
		_back_slot = hotbar.selected
	hotbar.selected = slot
	if inventory_panel.visible:
		inventory_panel.show_for(client.inventory(), slot)


## Q: the weapon into the hands at once (the last one used, else the first in
## the slots); again, back to what was held before.
func _snatch_weapon() -> void:
	var held := hotbar.items[hotbar.selected]
	if held != "" and content.get_def(held).has("weapon") and not content.get_def(held).has("tools"):
		_choose_slot(_back_slot)
		return
	var slot := _weapon_slot
	if slot < 0 or hotbar.items[slot] == "" or not content.get_def(hotbar.items[slot]).has("weapon"):
		slot = -1
		for i in Hotbar.SLOTS:
			var id := hotbar.items[i]
			if id != "" and content.get_def(id).has("weapon") and int(client.inventory().get(id, 0)) > 0:
				slot = i
				break
	if slot >= 0:
		_choose_slot(slot)
		_weapon_slot = slot
	else:
		_note = "оружия в ячейках нет (I — положить)"


## Cells a drag of the blueprint covers: an area for ceilings and roofs, a
## straight row (along the longer side) for the rest.
func _drag_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var role := String(content.get_def(_blueprint).get("role", ""))
	if role == "ceiling" or role == "roof":
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
				out.append(Vector2i(x, y))
	elif absi(b.x - a.x) >= absi(b.y - a.y):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			out.append(Vector2i(x, a.y))
	else:
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			out.append(Vector2i(a.x, y))
	return out.slice(0, DRAG_MAX)


func _close_tools() -> void:
	catalog.visible = false
	inventory_panel.visible = false
	_blueprint = ""
	_drag_from = NO_CELL


## The quick slots, the catalogue, the things, the context menu.
func _build_tools(layer: CanvasLayer) -> void:
	hotbar.setup(content, view)
	hotbar.position = Vector2(240 - Hotbar.SLOTS * 11, 228)
	layer.add_child(hotbar)
	catalog.setup(content, view)
	catalog.position = Vector2(6, 40)
	catalog.chosen.connect(func(part: String) -> void:
		_blueprint = part
		_facing = 0
		catalog.visible = false)
	layer.add_child(catalog)
	inventory_panel.setup(content, view)
	inventory_panel.position = Vector2(130, 50)
	inventory_panel.chosen.connect(func(item: String) -> void:
		hotbar.assign(item)
		_save_hotbar()
		inventory_panel.show_for(client.inventory(), hotbar.selected))
	layer.add_child(inventory_panel)
	_menu.theme = Art.theme()
	_menu.id_pressed.connect(func(i: int) -> void:
		if i >= 0 and i < _menu_actions.size():
			_do(_menu_actions[i]))
	add_child(_menu)


## The character's quick slots as the player left them; for one seen first,
## its weapons and tools.
func _load_hotbar(inv: Dictionary) -> void:
	_hotbar_loaded = true
	var saved: Dictionary = settings.get_value("hotbars") if settings else {}
	var mine: Array = saved.get(client.character_id, [])
	if mine.is_empty():
		hotbar.fill_from(inv)
		_save_hotbar()
		return
	for i in mini(mine.size(), Hotbar.SLOTS):
		hotbar.items[i] = String(mine[i])


func _save_hotbar() -> void:
	if settings == null or client.character_id == "":
		return
	var saved: Dictionary = (settings.get_value("hotbars") as Dictionary).duplicate()
	saved[client.character_id] = Array(hotbar.items)
	settings.set_value("hotbars", saved)
	settings.save()


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
	if part != "" and content.get_def(part).get("role") == "shaft":
		ways.append(String(content.get_def(part).get("leads", "down")))  # between depths (ADR-0017)
	if c.get_props(lx, ly).get("stairs_down", false):
		ways.append("down")
	return ways


## The facings the chosen part may be built in ([] if it does not turn).
func _turns() -> Array:
	return content.get_def(_blueprint).get("rotations", []) if _blueprint != "" else []


## Where a click would build: the cell under the mouse, or for ceilings and
## roofs the cell whose cover would be drawn there (covers sit a cell higher).
func _build_cell() -> Vector2i:
	var m := get_global_mouse_position()
	var cell := Vector2i(floori(m.x / WorldView.CELL), floori(m.y / WorldView.CELL))
	if Terrain.layer_for_role(String(content.get_def(_blueprint).get("role", ""))) != "structure":
		cell.y += 1
	return cell


func _update_ghost() -> void:
	var v := content.visual_of(_blueprint) if _blueprint != "" and _blueprint != BuildCatalog.DEMOLISH else {}
	if client.state != "playing" or v.is_empty() or _opts.has("screenshot") or world_map.visible:
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
		if _attacks.has(rid):
			_attacks.erase(rid)
			client.results.erase(rid)
			if not r.get("ok") and r.get("reason") != "not_ready":
				_note = String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			continue
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
		bag.append("%s %d" % [content.get_def(id).get("name", id), int(inv.get(id, 0))])
	var level := "Поверхность  0" if client.z == 0 else ("Этаж  %+d" % client.z if client.z > 0 else "Глубина  −%d" % -client.z)
	var clock := "День %d  %s     " % [Daylight.day_of(int(client.world_time)), Daylight.clock_text(client.world_time)] \
		if client.has_time else ""
	var top := int(client.own.get("max_health", 0))
	var health := "Здоровье %d/%d     " % [int(client.own.get("health", top)), top] if top > 0 else ""
	var deaths := int(client.own.get("deaths", 0))
	if deaths > _deaths_seen and _deaths_seen >= 0:
		_note = "вы погибли и вернулись к началу"
	_deaths_seen = deaths if client.own.has("deaths") else _deaths_seen
	hud.text = clock + level + "     " + health + "  ".join(bag)
	var info := PackedStringArray()
	if hosted:
		info.append("сервер: порт %d%s" % [hosted.port, _lan_address()])
	if settings.get_value("show_fps"):
		info.append("%d к/с" % Engine.get_frames_per_second())
	if settings.get_value("show_hints"):
		info.append("ЛКМ — действие, ПКМ — все действия, E — быстрое, 1–9/колесо — в руки, Q — оружие, I — вещи, B — стройка, M — карта, Esc — меню")
	_info.text = "   ".join(info)
	var note := _note
	if client.has_position and _ways_at(Movement.cell_of(client.position)).size() == 2:
		note = "F — вверх, Shift+F — вниз   " + _note
	if not _hotbar_loaded and client.character_id != "" and client.own.has("inventory"):
		_load_hotbar(inv)
	var held := hotbar.held(inv)
	var hands := "в руках: " + (String(content.get_def(held).get("name", held)) if held != "" else "ничего")
	if held != "" and content.get_def(held).get("weapon", {}).get("kind") == "ranged":
		hands += " (%d)" % int(inv.get(String(content.get_def(held)["weapon"]["ammo"]), 0))
	var doing := ""
	if _blueprint == BuildCatalog.DEMOLISH:
		doing = "РАЗБОРКА: ЛКМ — разобрать своё, ПКМ — отпустить"
	elif _blueprint != "":
		doing = "чертёж: " + String(content.get_def(_blueprint).get("name", _blueprint))
		if not _turns().is_empty():
			doing += " " + String({"n": "↑", "e": "→", "s": "↓", "w": "←"}.get(_turns()[_facing % _turns().size()], "")) + " (R)"
		var cost := content.structure_cost(_blueprint)
		var n := _drag_cells(_drag_from, _build_cell()).size() if _drag_from != NO_CELL else 1
		var parts := PackedStringArray()
		for m: String in cost:
			parts.append("%s %d/%d" % [String(content.get_def(m).get("name", m)).to_lower(), int(cost[m]) * n, int(inv.get(m, 0))])
		doing += ("  ×%d" % n if n > 1 else "") + "  " + ", ".join(parts) + "  ПКМ — отпустить"
	else:
		var p := Actions.primary(actions)
		var what := Actions.describe(content, target)
		if not p.is_empty() and p["id"] != "inspect":
			doing = "ЛКМ: %s%s" % [p["name"], " — " + what if what != "" else ""]
		elif what != "":
			doing = what
	status.text = "%s  %s   %s   %s" % [state, hands, doing, note]
	hotbar.refresh(inv)


## What the cursor points at and what can be done there (each frame), and
## the cursor that says so.
func _update_target() -> void:
	if client.state != "playing" or world_map.visible:
		return
	var mouse := get_global_mouse_position()
	target = view.pick_target(mouse)
	var aim := Vector2i(mouse * WorldView.UNITS_PER_PIXEL)
	actions = Actions.of(content, client, view, hotbar.held(client.inventory()), target, aim)
	var p := Actions.primary(actions)
	var aiming := _blueprint == "" and String(p.get("id", "")) in ["strike", "shoot", "swing"]
	if aiming != _cursor_aim:
		_cursor_aim = aiming
		_set_cursor()


## Where others on the local network reach this host (first private IPv4).
static func _lan_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return ", адрес " + a
	return ""
