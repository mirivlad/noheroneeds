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
## --time=HOUR sets a local world's clock; --poses=PREFIX photographs the own
## RO-style character in poses (DevRuns).
##
## Controls (ADR-0021): what is in the hands and what the cursor points at
## decide what a click does (Actions): WASD/arrows walk, Ctrl runs; 1-9 choose
## the quick slot in the hands (not the wheel: it got in the way; in 3D it zooms), Q snatches the weapon (and back),
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
var crafts := CraftPanel.new()
## Requests to craft: their result says what was made.
var _craft_rids := {}
const WEATHER_WORDS := {"clear": "ясно", "cloudy": "пасмурно", "rain": "дождь", "storm": "гроза", "snow": "снег", "fog": "туман"}
## Rain, fog, lightning over the world (ADR-0033).
var weather := WeatherView.new()
## One's own state at the top left, the world's time at the top right.
var needs_box := HudBoxes.NeedsBox.new()
var clock_box := HudBoxes.ClockBox.new()
## Feeding an animal (ADR-0030): how it took it.
var _feed_rids := {}
var inventory_panel := InventoryPanel.new()
var character_panel := CharacterPanel.new()
var chest_panel := ChestPanel.new()
## Trade with a dweller (ADR-0040), and the requests about it: rid -> the dweller.
var trade_panel := TradePanel.new()
var _trade_rids := {}
## Talk with dwellers and the journal (ADR-0042).
var talk_panel := TalkPanel.new()
var journal_panel := JournalPanel.new()
var _talk_rids := {}
var _journal_rids := {}
var pin_panel := PinPanel.new()
## Request id -> the door's cell, for a locked one to ask the code.
var _door_rids := {}
## Requests about the open container: request id -> its cell.
var _chest_rids := {}
var _inv_seen := 0
## The context menu (right button) and the actions it lists.
var _menu := ActionMenu.new()
var _menu_actions: Array[Dictionary] = []
## The blueprint under the cursor ("" none; BuildCatalog.DEMOLISH: taking apart),
## where a drag began (NO_CELL: none).
var _blueprint := ""
var _drag_from := NO_CELL
const NO_CELL := Vector2i(1 << 30, 1 << 30)
## Windows begin below the boxes at the top (needs, time).
const WINDOW_TOP := 52.0
## What the cursor points at, and what can be done there with what is held.
var target := {}
var actions: Array[Dictionary] = []
var _cursor_kind := "corners"
var _cursor_drawn := []
var _hotbar_loaded := false
## Where the cursor is in the world; tests that push mouse events set it
## (a window-less viewport keeps no mouse position of its own).
var mouse_at: Variant = null


func _mouse_world() -> Vector2:
	if mouse_at != null:
		view.point_at(mouse_at)
		return mouse_at
	return view.screen_point(get_viewport().get_mouse_position())

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
## The bow held drawn (the left button held over a shot).
var _bow_drawn := false
const REPEATED := ["gather", "strike_part", "strike", "swing", "till", "sow"]
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
## Requests whose answer may say what the held thing became ("now"): rid -> the thing.
var _swap_rids := {}
## Crafts asked: rid -> the recipe (its station's sound).
var _craft_rids_recipe := {}
var _mend_rids := {}
var _learn_rids := {}
## The menu is open: no controls, and a single-player world stands still.
var paused := false
var _reported := false
## The world, in 3D (ADR-0063: the 2D view is gone).
var view := WorldView3D.new()
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
## The request for the settlements' names on the map (ADR-0038).
var _places_rid := ""
## Development runs (--demo, --goto, --ui...): none in a player's game.
var _dev: DevRuns
## The blueprint's cells this frame ([cell, why not]) and their pictures.
var _plan: Array = []
var _build_view: ClientBuildView

## What the server's refusals mean, for people.
const REASONS := {
	"young_animal": "детёныш ещё не вырос", "hungry_animal": "сначала накормите животное",
	"occupied": "место занято", "blocked": "мешает вода, стена или дерево", "someone_there": "там кто-то стоит",
	"materials": "не хватает материалов", "too_far": "слишком далеко", "no_floor": "здесь нет пола",
	"rain": "под дождём костёр не развести: дождитесь сухой погоды или поставьте его под крышей",
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
	"swimming": "в воде этого не сделать: выберитесь на берег", "no_tool": "этим этого не сделать", "nothing_to_gather": "здесь нечего добыть", "natural": "это не разобрать — только выкопать", "not_buildable": "это не строится",
	"underground": "под землёй вверх не строят: выше — другая глубина", "wrong_place": "здесь это не ставят", "side_wall": "дверь в боковой стене не видна — ставьте в стену поперёк", "door_beside": "дверь окажется в боковой стене",
	"blocked_below": "внизу что-то построено", "box_full": "сундук полон", "full": "сумка полна", "not_empty": "сначала опустошите",
	"not_a_container": "это не открыть", "unbreakable": "это не сломать", "not_damaged": "чинить нечего", "too_deep": "глубже нельзя (настройка сервера)",
	"no_station": "нужен станок рядом", "not_hungry": "вы сыты", "not_food": "это не едят",
	"aboard": "вы уже в лодке", "not_aboard": "вы не в лодке", "no_water": "рядом нет воды", "aground": "лодка на мели — столкните её в воду",
	"no_trees_here": "здесь деревья не растут", "no_seat": "мест нет", "no_shore": "рядом нет берега", "crewed": "в ней сидят",
	"broken": "сломано — почините (K или у станка)", "not_mendable": "это не чинится", "not_worn": "чинить нечего",
	"worn_out": "износилось до предела — больше не починить",
	"unknown_recipe": "этого вы не умеете: учитесь у мастера или по чертежу", "no_blueprint": "нет такого чертежа",
	"known_already": "это вы уже знаете", "standing": "деревня вам ещё мало доверяет: помогите её жителям",
	"not_skilled": "не хватает умения", "not_taught": "этому здесь не учат",
	"not_ripe": "ещё не созрело", "not_its_food": "этого не ест", "fed_already": "уже сыто", "not_a_bed": "это не кровать", "in_the_way": "мешает то, что ближе", "no_trade": "не торгует", "not_now": "сейчас не до торговли", "not_sold": "этого не продаёт", "sold_out": "больше нет", "no_money": "не хватает монет", "not_bought": "это не покупает", "no_money_there": "у него не хватает монет", "grudge": "с вами не хотят иметь дела", "no_request": "просить не о чем", "not_taken": "сначала возьмитесь", "not_done": "ещё не сделано", "nothing_to_fill": "здесь не набрать", "not_yours": "это не ваше", "not_yet": "ещё рано", "not_a_liquid": "выливать нечего", "not_tired": "спать не хочется", "not_tameable": "не приручить", "not_tillable": "здесь не вспахать", "not_a_field": "сеют на пашне", "not_a_seed": "это не сеют",
}


