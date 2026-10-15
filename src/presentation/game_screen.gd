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
var chest_panel := ChestPanel.new()
var pin_panel := PinPanel.new()
## Request id -> the door's cell, for a locked one to ask the code.
var _door_rids := {}
## Requests about the open container: request id -> its cell.
var _chest_rids := {}
var _inv_seen := 0
## The context menu (right button) and the actions it lists.
var _menu := PopupMenu.new()
var _menu_actions: Array[Dictionary] = []
## The blueprint under the cursor ("" none; BuildCatalog.DEMOLISH: taking apart),
## where a drag began (NO_CELL: none).
var _blueprint := ""
var _drag_from := NO_CELL
const NO_CELL := Vector2i(1 << 30, 1 << 30)
## What the cursor points at, and what can be done there with what is held.
var target := {}
var actions: Array[Dictionary] = []
var _cursor_aim := false
var _hotbar_loaded := false
## Where the cursor is in the world; tests that push mouse events set it
## (a window-less viewport keeps no mouse position of its own).
var mouse_at: Variant = null


func _mouse_world() -> Vector2:
	return mouse_at if mouse_at != null else get_global_mouse_position()

var painter := MapPainter.new()
var minimap := Minimap.new()
var world_map := WorldMap.new()
## Where one last walked: a jump goes that way.
var _last_dir := Vector2i(0, 1)
var _attacks := {}
## When the own next blow may be shown (ms, Time): the weapon's pace.
var _swing_ready_ms := 0
## The left button is held: work and blows go on at their pace (a tree is
## felled by holding it, not by a click a blow).
var _lmb_held := false
const REPEATED := ["gather", "strike_part", "strike", "swing"]
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
## The blueprint's cells this frame ([cell, why not]) and their pictures.
var _plan: Array = []
var _ghosts: Array[Sprite2D] = []
var _build_view: ClientBuildView

