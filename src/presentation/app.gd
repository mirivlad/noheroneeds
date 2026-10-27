class_name App
extends Node
## The game application: the start screen with its menu, the game started
## from it, the same menu over the game (Esc). Holds what the menu and the
## game share: content, the player's key, settings, worlds and characters.
##
## Options (after "--"):
##   --profile=NAME   keeps identity, characters, worlds and settings apart
##                    (default "default"), e.g. for development runs;
##   --connect=HOST:PORT  joins a server at once, without the menu;
##   --server [options]   (with --headless) runs a dedicated server instead
##                        of the game (DedicatedServer lists the options);
##   --world=ID       plays a saved world (or makes it) at once;
## dev runs: --demo[=outside|upstairs|behind], --walk=DX,DY, --body=PLAN (plays a
## character of that body plan, made in the profile if it has none),
## --screenshot=PATH --frames=N (saves a frame and quits), --poses=PREFIX (DevRuns) start a local game
## at once in the world "local"; --menu=SCREEN (start, new_game, load,
## connect, characters, character_create, settings...) shows a menu screen.

var content: ContentRegistry
var me: PlayerIdentity
var settings: GameSettings
var worlds: WorldLibrary
var characters: CharacterLibrary
var game: GameScreen
var menu: MainMenu
var music := MusicDirector.new()
var _opts := {}
var _menu_layer := CanvasLayer.new()
var _backdrop: Control
var display: PixelDisplay


## Options given before the app enters the tree (tests); else the command line.
func configure(options: Dictionary) -> void:
	_opts = options.duplicate()
	_configured = true


var _configured := false
## Running as a dedicated server (--server): no menu, no game, no music.
var _serving := false


func _ready() -> void:
	if not _configured:
		for a in OS.get_cmdline_user_args():
			var kv := a.trim_prefix("--").split("=", true, 1)
			_opts[kv[0]] = kv[1] if kv.size() > 1 else ""
	if _opts.has("server"):
		# A built game is a dedicated server too: noheroneeds --headless -- --server [options]
		_serving = true
		set_process(false)
		music.free()  # no game here: what it would have shown goes
		_menu_layer.free()
		var server := DedicatedServer.new()
		add_child(server)
		var err := server.start(_opts)
		if err != "":
			printerr(err)
			get_tree().quit(1)
		return
	display = PixelDisplay.new()
	add_child(display)
	display.setup(get_window())
	content = ContentRegistry.load_packs(["res://content/base"])
	if not content.errors.is_empty():
		push_error("content: " + "; ".join(content.errors))
		get_tree().quit(1)
		return
	me = PlayerIdentity.load_or_create(_user("identity"))
	settings = GameSettings.load_from(_user("settings.cfg"))
	settings.apply()
	worlds = WorldLibrary.new(_user("worlds"))
	characters = CharacterLibrary.new(_user("characters"), content, me)
	_menu_layer.layer = 10
	add_child(_menu_layer)
	music.setup(content)
	add_child(music)
	get_tree().set_auto_accept_quit(false)
	if _opts.has("connect"):
		var hp := String(_opts["connect"]).split(":")
		start_game({"mode": "connect", "address": hp[0], "port": int(hp[1]) if hp.size() > 1 else 24680})
	elif _opts.has("world") or (not _opts.has("menu") and (_opts.has("demo") or _opts.has("screenshot") or _opts.has("walk") or _opts.has("poses"))):
		var id := String(_opts.get("world", "local"))
		if id == "":
			id = "local"
		if _opts.has("quality"):
			id = "quality_431"
			if not DirAccess.dir_exists_absolute(worlds.root.path_join(id)):
				id = worlds.create("quality_431", {"seed": "431", "starter_kit": true})
				# WorldLibrary.read() only exposes rules after world.db exists.
				var prepared := ServerWorld.open(worlds.db_path(id), content, {"seed": 431})
				if prepared == null:
					show_start_screen("Не удалось создать маршрут seed 431: " + ServerWorld.open_error)
					return
				prepared.close()
			if WorldLibrary.seed_of(worlds.read(id)) != 431:
				show_start_screen("Мир quality_431 уже существует с другим seed; файлы сохранены. Используйте новый отдельный профиль.")
				return
		start_game({"mode": "local", "world": id, "world_path": worlds.db_path(id), "rules": worlds.read(id)})
	else:
		show_start_screen()
		# Dev: --menu=SCREEN opens that screen (with --screenshot, for pictures).
		var screen := String(_opts.get("menu", ""))
		if screen != "" and menu.has_method("show_" + screen):
			menu.call("show_" + screen)