## What is said of a craft's result (ADR-0047): what came out, what failed
## and what it spoiled; a recipe studied or a blueprint drafted.
static func craft_note(registry: ContentRegistry, r: Dictionary) -> String:
	var name_of := func(id: String) -> String: return String(registry.get_def(id).get("name", id)).to_lower()
	if r.has("learned"):
		return "изучено: " + String(name_of.call(String(r["learned"])))
	if r.has("drafted"):
		return "записан чертёж: " + String(name_of.call(String(r["drafted"])))
	var parts := PackedStringArray()
	var made := PackedStringArray()
	for item: String in r.get("made", {}):
		made.append("%s %d" % [name_of.call(item), int(r["made"][item])])
	if not made.is_empty():
		parts.append("сделано: " + ", ".join(made))
	if int(r.get("failed", 0)) > 0:
		var lost := PackedStringArray()
		for item: String in r.get("lost", {}):
			lost.append("%s %d" % [name_of.call(item), int(r["lost"][item])])
		parts.append("не вышло: %d%s" % [int(r["failed"]), (" (испорчено: " + ", ".join(lost) + ")") if not lost.is_empty() else ""])
	return "; ".join(parts) if not parts.is_empty() else "готово"


## What is said when a thing in use broke: mend it where it is mended, or it
## fell apart (flint, or mended too often).
static func broke_note(registry: ContentRegistry, item: String, gone: bool) -> String:
	var item_name := String(registry.get_def(item).get("name", item))
	if gone:
		return "%s: износ до конца, вещь развалилась" % item_name
	var where := Wear.mend_station(registry, item)
	return "%s: поломка — почините %s" % [item_name, String(ItemCard.STATIONS.get(where, "")) if where != "" else "в руках"]


## Sets the game up; "" on success, else what went wrong (for people).
func start(cfg: Dictionary, registry: ContentRegistry, me: PlayerIdentity, server_identity: PlayerIdentity,
		character_file: PackedByteArray, player_settings: GameSettings, dev := {}) -> String:
	content = registry
	settings = player_settings
	_opts = dev
	view.configure_camera(settings)
	if not _opts.is_empty():
		_dev = DevRuns.new(self)
	match String(cfg.get("mode", "local")):
		"connect":
			var t := ENetTransport.new()
			if t.start_client(String(cfg["address"]), int(cfg["port"])) != OK:
				return "не удалось начать подключение к %s:%d" % [cfg["address"], cfg["port"]]
			client = GameClient.new(t, me, character_file, content)
			client.password = String(cfg.get("password", ""))
			client.invite = String(cfg.get("invite", ""))
		"host":
			hosted = HostedGame.start(String(cfg["world_path"]), content, me, server_identity, character_file,
				int(cfg["port"]), int(cfg.get("max_players", 8)), {"seed": WorldLibrary.seed_of(cfg.get("rules", {})),
				"password": String(cfg.get("password", ""))})
			if not hosted.ok():
				return hosted.error
			WorldLibrary.apply_rules(cfg.get("rules", {}), hosted.world)
			client = hosted.client
		_:
			DirAccess.make_dir_recursive_absolute(String(cfg["world_path"]).get_base_dir())
			game = LocalGame.start(String(cfg["world_path"]), content, me, server_identity, character_file,
				{"seed": WorldLibrary.seed_of(cfg.get("rules", {}))})
			if game == null:
				return ServerWorld.open_error if ServerWorld.open_error != "" else "не удалось открыть мир"
			WorldLibrary.apply_rules(cfg.get("rules", {}), game.world)
			if _opts.has("season"):  # dev only: --season=spring|summer|autumn|winter, its first day
				game.world.world_time += maxi(0, WorldView.SEASON_KEYS.find(String(_opts["season"]))) * Seasons.SEASON_MS
			if _opts.has("time"):  # dev only: --time=HOUR sets the world's clock
				var day_start := game.world.world_time - game.world.world_time % Daylight.DAY_MS
				game.world.world_time = day_start + int(float(_opts["time"]) * Daylight.HOUR_MS)
			if _opts.has("weather"):  # dev only: --weather=rain|storm|snow|fog|clear, the clock on to the next such hour
				var w := game.world
				for h in 24 * 120:
					if Weather.kind(w.weather_seed, w.world_time) == String(_opts["weather"]) \
							and (String(_opts["weather"]) == "fog" or not Daylight.is_night(w.world_time)):
						break
					w.world_time += Daylight.HOUR_MS / 2
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
	weather.setup(client, view)
	weather.lightning.connect(func() -> void: audio.play("thunder", "", null))
	layer.add_child(weather)  # first: under everything else on the screen
	for l: Label in [hud, status, _info]:
		l.add_theme_font_override("font", Art.font())
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", Art.TEXT)
		l.add_theme_color_override("font_outline_color", Art.INK)
		l.add_theme_constant_override("outline_size", 4)
		layer.add_child(l)
	layer.add_child(needs_box)
	layer.add_child(clock_box)
	hud.position = Vector2(6, 2)
	_info.position = Vector2(6, 16)
	_info.add_theme_color_override("font_color", Art.TEXT_DIM)
	_build_tools(layer)
	_build_view = ClientBuildView.new(client)
	painter.setup(content, view, client)
	minimap.setup(painter, client)
	layer.add_child(minimap)
	# Equipment covers the minimap in drawing and mouse picking alike.
	layer.move_child(character_panel, layer.get_child_count() - 1)
	layer.move_child(_menu, layer.get_child_count() - 1)  # the right button's list over everything
	var map_layer := CanvasLayer.new()
	map_layer.layer = 5
	add_child(map_layer)
	world_map.setup(painter, client)
	map_layer.add_child(world_map)
	get_viewport().size_changed.connect(_layout_hud)
	_layout_hud()
	_set_cursor()
	apply_settings()
	return ""