## What the server's refusals mean, for people.
const REASONS := {
	"occupied": "место занято", "blocked": "мешает вода, стена или дерево", "someone_there": "там кто-то стоит",
	"materials": "не хватает материалов", "too_far": "слишком далеко", "no_floor": "здесь нет пола",
	"too_high": "выше строить нельзя (настройка сервера)", "occupied_above": "сверху что-то стоит — сначала уберите",
	"no_landing": "наверху, куда смотрит лестница, нужен пол (перекрытие)", "roof_above": "над лестницей кровля",
	"ceiling_not_yours": "перекрытие над лестницей поставил другой: его можно только сломать",
	"landing_blocked": "наверху, куда выводит лестница, занято", "stairs_here": "здесь лестница: над ней проём", "stairs_below": "сначала уберите лестницу",
	"not_owner": "это чужое", "locked": "заперто", "wrong_pin": "неверный код",
	"pin_wait": "много неверных попыток — подождите", "bad_pin": "код — четыре цифры",
	"kept_for_dead": "это вещи погибшего — пока только его", "empty": "здесь нечего разбирать", "no_stairs": "здесь нет лестницы",
	"unknown_part": "неизвестная деталь", "nothing_to_use": "здесь нечего открыть", "gone": "уже подобрали",
	"not_enough": "не хватает", "no_such_place": "здесь строить нельзя",
	"no_ammo": "нет стрел", "not_carried": "этого нет при себе", "not_a_weapon": "это не оружие",
	"nothing_to_jump_from": "прыгать можно с этажа", "not_an_edge": "пол продолжается — идите",
	"roof_below": "внизу крыша", "bad_request": "не получилось",
	"no_tool": "этим этого не сделать", "nothing_to_gather": "здесь нечего добыть", "natural": "это не разобрать — только выкопать", "not_buildable": "это не строится",
	"underground": "под землёй вверх не строят: выше — другая глубина", "wrong_place": "здесь это не ставят",
	"blocked_below": "внизу что-то построено", "full": "сундук полон", "not_empty": "сначала опустошите",
	"not_a_container": "это не открыть", "unbreakable": "это не сломать", "not_damaged": "чинить нечего", "too_deep": "глубже нельзя (настройка сервера)",
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
	_build_tools(layer)
	_build_view = ClientBuildView.new(client)
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
		for n: Node in [view, camera, hud, status, _info, audio, minimap, world_map, hotbar, catalog,
				inventory_panel, chest_panel, pin_panel, _menu]:
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
	var t0 := Time.get_ticks_usec()
	painter.refresh()
	var t_map := Time.get_ticks_usec()
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
	var t_sim := Time.get_ticks_usec()
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
	if _opts.get("demo") == "loot" and game:  # dev only: looters by things lying about (ADR-0016)
		var me := Vector2i(0, 7)
		if _frames == 40:
			game.world.move_character(client.character_id, me * 256 + Vector2i(128, 128))
			game.world.creatures._spawn("base:poring", "surface", me + Vector2i(3, 0), {}, 1)
			game.world.creatures._spawn("base:poporing", "surface", me + Vector2i(-3, 1), {}, 2)
			game.world.place_item("surface", (me + Vector2i(5, 1)) * 256 + Vector2i(128, 128), "base:plank", 3)
			game.world.place_item("surface", (me + Vector2i(-5, -1)) * 256 + Vector2i(128, 128), "base:stone", 2)
	if _opts.has("swing") and _frames == int(_opts.get("frames", "120")) - int(_opts["swing"]):  # dev: a blow caught midway
		view.swing_own(Vector2.RIGHT)
	if _opts.has("open_map") and _frames == int(_opts.get("frames", "120")) - 8:  # dev: a picture of the map
		world_map.open()
	if _opts.has("ui") and _frames == int(_opts.get("frames", "120")) - 8:  # dev: a picture of a panel
		match String(_opts["ui"]):
			"catalog":
				catalog.open(client.inventory())
			"inventory":
				inventory_panel.show_for(client.inventory(), hotbar.selected)
			"pin":
				pin_panel.open_for(Vector2i(0, 2), false)
			"plan":  # a row of walls dragged, part of it out of reach
				var me := Movement.cell_of(client.position)
				_blueprint = "base:wood_wall"
				_drag_from = me + Vector2i(-4, 2)
				mouse_at = Vector2((me.x + 9) * WorldView.CELL + 8, (me.y + 2) * WorldView.CELL + 8)
	if _opts.get("demo") == "outside" and _frames == 40 and game:
		game.world.move_character(client.character_id, Vector2i(128, 7 * 256 + 128))  # dev only: before the house
	if _opts.get("demo") == "behind" and _frames == 40 and game:
		game.world.move_character(client.character_id, Vector2i(128, -5 * 256 + 200))  # dev only: behind the back wall
	if _opts.get("demo") in ["hole", "upstairs"] and game and _frames == 36:
		game.world.move_character(client.character_id, Vector2i(1 * 256 + 128, 1 * 256 + 128))  # dev only: by the stairs
	if _opts.get("demo") == "hole" and game:  # dev only: up, then the stairs gone: the opening stays
		if _frames == 40:
			client.request({"type": "climb", "location": client.location, "x": 1, "y": 0})
		if _frames == 90:
			game.world._take_down("surface", game.world.chunk("surface", 0, 0), ["surface", 0, 0, 1, 0], "structure",
				"base:wood_stairs", "")
	if _opts.get("demo") == "upstairs" and _frames == 40:
		client.request({"type": "climb", "location": client.location, "x": 1, "y": 0})
	if _opts.get("demo") == "upstairs" and _frames == 60 and client.z == 1:
		# Part of the first level roofed over: floor and ceiling side by side.
		for y in range(-3, 0):
			for x in range(-2, 1):
				client.request({"type": "build", "location": client.location, "x": x, "y": y, "part": "base:wood_ceiling"})
	if _lmb_held and not paused and _blueprint == "" and Time.get_ticks_msec() >= _swing_ready_ms:
		var held_on := Actions.primary(actions)
		if String(held_on.get("id", "")) in REPEATED:
			_do(held_on)
	var t_view := Time.get_ticks_usec()
	view.update_view(_accum / tick, delta)
	var t_drawn := Time.get_ticks_usec()
	if client.has_position:
		camera.position = view.own_pixel_position(_accum / tick).round()
	_update_target()
	_update_hud()
	_update_ghost()
	_frames += 1
	if _opts.has("perf"):  # dev: where a frame's time goes, every 2 s
		_perf(t_map - t0, t_sim - t_map, t_drawn - t_view, Time.get_ticks_usec() - t_drawn, delta)
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
		if catalog.visible or inventory_panel.visible or chest_panel.visible or pin_panel.visible or _blueprint != "":
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
	elif k == KEY_E and chest_panel.visible:
		chest_panel.visible = false
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
			var t := view.pick_target(_mouse_world())
			if t.get("kind") == "part":
				var c: Vector2i = t["cell"]
				client.request({"type": "dismantle", "location": client.location, "x": c.x, "y": c.y, "layer": t["layer"]})
		elif b.button_index == MOUSE_BUTTON_LEFT and b.pressed:
			_drag_from = _build_cell()
		elif b.button_index == MOUSE_BUTTON_LEFT and not b.pressed and _drag_from != NO_CELL:
			# Only the cells shown as allowed; the server judges each again.
			for p: Array in _plan_cells():
				if p[1] != "":
					continue
				var cell: Vector2i = p[0]
				var op := {"type": "build", "location": client.location, "x": cell.x, "y": cell.y, "part": _blueprint}
				if not _turns().is_empty():
					op["facing"] = _turns()[_facing % _turns().size()]
				client.request(op)
			_drag_from = NO_CELL
		return
	if b.button_index == MOUSE_BUTTON_LEFT:
		_lmb_held = b.pressed
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
	if a.get("local") == "lock":
		pin_panel.open_for(Vector2i(int(a["request"]["x"]), int(a["request"]["y"])), true)
		return
	client.hold(hotbar.held(client.inventory()))  # the hands first: the action is done with them
	var rid := client.request(a["request"])
	if a.get("local") == "container":
		_chest_rids[rid] = Vector2i(int(a["request"]["x"]), int(a["request"]["y"]))
		return
	match String(a["id"]):
		"strike", "shoot", "swing", "strike_part", "gather":
			_attacks[rid] = true
			# Shown at once, but only as often as the server lets one strike.
			var item := String(a["request"].get("item", ""))
			var w: Dictionary = content.get_def(item).get("weapon", {}) if item != "" else {}
			if a["request"].get("unarmed", false):
				w = {}
			var now := Time.get_ticks_msec()
			if now >= _swing_ready_ms:
				_swing_ready_ms = now + int(w.get("cooldown_ms", 700 if a["id"] == "gather" else 500))
				view.swing_own(_mouse_world() - view.own_pixel_position(1.0))
				if a["id"] != "shoot":
					audio.play("swing", item, null)
			if a["id"] != "gather":
				hotbar.used(item)
		"pickup":
			_sound_on_ok[rid] = "pickup"
		"use":
			_door_rids[rid] = Vector2i(int(a["request"]["x"]), int(a["request"]["y"]))
		"jump", "climb":
			_sound_on_ok[rid] = "climb"


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
	hotbar.choose(slot)
	if inventory_panel.visible:
		inventory_panel.show_for(client.inventory(), slot)


## Q: the weapon into the hands at once, and back (Hotbar.snatch).
func _snatch_weapon() -> void:
	var note := hotbar.snatch(client.inventory())
	if note != "":
		_note = note
	if inventory_panel.visible:
		inventory_panel.show_for(client.inventory(), hotbar.selected)


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
	while out.size() > DRAG_MAX:
		out.pop_back()  # one drag builds so many at most
	return out


func _close_tools() -> void:
	catalog.visible = false
	inventory_panel.visible = false
	chest_panel.visible = false
	pin_panel.visible = false
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
	inventory_panel.drop.connect(func(item: String, n: int) -> void:
		_sound_on_ok[client.request({"type": "drop", "item": item, "count": n})] = "drop")
	hotbar.select_slot.connect(func(i: int) -> void: _choose_slot(i))
	hotbar.changed.connect(_save_hotbar)
	chest_panel.setup(content, view)
	chest_panel.position = Vector2(60, 50)
	chest_panel.move.connect(func(item: String, n: int, putting: bool) -> void:
		var c := chest_panel.cell
		_chest_rids[client.request({"type": "store" if putting else "take", "location": client.location,
			"x": c.x, "y": c.y, "item": item, "count": n})] = c)
	layer.add_child(chest_panel)
	pin_panel.setup()
	pin_panel.position = Vector2(180, 90)
	pin_panel.entered.connect(func(c: Vector2i, pin: String, new_code: bool) -> void:
		var r := {"type": "lock" if new_code else "use", "location": client.location, "x": c.x, "y": c.y, "pin": pin}
		var rid := client.request(r)
		if not new_code:
			_door_rids[rid] = c)
	layer.add_child(pin_panel)
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
	var m := _mouse_world()
	var cell := Vector2i(floori(m.x / WorldView.CELL), floori(m.y / WorldView.CELL))
	if Terrain.layer_for_role(String(content.get_def(_blueprint).get("role", ""))) != "structure":
		cell.y += 1
	return cell


## The blueprint's cells as they would be built (ADR-0021): the dragged row
## or area (or the cell under the cursor), each judged by the same rules the
## server will use (BuildRules), with reach and the materials as they run out
## along the drag. [[cell, reason or ""], ...]
func _plan_cells() -> Array:
	var out := []
	var cells: Array[Vector2i] = []
	if _drag_from != NO_CELL:
		cells = _drag_cells(_drag_from, _build_cell())
	else:
		cells.append(_build_cell())
	var have := client.inventory().duplicate()
	var cost := content.structure_cost(_blueprint)
	var facing := String(_turns()[_facing % _turns().size()]) if not _turns().is_empty() else ""
	for cell: Vector2i in cells:
		var why := ""
		if not BuildRules.reaches(client.position, cell.x, cell.y):
			why = "too_far"
		else:
			why = BuildRules.check(_build_view, content, _blueprint, client.location, cell.x, cell.y, facing,
				client.character_id)
			if why == "unknown":
				why = ""  # not known here: the server will say
		if why == "":
			for m: String in cost:
				if int(have.get(m, 0)) < int(cost[m]):
					why = "materials"
			if why == "":
				for m: String in cost:
					have[m] = int(have.get(m, 0)) - int(cost[m])
		out.append([cell, why])
	return out


## Shows the plan: a picture on each cell, green where it can stand, red
## where not; the status line says how many, what it costs, why not.
var _perf_sum := PackedInt64Array([0, 0, 0, 0, 0, 0])


func _perf(map_us: int, sim_us: int, view_us: int, ui_us: int, delta: float) -> void:
	for i in 4:
		_perf_sum[i] += [map_us, sim_us, view_us, ui_us][i]
	_perf_sum[4] += int(delta * 1e6)
	_perf_sum[5] += 1
	if _perf_sum[5] < 120:
		return
	var n := float(_perf_sum[5])
	print("perf z=%d frame %.1f ms: map %.2f sim %.2f view %.2f ui %.2f; nodes %d, sprites in chunks %d, draw calls %d" % [
		client.z, _perf_sum[4] / n / 1000.0, _perf_sum[0] / n / 1000.0, _perf_sum[1] / n / 1000.0,
		_perf_sum[2] / n / 1000.0, _perf_sum[3] / n / 1000.0, Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		view.sprite_count(), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	_perf_sum.fill(0)


func _update_ghost() -> void:
	var v := content.visual_of(_blueprint) if _blueprint != "" and _blueprint != BuildCatalog.DEMOLISH else {}
	_plan = [] if client.state != "playing" or v.is_empty() or world_map.visible else _plan_cells()
	if _opts.has("screenshot") and not _opts.has("ui"):
		_plan = []
	while _ghosts.size() < _plan.size():
		var g := Sprite2D.new()
		g.centered = false
		g.z_index = 20
		add_child(g)
		_ghosts.append(g)
	for i in _ghosts.size():
		var g: Sprite2D = _ghosts[i]
		g.visible = i < _plan.size()
		if not g.visible:
			continue
		var cell: Vector2i = _plan[i][0]
		g.texture = view.texture(v["atlas_path"])
		g.region_enabled = true
		var facing := String(_turns()[_facing % _turns().size()]) if not _turns().is_empty() else ""
		var turned: String = v.get("mirror", {}).get(facing, facing)
		var r: Array = v.get("rotations", {}).get(turned, v["rect"])
		g.region_rect = Rect2(r[0], r[1], r[2], r[3])
		g.flip_h = v.get("mirror", {}).has(facing)
		if v["mode"] == "cover":
			g.position = Vector2(cell.x * WorldView.CELL, cell.y * WorldView.CELL - WorldView.COVER_LIFT)
		else:
			g.position = Vector2(cell.x * WorldView.CELL, (cell.y + 1) * WorldView.CELL) - Vector2(v["origin"][0], v["origin"][1])
		g.modulate = Color(0.6, 1.0, 0.6, 0.6) if _plan[i][1] == "" else Color(1.0, 0.4, 0.4, 0.5)


func _direction() -> Vector2i:
	if pin_panel.visible:
		return Vector2i.ZERO  # the keys type the code
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
		if _chest_rids.has(rid):
			var at: Vector2i = _chest_rids[rid]
			_chest_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				chest_panel.open_at(at, r.get("contents", {}), int(r.get("slots", 0)), client.inventory())
			else:
				_note = "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			continue
		if _door_rids.has(rid):
			var door: Vector2i = _door_rids[rid]
			_door_rids.erase(rid)
			if r.get("reason") == "locked":
				client.results.erase(rid)
				pin_panel.open_for(door, false)  # the code is asked for
				continue
		if _attacks.has(rid):
			_attacks.erase(rid)
			client.results.erase(rid)
			if not r.get("ok") and r.get("reason") != "not_ready":
				_note = String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			elif r.has("work"):
				_note = "%s: %d из %d" % [content.get_def(String(r.get("thing", ""))).get("name", ""), int(r["work"]), int(r["of"])]
			elif r.has("drops"):
				_note = "готово"
			continue
		_note = "готово" if r.get("ok") else "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?"))) \
			+ (" (ещё %d мин)" % ceili(int(r["seconds"]) / 60.0) if r.has("seconds") else "")
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
	view.own_held = held
	client.hold(held)  # the server's word on the hands follows (only when it changes)
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
		var ok := _plan.filter(func(p: Array) -> bool: return p[1] == "").size()
		var cost := content.structure_cost(_blueprint)
		var parts := PackedStringArray()
		for m: String in cost:
			parts.append("%s %d/%d" % [String(content.get_def(m).get("name", m)).to_lower(), int(cost[m]) * ok, int(inv.get(m, 0))])
		doing += "  %d из %d  %s" % [ok, _plan.size(), ", ".join(parts)]
		for p: Array in _plan:
			if p[1] != "":
				doing += "  нельзя: " + String(REASONS.get(p[1], p[1]))
				break
		doing += "  ПКМ — отпустить"
	else:
		var p := Actions.primary(actions)
		var what := Actions.describe(content, target)
		if not p.is_empty() and p["id"] != "inspect":
			doing = "ЛКМ: %s%s" % [p["name"], " — " + what if what != "" else ""]
		elif what != "":
			doing = what
	status.text = "%s  %s   %s   %s" % [state, hands, doing, note]
	hotbar.refresh(inv)
	if inv.hash() != _inv_seen:  # the open panels follow what one carries
		_inv_seen = inv.hash()
		if chest_panel.visible:
			chest_panel.refresh(inv)
		if inventory_panel.visible:
			inventory_panel.show_for(inv, hotbar.selected)


## What the cursor points at and what can be done there (each frame), and
## the cursor that says so.
func _update_target() -> void:
	if client.state != "playing" or world_map.visible:
		return
	var mouse := _mouse_world()
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
