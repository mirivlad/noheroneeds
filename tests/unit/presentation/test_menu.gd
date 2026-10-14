extends TestCase
## The menu as a player uses it: buttons pressed, games started and left.

var app: App


func before_each() -> void:
	app = App.new()
	app.configure({"profile_dir": tmp_dir()})
	(Engine.get_main_loop() as SceneTree).root.add_child(app)


func after_each() -> void:
	app.quit()
	app.free()
	# Screens the menu let go of are freed at the end of a frame.
	for i in 2:
		await (Engine.get_main_loop() as SceneTree).process_frame


func _press(text: String) -> bool:
	for b: Button in app.menu.find_children("*", "Button", true, false):
		if not b.is_queued_for_deletion() and (b.text == text or b.tooltip_text == text) and not b.disabled:
			b.pressed.emit()
			return true
	failures.append("%s: no button '%s'" % [current, text])
	return false


func _play(frames: int) -> void:
	for i in frames:
		app.game._process(0.05)
		if app.game.client.state == "playing" and app.game.client.has_position:
			return
		OS.delay_msec(2)


func test_new_local_game_then_back_to_the_start_screen() -> void:
	check(app.menu != null and not app.menu.in_game, "the start screen")
	_press("Новая игра")
	_press("Локально")
	var name_edit: LineEdit = app.menu.find_children("*", "LineEdit", true, false)[0]
	name_edit.text = "Тестовый лес"
	_press("Создать и играть")
	check(app.game != null and app.menu == null, "playing, no menu")
	_play(100)
	eq(app.game.client.state, "playing")
	app.game.menu_requested.emit()  # Esc
	check(app.menu != null and app.menu.in_game, "the menu over the game")
	check(app.game.paused, "a single-player world stands still")
	_press("Продолжить")
	check(app.menu == null and not app.game.paused, "back in the game")
	app.game.menu_requested.emit()
	_press("Выход в главное меню")
	check(app.game == null, "the game is closed")
	check(app.menu != null and not app.menu.in_game, "the start screen again")
	var all := app.worlds.list()
	eq(all.size(), 1)
	eq(all[0]["name"], "Тестовый лес")
	check(int(all[0]["last_played"]) > 0, "marked as played")


func test_load_a_world_and_host_it() -> void:
	var id := app.worlds.create("Сервер", {})
	ServerWorld.open(app.worlds.db_path(id), app.content, {"seed": 1}).close()
	app.settings.set_value("server_port", 25400 + randi() % 400)
	_press("Загрузить игру")
	_press("Запустить сервер и играть")
	check(app.game != null and app.game.hosted != null, "hosting")
	_play(200)
	eq(app.game.client.state, "playing", "the host plays through its own server")
	app.game.menu_requested.emit()
	check(not app.game.paused or app.game.hosted != null, "")
	_press("Выход в главное меню")
	check(app.game == null, "closed")


func test_create_and_switch_characters() -> void:
	_press("Персонажи")
	_press("Создать нового")
	var name_edit: LineEdit = app.menu.find_children("*", "LineEdit", true, false)[0]
	name_edit.text = "Мара"
	_press("Создать")
	var made := app.characters.load_character(String(app.settings.get_value("character")))
	check(made != null and made.name == "Мара", "the new character is the current one")
	_press("Сменить персонажа")
	var others := app.characters.list().filter(func(c: Dictionary) -> bool: return c["name"] != "Мара")
	check(others.size() == 1, "the default one is there too")
	_press("%s — %s" % [others[0]["name"], MainMenu.HAIR[others[0]["hair"]]])
	eq(app.settings.get_value("character"), others[0]["file"], "switched")
	eq(GameSettings.load_from(app.settings.path).get_value("character"), others[0]["file"], "and kept")


func test_a_refused_start_is_told_on_the_start_screen() -> void:
	var blocker := ENetTransport.new()
	var port := 25900 + randi() % 50
	blocker.start_server(port, 1)
	app.settings.set_value("server_port", port)
	_press("Новая игра")
	_press("Создать сервер и играть")
	expect_errors(1)
	_press("Создать и играть")
	check(app.game == null, "no game")
	var said := false
	for l: Label in app.menu.find_children("*", "Label", true, false):
		said = said or l.text.contains(str(port))
	check(said, "the busy port is told")
	blocker.close()