## The cursor: what a click (or E) will do (CursorArt), its pixels the
## raster's (ADR-0022), never thinner than two screen pixels.
func _set_cursor() -> void:
	var win := get_window()
	var fit := minf(float(win.size.x) / PixelDisplay.SIZE.x, float(win.size.y) / PixelDisplay.SIZE.y)
	var scale := maxi(2, roundi(fit))
	if _cursor_drawn == [_cursor_kind, scale]:
		return
	_cursor_drawn = [_cursor_kind, scale]
	Input.set_custom_mouse_cursor(CursorArt.texture(_cursor_kind, scale), Input.CURSOR_ARROW,
		CursorArt.hotspot(_cursor_kind, scale))


func _exit_tree() -> void:
	Input.set_custom_mouse_cursor(null)  # the menu has its own
	_cursor_drawn = []


func _notification(what: int) -> void:
	# Parts made up front but never added (a start that failed) are freed too.
	if what == NOTIFICATION_PREDELETE:
		for n: Node in [view, camera, hud, status, _info, audio, minimap, world_map, hotbar, catalog, crafts,
				inventory_panel, character_panel, chest_panel, trade_panel, talk_panel, journal_panel, pin_panel, _menu, weather,
				needs_box, clock_box]:
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
	camera.zoom = Vector2.ONE * z * PixelDisplay.WORLD_SCALE


## One's own state as rows of the box at the top left (ADR-0032, 0034, 0035):
## [key, name, value, most, colour, warning].
func _need_rows() -> Array:
	var rows := []
	var top := int(client.own.get("max_health", 0))
	if top > 0:
		var hp := int(client.own.get("health", top))
		rows.append(["health", "Здоровье", hp, top, Color("c84040"), "Ранены" if hp * 10 < top * 3 else ""])
	if client.own.has("needs"):  # one's own, from the server
		var n: Dictionary = client.own["needs"]
		var satiety := int(n.get("satiety", 100))
		rows.append(["satiety", "Сытость", satiety, 100, Color("d8a040"),
			"Голод!" if satiety <= 0 else ("Голодно" if satiety < int(Needs.HUNGRY) else "")])
		var warmth := int(n.get("warmth", 100))
		rows.append(["warmth", "Тепло", warmth, 100, Color("e07030"),
			"Замерзаете!" if warmth <= 0 else ("Холодно" if warmth < int(Needs.COLD) else "")])
		var energy := int(n.get("energy", 100))
		rows.append(["energy", "Бодрость", energy, 100, Color("60a8d8"),
			"Сон" if client.own.get("asleep", false) else ("Устали" if energy < int(Needs.TIRED) else "")])
	return rows


## The boxes at the top change size with what they say: the lines between them follow.
var _top_sizes := []


func _layout_top() -> void:
	var sizes := [needs_box.get_combined_minimum_size(), clock_box.get_combined_minimum_size()]
	if sizes != _top_sizes:
		_top_sizes = sizes
		_layout_hud()


## HUD coordinates are viewport pixels, independent of the world's camera.
func _layout_hud() -> void:
	var viewport_size := get_viewport_rect().size
	needs_box.position = Vector2(4, 4)
	clock_box.size = clock_box.get_combined_minimum_size()
	clock_box.position = Vector2(viewport_size.x - maxf(clock_box.size.x, Minimap.SIZE) - 4, 4)
	minimap.position = Vector2(viewport_size.x - Minimap.SIZE - 4, 34)
	hotbar.position = Vector2(floorf((viewport_size.x - hotbar.get_combined_minimum_size().x) / 2.0), viewport_size.y - 60)  # above the status line
	status.position = Vector2(6, viewport_size.y - 18)
	# Bounded lines: they cannot spill across the minimap or hotbar.
	# The lines at the top run between the two boxes.
	var left := needs_box.position.x + needs_box.get_combined_minimum_size().x + 8
	hud.position = Vector2(left, 4)
	_info.position = Vector2(left, 24)
	minimap.position.y = maxf(48, clock_box.position.y + clock_box.size.y + 4)
	for label: Label in [hud, _info, status]:
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.custom_minimum_size.x = 0
		label.size = Vector2(viewport_size.x - 12, 18)
		label.add_theme_constant_override("outline_size", 2)
	for label: Label in [hud, _info]:
		label.size.x = maxf(40, clock_box.position.x - 8 - left)


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
	# Tired, one does not run (ADR-0035): the server would not let it, so neither does the guess.
	client.run = not paused and (_opts.has("run") or Input.is_physical_key_pressed(KEY_CTRL)) \
		and int(client.own.get("needs", {}).get("energy", 100)) >= int(Needs.TIRED)
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
	if _dev:
		_dev.step(delta)
		if client == null:  # the dev run took its last picture and closed the game
			return
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
	_place_windows()
	_update_hud()
	_update_ghost()
	_frames += 1
	if _opts.has("perf"):  # dev: where a frame's time goes, every 2 s
		_perf(t_map - t0, t_sim - t_map, t_drawn - t_view, Time.get_ticks_usec() - t_drawn, delta)
	if not _reported and client.state in ["disconnected", "rejected"]:
		_reported = true
		failed.emit(("сервер отказал: " + Protocol.reason_text(client.reject_reason)) if client.state == "rejected" else "связь с сервером потеряна")
	if _opts.has("screenshot") and _frames >= int(_opts.get("frames", "120")):
		get_viewport().get_texture().get_image().save_png(String(_opts["screenshot"]))
		screenshot_taken.emit()