var _frames := 0


func _process(_delta: float) -> void:
	_frames += 1
	music.want(game.music_mood() if game and game.client else "menu")
	# Dev: --world=ID --menu=SCREEN opens the menu over the game for a picture.
	if game and _opts.has("menu") and _frames == 40:
		_on_menu_requested()
		if menu.has_method("show_" + String(_opts["menu"])):
			menu.call("show_" + String(_opts["menu"]))
	if game == null and _opts.has("screenshot") and _frames >= int(_opts.get("frames", "60")):
		get_viewport().get_texture().get_image().save_png(String(_opts["screenshot"]))
		quit()


## The start screen: a dim meadow behind the menu.
func show_start_screen(message := "") -> void:
	_end_game()
	if _backdrop == null:
		_backdrop = _make_backdrop()
		add_child(_backdrop)
		move_child(_backdrop, 0)
	_backdrop.visible = true
	_open_menu(false)
	if message != "":
		menu.tell(message)


## Dev: the profile's first character of the body plan --body names, or a new one.
func _dev_character() -> String:
	for c: Dictionary in characters.list():
		if c["body_plan"] == String(_opts["body"]):
			return String(c["file"])
	return characters.create("Путник", {}, {}, String(_opts["body"]))


func start_game(cfg: Dictionary) -> void:
	_end_game()
	_close_menu()
	var file := characters.file_bytes(_dev_character() if _opts.has("body") else characters.current(String(settings.get_value("character"))))
	game = GameScreen.new()
	add_child(game)
	var err := game.start(cfg, content, me, PlayerIdentity.load_or_create(_user("local_server_identity")),
		file, settings, _opts)
	if err != "":
		show_start_screen("Не удалось начать: " + err)
		return
	if cfg.has("world"):
		worlds.touch(String(cfg["world"]))
	if _backdrop:
		_backdrop.visible = false
	game.menu_requested.connect(_on_menu_requested)
	game.failed.connect(func(reason: String) -> void: show_start_screen(reason))
	game.screenshot_taken.connect(quit)


func quit() -> void:
	if _serving:
		get_tree().quit()
		return
	_end_game()
	music.silence()
	if not _opts.has("profile_dir"):
		Art.clear()
		get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit()


func _on_menu_requested() -> void:
	game.paused = true
	_open_menu(true)


func _open_menu(over_game: bool) -> void:
	_close_menu()
	menu = MainMenu.new(worlds, characters, settings, content, over_game)
	_menu_layer.add_child(menu)
	menu.play.connect(start_game)
	menu.quit_game.connect(quit)
	menu.to_start_screen.connect(func() -> void: show_start_screen())
	menu.resume.connect(func() -> void:
		_close_menu()
		if game:
			game.paused = false)
	menu.settings_changed.connect(func() -> void:
		if game:
			game.apply_settings())


func _close_menu() -> void:
	if menu:
		menu.queue_free()
		menu = null


## Saves and closes the running game, if any.
func _end_game() -> void:
	if game:
		game.close()
		game.queue_free()
		game = null


func _make_backdrop() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color("161219")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var v := content.visual_of("base:grass")
	if not v.is_empty():
		var grid: Vector2i = v.get("grid_size", Vector2i.ONE)
		var img := Art.texture(v["atlas_path"]).get_image().get_region(
			Rect2i(v["rect"][0], v["rect"][1], v["rect"][2] * grid.x, v["rect"][3] * grid.y))
		var tile := TextureRect.new()
		tile.texture = ImageTexture.create_from_image(img)
		tile.stretch_mode = TextureRect.STRETCH_TILE
		tile.set_anchors_preset(Control.PRESET_FULL_RECT)
		tile.modulate = Color(0.32, 0.3, 0.34)
		root.add_child(tile)
	return root


func _user(rel: String) -> String:
	if _opts.has("profile_dir"):  # tests: a profile in a directory of their own
		return String(_opts["profile_dir"]).path_join(rel)
	return ProjectSettings.globalize_path("user://profiles/%s/%s" % [_opts.get("profile", "default"), rel])