func _unhandled_input(event: InputEvent) -> void:
	if paused or client == null:
		return
	if not world_map.visible and view.camera_input(event):
		get_viewport().set_input_as_handled()
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
		if _menu.visible:
			_menu.hide()
			return
		if catalog.visible or crafts.visible or inventory_panel.visible or character_panel.visible or chest_panel.visible or trade_panel.visible or talk_panel.visible or journal_panel.visible or pin_panel.visible or _blueprint != "":
			_close_tools()
			return
		menu_requested.emit()
		return
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		_key((event as InputEventKey).keycode, (event as InputEventKey).shift_pressed)
	elif event is InputEventMouseButton:
		_mouse(event as InputEventMouseButton)


func _key(k: int, shift: bool) -> void:
	if game and k in [KEY_F6, KEY_F7, KEY_F8]:
		var at := game.world._spawn_way()
		if k == KEY_F6:
			var village := game.world.generator.settlements.home_plan()
			if not village.is_empty():
				at = (village["fire"] as Vector2i) + Vector2i(2, 0)
		if k == KEY_F8:
			if game.world.generator.world_seed != 431:
				_note = "Маршрут seed 431: запустите tools/start_3d_experiment.sh --quality"
				return
			at = Vector2i(-231, 816)  # Original Settlements.roads_of(), quality/inspect.gd.
		view.zoom = 38 if k == KEY_F8 else 16.875
		view.tilt = 38 if k == KEY_F8 else (65 if k == KEY_F7 else 49)
		view.yaw = PI + .6 if k == KEY_F8 else .6
		if client.location == Levels.SURFACE:
			game.world.move_character(client.character_id, at * Movement.UNIT + Vector2i.ONE * (Movement.UNIT / 2))
			_note = "Эксперимент: горная дорога (seed 431)" if k == KEY_F8 else ("Эксперимент: деревня" if k == KEY_F6 else "Эксперимент: вход в пещеру; F — спуск")
		else:
			_note = "Сначала вернитесь на поверхность через существующий переход (F)"
		return
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
			character_panel.hide()
			inventory_panel.show_for(client.inventory(), hotbar.selected, client.item_states())
	elif k == KEY_C:
		if character_panel.visible:
			character_panel.hide()
		else:
			_close_tools()
			character_panel.show_for(client.own, hotbar.held(client.inventory()))
	elif k == KEY_B:
		if catalog.visible:
			catalog.visible = false
		else:
			inventory_panel.visible = false
			character_panel.hide()
			crafts.visible = false
			catalog.open(client.inventory())
	elif k == KEY_K:
		if crafts.visible:
			crafts.visible = false
		else:
			_close_tools()
			crafts.open()
	elif k == KEY_M:
		world_map.open()
		_places_rid = client.request({"type": "places"})  # the settlements' names on it
	elif k == KEY_L:
		if journal_panel.visible:
			journal_panel.visible = false
		else:
			_close_tools()
			_journal_rids[client.request({"type": "journal"})] = true
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
	elif k == KEY_E and trade_panel.visible:
		trade_panel.visible = false
	elif k == KEY_E and talk_panel.visible:
		talk_panel.visible = false
	elif k == KEY_E:
		var q := Actions.quick(actions)
		if not q.is_empty():
			_do(q)
		else:
			_use_nearest()
	elif k == KEY_F:
		_climb_nearest("down" if shift else "up")


func _mouse(b: InputEventMouseButton) -> void:
	if _menu.visible and b.pressed:
		_menu.hide()  # a click past it lets it go, and does nothing else
		return
	if b.button_index == MOUSE_BUTTON_WHEEL_UP or b.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		return  # the wheel does not turn the quick slots (it got in the way)
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
			elif t.get("kind") == "ground" and (view.props_at(t["cell"]).get("ground", {}) as Dictionary).has("part"):
				var c: Vector2i = t["cell"]
				client.request({"type": "dismantle", "location": client.location, "x": c.x, "y": c.y, "layer": "ground"})
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
		# A bow: drawn while the button is held, the arrow loosed when it is let go.
		if not b.pressed and _bow_drawn:
			var shot := Actions.primary(actions)
			if String(shot.get("id", "")) == "shoot":
				_do(shot)
			view.loose_own(_mouse_world() - view.own_pixel_position(1.0))  # let go even before the bow is ready
			_bow_drawn = false
			return
	if not b.pressed:
		return
	if b.button_index == MOUSE_BUTTON_LEFT:
		var p := Actions.primary(actions)
		if String(p.get("id", "")) == "shoot" and p.get("enabled", true):
			_bow_drawn = true
			view.draw_own(_mouse_world() - view.own_pixel_position(1.0))
		elif not p.is_empty():
			_do(p)
	elif b.button_index == MOUSE_BUTTON_RIGHT:
		_open_menu()


## Every window the same way: in the middle, between the lines at the top
## and the quick slots below.
func _place_windows() -> void:
	var area := get_viewport_rect().size
	for w: Control in [catalog, crafts, inventory_panel, character_panel, chest_panel, trade_panel, talk_panel,
			journal_panel, pin_panel]:
		if w.visible:
			w.size = w.get_combined_minimum_size()
			w.position = Vector2(floorf((area.x - w.size.x) / 2.0),
				clampf(floorf((area.y - 60 - w.size.y) / 2.0), WINDOW_TOP, maxf(WINDOW_TOP, area.y - 60 - w.size.y)))


## The colour of what flies off a thing worked: wood, stone, earth, green.
func _chip_tint(id: String) -> Color:
	var d := content.get_def(id)
	var tool := String(d.get("gather", {}).get("tool", ""))
	if tool == "chopping" or d.get("material") == "wood":
		return Color(0.62, 0.43, 0.24)
	if tool == "mining" or d.get("material") == "stone":
		return Color(0.62, 0.62, 0.66)
	if content.kind_of(id) == "ground":
		return Color(0.5, 0.36, 0.22)
	return Color(0.45, 0.72, 0.32)


## Does an action: sends its request, or looks (inspect).
func _do(a: Dictionary) -> void:
	if not a.get("enabled", true):
		_note = String(a.get("why", "нельзя"))
		return
	if a.get("local") == "inspect":
		_note = Actions.describe(content, target, client.character_id)
		return
	if a.get("local") == "crafts":
		_close_tools()
		crafts.open(String(a["station"]))
		return
	if a.get("local") == "lock":
		pin_panel.open_for(Vector2i(int(a["request"]["x"]), int(a["request"]["y"])), true)
		return
	client.hold(hotbar.held(client.inventory()))  # the hands first: the action is done with them
	var rid := client.request(a["request"])
	if a.get("local") == "container":
		_chest_rids[rid] = Vector2i(int(a["request"]["x"]), int(a["request"]["y"]))
		return
	if a.get("local") == "trade":
		_trade_rids[rid] = String(a["request"]["creature"])
		return
	if a.get("local") == "talk":
		_talk_rids[rid] = String(a["request"]["creature"])
		return
	match String(a["id"]):
		"strike", "shoot", "swing", "strike_part", "gather", "till":
			_attacks[rid] = String(a["id"])
			# Shown at once, but only as often as the server lets one strike.
			var item := String(a["request"].get("item", ""))
			var w: Dictionary = content.get_def(item).get("weapon", {}) if item != "" else {}
			if a["request"].get("unarmed", false):
				w = {}
			var now := Time.get_ticks_msec()
			if now >= _swing_ready_ms:
				_swing_ready_ms = now + int(w.get("cooldown_ms", 700 if a["id"] == "gather" else 500))
				if _bow_drawn:
					view.loose_own(_mouse_world() - view.own_pixel_position(1.0))
				else:
					view.swing_own(_mouse_world() - view.own_pixel_position(1.0))
				if a["id"] != "shoot":
					audio.play("swing", item, null)
				if a["id"] in ["gather", "strike_part", "till"]:  # chips off what is worked
					var at := Vector2(int(a["request"].get("x", 0)) + 0.5, int(a["request"].get("y", 0)) + 0.5) * WorldView.CELL
					view.burst_at(at, "chips", _chip_tint(String(target.get("id", ""))))
			if a["id"] != "gather":
				hotbar.used(item)
		"feed":
			_feed_rids[rid] = true
		"fill", "pour":  # ADR-0037: the container in the hands becomes full or empty
			var item := String(a["request"].get("item", ""))
			_sound_on_ok[rid] = [String(a["id"]), item]
			_swap_rids[rid] = item
		"eat":
			var item := String(a["request"].get("item", ""))
			var drunk: bool = content.get_def(item).has("liquid")
			_sound_on_ok[rid] = ["drink" if drunk else "eat", item]
			if drunk:
				_swap_rids[rid] = item
		"sow":
			_sound_on_ok[rid] = ["sow", ""]
		"sleep":
			_sound_on_ok[rid] = ["sleep", ""]
		"pickup":
			_sound_on_ok[rid] = "pickup"
		"use":
			_door_rids[rid] = Vector2i(int(a["request"]["x"]), int(a["request"]["y"]))
		"jump", "climb":
			_sound_on_ok[rid] = "climb"


func _open_menu() -> void:
	_menu_actions = actions.duplicate()
	var lines: Array[Dictionary] = []
	for a: Dictionary in _menu_actions:
		lines.append({"text": String(a["name"]) + ("  (E)" if a.get("quick", false) else "") + ("  (ЛКМ)" if a.get("primary", false) else ""),
			"disabled": not a.get("enabled", true), "why": String(a.get("why", ""))})
	_menu.open(get_viewport().get_mouse_position(), Actions.describe(content, target, client.character_id), lines)


func _choose_slot(slot: int) -> void:
	hotbar.choose(slot)
	if inventory_panel.visible:
		inventory_panel.show_for(client.inventory(), slot, client.item_states())


## Q: the weapon into the hands at once, and back (Hotbar.snatch).
func _snatch_weapon() -> void:
	var note := hotbar.snatch(client.inventory())
	if note != "":
		_note = note
	if inventory_panel.visible:
		inventory_panel.show_for(client.inventory(), hotbar.selected, client.item_states())


## Cells a drag of the blueprint covers: an area for ceilings and roofs, a
## straight row (along the longer side) for the rest.
func _drag_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var role := String(content.get_def(_blueprint).get("role", ""))
	if role == "ceiling" or role == "roof" or role == "floor":
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
	crafts.visible = false
	inventory_panel.visible = false
	character_panel.hide()
	chest_panel.visible = false
	trade_panel.visible = false
	talk_panel.visible = false
	journal_panel.visible = false
	pin_panel.visible = false
	_blueprint = ""
	_drag_from = NO_CELL


## The quick slots, the catalogue, the things, the context menu.
func _build_tools(layer: CanvasLayer) -> void:
	hotbar.setup(content, view)
	layer.add_child(hotbar)
	catalog.setup(content, view)
	catalog.chosen.connect(func(part: String) -> void:
		_blueprint = part
		_facing = 0
		catalog.visible = false)
	layer.add_child(catalog)
	crafts.setup(content, view, client)
	crafts.craft.connect(func(recipe: String, count: int) -> void:
		var crid := client.request({"type": "craft", "recipe": recipe, "count": count})
		_craft_rids[crid] = true
		_craft_rids_recipe[crid] = recipe)
	crafts.mend.connect(func(r: Dictionary) -> void:
		_mend_rids[client.request(r.merged({"type": "mend"}))] = true)
	crafts.ask.connect(func(r: Dictionary) -> void:
		var arid := client.request(r)
		_craft_rids[arid] = true
		_craft_rids_recipe[arid] = String(r.get("recipe", "")))
	layer.add_child(crafts)
	inventory_panel.setup(content, view)
	inventory_panel.unslot.connect(func(slot: int) -> void:
		hotbar.put(slot, "", -1))
	layer.add_child(inventory_panel)
	inventory_panel.drop.connect(_drop_item)
	inventory_panel.wear.connect(_wear_item)
	inventory_panel.blueprints.connect(func() -> void:
		_close_tools()
		crafts.open("", CraftPanel.SHEETS))
	inventory_panel.arranged.connect(_save_bag)
	character_panel.setup(content, view)
	character_panel.wear.connect(_wear_item)
	character_panel.take_off.connect(func(slot: String) -> void:
		if slot == "main_hand":
			hotbar.put(hotbar.selected, "", -1)
		else:
			_sound_on_ok[client.request({"type": "unequip", "slot": slot})] = "equip")
	character_panel.unslot.connect(func(slot: int) -> void: hotbar.put(slot, "", -1))
	character_panel.drop.connect(_drop_item)
	layer.add_child(character_panel)
	hotbar.select_slot.connect(func(i: int) -> void: _choose_slot(i))
	hotbar.changed.connect(_save_hotbar)
	chest_panel.setup(content, view)
	chest_panel.move.connect(func(item: String, n: int, putting: bool, copy: int) -> void:
		var c := chest_panel.cell
		var r := {"type": "store" if putting else "take", "location": client.location, "x": c.x, "y": c.y, "item": item, "count": n}
		if copy >= 0:
			r["copy"] = copy
		_chest_rids[client.request(r)] = c)
	layer.add_child(chest_panel)
	trade_panel.setup(content, view)
	trade_panel.deal.connect(func(item: String, n: int, buying: bool, copy: int) -> void:
		if n > 0:
			var r := {"type": "trade", "creature": trade_panel.creature, "item": item, "count": n, "buy": buying}
			if copy >= 0:
				r["copy"] = copy
			_trade_rids[client.request(r)] = trade_panel.creature)
	layer.add_child(trade_panel)
	talk_panel.setup(content)
	talk_panel.promise.connect(func(who: String) -> void:
		_talk_rids[client.request({"type": "promise", "creature": who})] = who)
	talk_panel.report.connect(func(who: String) -> void:
		_talk_rids[client.request({"type": "report", "creature": who})] = who)
	talk_panel.learn.connect(func(who: String, recipe: String) -> void:
		_learn_rids[client.request({"type": "learn", "creature": who, "recipe": recipe})] = who)
	trade_panel.buy_blueprint.connect(func(recipe: String) -> void:
		_trade_rids[client.request({"type": "trade", "creature": trade_panel.creature, "blueprint": recipe})] = trade_panel.creature)
	talk_panel.trade.connect(func(who: String) -> void:
		talk_panel.visible = false
		_trade_rids[client.request({"type": "trade_look", "creature": who})] = who)
	layer.add_child(talk_panel)
	journal_panel.setup()
	layer.add_child(journal_panel)
	pin_panel.setup()
	pin_panel.entered.connect(func(c: Vector2i, pin: String, new_code: bool) -> void:
		var r := {"type": "lock" if new_code else "use", "location": client.location, "x": c.x, "y": c.y, "pin": pin}
		var rid := client.request(r)
		if not new_code:
			_door_rids[rid] = c)
	layer.add_child(pin_panel)
	_menu.chosen.connect(func(i: int) -> void:
		if i >= 0 and i < _menu_actions.size():
			_do(_menu_actions[i]))
	layer.add_child(_menu)


## Puts on or takes into the hands; `copy`: which of several alike things
## (ADR-0046: the axe of these two that is less worn), -1: any.
func _wear_item(item: String, copy := -1) -> void:
	var d := content.get_def(item)
	var slot := String(d.get("equip_slot", ""))
	if slot in ["", "main_hand"]:
		var at := hotbar.items.find(item)
		if at < 0:
			at = hotbar.selected
			hotbar.put(at, item, -1)
		_choose_slot(at)
		if copy > 0:
			client.hold_copy(item, copy)  # that copy first: the one in use
	else:
		var r := {"type": "equip", "item": item}
		if copy >= 0:
			r["copy"] = copy
		_sound_on_ok[client.request(r)] = "equip"


## Drops `n` of a thing; `copy`: which one of several alike (-1: any).
func _drop_item(item: String, n: int, copy := -1) -> void:
	var r := {"type": "drop", "item": item, "count": n}
	if copy >= 0:
		r["copy"] = copy
	_sound_on_ok[client.request(r)] = "drop"


## The character's quick slots as the player left them; for one seen first,
## its weapons and tools.
func _load_hotbar(inv: Dictionary) -> void:
	_hotbar_loaded = true
	var bags: Dictionary = settings.get_value("bags") if settings else {}
	inventory_panel.order = (bags.get(client.character_id, []) as Array).duplicate()
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


## The bag's cells as the player arranged them (ADR-0041).
func _save_bag(order: Array) -> void:
	if settings == null or client.character_id == "":
		return
	var saved: Dictionary = (settings.get_value("bags") as Dictionary).duplicate()
	if saved.get(client.character_id, []) == order:
		return
	saved[client.character_id] = order.duplicate()
	settings.set_value("bags", saved)
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
## roofs the cell whose cover would be drawn there (covers sit a storey higher).
func _build_cell() -> Vector2i:
	var m := _mouse_world()
	return Vector2i(floori(m.x / WorldView.CELL), floori(m.y / WorldView.CELL))


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
## The worst frame in the period: [frame, map, sim, view, ui] (us).
var _perf_worst := PackedInt64Array([0, 0, 0, 0, 0])


func _perf(map_us: int, sim_us: int, view_us: int, ui_us: int, delta: float) -> void:
	for i in 4:
		_perf_sum[i] += [map_us, sim_us, view_us, ui_us][i]
	_perf_sum[4] += int(delta * 1e6)
	_perf_sum[5] += 1
	var own := map_us + sim_us + view_us + ui_us
	if own > _perf_worst[1] + _perf_worst[2] + _perf_worst[3] + _perf_worst[4]:
		_perf_worst = PackedInt64Array([int(delta * 1e6), map_us, sim_us, view_us, ui_us])
	if _perf_sum[5] < 120:
		return
	var n := float(_perf_sum[5])
	print("perf z=%d frame %.1f ms: map %.2f sim %.2f view %.2f ui %.2f; worst ours %.1f (map %.1f sim %.1f view %.1f ui %.1f); nodes %d, sprites %d, chunks %d" % [
		client.z, _perf_sum[4] / n / 1000.0, _perf_sum[0] / n / 1000.0, _perf_sum[1] / n / 1000.0,
		_perf_sum[2] / n / 1000.0, _perf_sum[3] / n / 1000.0,
		(_perf_worst[1] + _perf_worst[2] + _perf_worst[3] + _perf_worst[4]) / 1000.0, _perf_worst[1] / 1000.0,
		_perf_worst[2] / 1000.0, _perf_worst[3] / 1000.0, _perf_worst[4] / 1000.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), view.sprite_count(), client.chunks.size()])
	_perf_sum.fill(0)
	_perf_worst.fill(0)
	if game:
		var st := game.server.take_stats()
		print("  server slowest tick %.1f ms: %s; sync loads %d" % [st["max"] / 1000.0, st["slowest_ms"], st["sync_loads"]])


func _update_ghost() -> void:
	var v := content.visual_of(_blueprint) if _blueprint != "" and _blueprint != BuildCatalog.DEMOLISH else {}
	_plan = [] if client.state != "playing" or v.is_empty() or world_map.visible else _plan_cells()
	if _opts.has("screenshot") and not _opts.has("ui"):
		_plan = []
	view.show_plan(_plan)


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
	return view.world_direction(d)


func _update_hud() -> void:
	minimap.yaw = view.yaw
	for rid: String in client.results.keys():
		var r: Dictionary = client.results[rid]
		if rid == _places_rid:
			client.results.erase(rid)
			world_map.places = r.get("places", [])
			continue
		if _talk_rids.has(rid):
			_talk_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				if r.has("thanks"):
					audio.play("pickup", "", null)
					view.react_own("pickup")
					_note = "получено: %d монет" % int(r.get("reward", 0))
				talk_panel.open_for(r)
			else:
				_note = "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			continue
		if _journal_rids.has(rid):
			_journal_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				journal_panel.open_for(r)
			continue
		if _trade_rids.has(rid):
			var who: String = _trade_rids[rid]
			_trade_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				if trade_panel.visible and trade_panel.creature == who:
					audio.play("pickup", "", null)
					view.react_own("pickup")
				trade_panel.open_for(who, r, client.inventory(), client.item_states())
			else:
				_note = "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			continue
		if _chest_rids.has(rid):
			var at: Vector2i = _chest_rids[rid]
			_chest_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				chest_panel.bag_order = inventory_panel.order
				chest_panel.open_at(at, r.get("contents", {}), int(r.get("slots", 0)), client.inventory(), r.get("states", {}),
					client.item_states())
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
		if _feed_rids.has(rid):
			_feed_rids.erase(rid)
			if r.get("ok"):
				client.results.erase(rid)
				audio.play("feed", "", null)
				_note = "приручено — теперь ваше" if r.get("tamed") else (
					"поели (%d из %d)" % [int(r.get("fed", 0)), int(r.get("of", 1))] if String(r.get("owner", "")) == "" else "поели")
				continue
		if _craft_rids.has(rid):
			_craft_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				_note = craft_note(content, r)
				# At a fire it sizzles, at a forge it rings, else hands and tools.
				var station := String(content.get_def(String(_craft_rids_recipe.get(rid, ""))).get("station", ""))
				if not (r.get("made", {}) as Dictionary).is_empty() or r.has("learned") or r.has("drafted"):
					audio.play("craft", {"fire": "base:campfire", "forge": "base:forge"}.get(station, ""), null)
			else:
				_note = "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			if crafts.visible:
				crafts.refresh()
			_craft_rids_recipe.erase(rid)
			continue
		if _learn_rids.has(rid):
			_learn_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				_note = craft_note(content, r)
				audio.play("craft", "", null)
				talk_panel.show_lessons(r.get("teaches", []))
			else:
				_note = "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			continue
		if _mend_rids.has(rid):
			_mend_rids.erase(rid)
			client.results.erase(rid)
			if r.get("ok"):
				_note = "починено: %s (починок осталось: %d)" % [String(content.get_def(String(r.get("item", ""))).get("name", "")).to_lower(),
					int(r.get("mends_left", 0))]
				audio.play("craft", "", null)
			else:
				_note = "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			if crafts.visible:
				crafts.refresh()
			continue
		if _attacks.has(rid):
			var done := String(_attacks[rid])
			_attacks.erase(rid)
			client.results.erase(rid)
			if r.get("ok") and done == "till":
				audio.play("till", "", null)
			elif r.get("ok") and done == "gather" and not r.has("bite"):  # the blow landed: the thing's own sound
				audio.play("gather", String(r.get("thing", "")), null)
			if not r.get("ok") and r.get("reason") != "not_ready":
				_note = String(REASONS.get(r.get("reason", ""), r.get("reason", "?")))
			elif r.has("broke"):  # the use that wore it out (ADR-0046)
				_note = broke_note(content, String(r["broke"]), bool(r.get("gone", false)))
			elif r.has("work"):
				_note = "%s: %d из %d" % [content.get_def(String(r.get("thing", ""))).get("name", ""), int(r["work"]), int(r["of"])]
			elif r.has("bite"):  # by luck (ADR-0031): a catch or nothing this time
				var got := PackedStringArray()
				for item: String in r.get("drops", {}):
					got.append(String(content.get_def(item).get("name", item)).to_lower())
				if r["bite"]:
					audio.play("splash", "", null)
				_note = "поймано: " + ", ".join(got) if r["bite"] else ("не клюёт" if float(r.get("chance", 0.0)) > 0.05 else "здесь выловлено — попробуйте в другом месте")
			elif r.has("drops"):
				_note = "готово"
			continue
		_note = "готово" if r.get("ok") else "нельзя: " + String(REASONS.get(r.get("reason", ""), r.get("reason", "?"))) \
			+ (" (ещё %d мин)" % ceili(int(r["seconds"]) / 60.0) if r.has("seconds") else "")
		if r.get("ok") and _sound_on_ok.has(rid):
			var snd: Variant = _sound_on_ok[rid]
			audio.play(snd[0] if snd is Array else String(snd), snd[1] if snd is Array else "", null)
		_sound_on_ok.erase(rid)
		if r.get("ok") and _swap_rids.has(rid) and r.has("now"):
			var slot := hotbar.items.find(String(_swap_rids[rid]))
			if slot >= 0 and int(client.inventory().get(_swap_rids[rid], 0)) <= 0:
				hotbar.put(slot, String(r["now"]), -1)  # the same slot holds it, full or empty
		_swap_rids.erase(rid)
		if r.get("ok") and r.get("watered", false):
			_note = "полито"
		client.results.erase(rid)
	var cell := Movement.cell_of(client.position)
	var state: String = {"playing": "", "connecting": "подключение…", "joining": "вход…", "disconnected": "нет связи",
		"rejected": "отказ: " + client.reject_reason}.get(client.state, client.state)
	var inv := client.inventory()
	var bag := PackedStringArray()
	for id: String in MATERIALS:
		bag.append("%s %d" % [content.get_def(id).get("name", id), int(inv.get(id, 0))])
	var level := "Поверхность  0" if client.z == 0 else ("Этаж  %+d" % client.z if client.z > 0 else "Глубина  −%d" % -client.z)
	if client.has_time:
		clock_box.show_time(Seasons.of(client.world_time), "%s, день %d" % [Seasons.name_of(client.world_time).capitalize(),
			Seasons.day_of(client.world_time)], "%s  %s" % [Daylight.clock_text(client.world_time),
			WEATHER_WORDS[Weather.kind(client.weather_seed, client.world_time, client.weather_place(), client.climate())] if client.z >= 0 else ""],
			Weather.kind(client.weather_seed, client.world_time, client.weather_place(), client.climate()) if client.z >= 0 else "", Daylight.is_night(client.world_time), level)
	var deaths := int(client.own.get("deaths", 0))
	if deaths > _deaths_seen and _deaths_seen >= 0:
		_note = "вы погибли и вернулись к началу"
	_deaths_seen = deaths if client.own.has("deaths") else _deaths_seen
	needs_box.show_rows(_need_rows())
	_layout_top()
	hud.text = "  ".join(bag)
	var info := PackedStringArray()
	if hosted:
		info.append("сервер: порт %d%s" % [hosted.port, _lan_address()])
	if settings.get_value("show_fps"):  # and how the 3D view keeps up
		info.append("%d к/с · %d чанков · %d объектов · %.1f мс · очередь %d" % [Engine.get_frames_per_second(),
			view._geometry.size(), view.object_count(), view._last_build_ms, view.pending_chunks()])
	if settings.get_value("show_hints"):
		info.append("ЛКМ — действие, ПКМ — все действия, E — быстрое, 1–9 — в руки, Q — оружие, I — вещи, C — персонаж, B — стройка, K — ремёсла, M — карта, L — журнал, Esc — меню")
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
		var what := Actions.describe(content, target, client.character_id)
		if not p.is_empty() and p["id"] != "inspect":
			doing = "ЛКМ: %s%s" % [p["name"], " — " + what if what != "" else ""]
		elif what != "":
			doing = what
	status.text = "%s  %s   %s   %s" % [state, hands, doing, note]
	hotbar.refresh(inv, client.item_states())
	if character_panel.visible:
		character_panel.show_for(client.own, held)
	var seen := [inv, client.item_states()].hash()  # counts, and each copy's wear
	if seen != _inv_seen:  # the open panels follow what one carries
		_inv_seen = seen
		if chest_panel.visible:
			chest_panel.refresh(inv, client.item_states())
		if trade_panel.visible:
			trade_panel.refresh(inv, client.item_states())
		if inventory_panel.visible:
			inventory_panel.show_for(inv, hotbar.selected, client.item_states())
		if crafts.visible:
			crafts.refresh()


## What the cursor points at and what can be done there (each frame), and
## the cursor that says so.
func _update_target() -> void:
	if client.state != "playing" or world_map.visible:
		return
	var mouse := _mouse_world()
	target = view.pick_target(mouse)
	var aim := Vector2i(mouse * WorldView.UNITS_PER_PIXEL)
	var held := hotbar.held(client.inventory())
	if Reach.digs(content, held) and client.has_position:
		# A pick or an axe works on the first solid thing toward the cursor,
		# within three cells, not on what the cursor is over (Reach).
		var hit := Reach.first_solid(client.position, Vector2(aim), client.is_solid)
		# What the cursor is over (a crown counts as its tree) is taken when the
		# way to it is clear: the line to its cell meets nothing before it.
		if target.get("kind") == "part" and client.is_solid(target["cell"].x, target["cell"].y):
			var middle := Vector2((target["cell"] as Vector2i) * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2))
			if Reach.first_solid(client.position, middle, client.is_solid) == target["cell"]:
				hit = target["cell"]
				aim = Vector2i(middle)
		if hit != Reach.NONE:
			target = view.part_target(hit)
			target["aim"] = aim
		elif target.get("kind") == "part" and client.is_solid(target["cell"].x, target["cell"].y):
			target = {"kind": "ground", "id": view.ground_at(client.location, Movement.cell_of(aim)),
				"cell": Movement.cell_of(aim), "location": client.location}  # out of reach: nothing to dig
	actions = Actions.of(content, client, view, held, target, aim)
	_cursor_kind = CursorArt.kind_of(actions) if _blueprint == "" else "corners"
	_set_cursor()


## Where others on the local network reach this host (first private IPv4).
static func _lan_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return ", адрес " + a
	return ""
