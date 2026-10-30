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
	ServerWorld.open(app.worlds.db_path(id), app.content, {"seed": 1, "require_planned": true}).close()
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
	var name_edit: LineEdit = app.menu.find_child("CharacterName", true, false)
	name_edit.text = "Мара"
	_press("Создать")
	var made := app.characters.load_character(String(app.settings.get_value("character")))
	check(made != null and made.name == "Мара", "the new character is the current one")
	_press("Сменить персонажа")
	var others := app.characters.list().filter(func(c: Dictionary) -> bool: return c["name"] != "Мара")
	check(others.size() == 1, "the default one is there too")
	_press("%s — %s" % [others[0]["name"], MainMenu._look_name(others[0]["body_plan"], others[0]["hair"])])
	eq(app.settings.get_value("character"), others[0]["file"], "switched")
	eq(GameSettings.load_from(app.settings.path).get_value("character"), others[0]["file"], "and kept")


func test_editor_choices_save_and_equipment_window_uses_inventory() -> void:
	_press("Персонажи")
	_press("Создать нового")
	var editor: CharacterEditor = app.menu.find_children("*", "VBoxContainer", true, false).filter(
		func(n: Node) -> bool: return n is CharacterEditor)[0]
	editor.name_edit.text = "Ева"
	editor.sex_pick.select(1)
	editor.face_pick.select(2)
	editor.hair_pick.select(4)
	editor.skin_pick.select(4)
	editor.color_pick.select(3)
	_press("Создать")
	var file := String(app.settings.get_value("character"))
	var c := app.characters.load_character(file)
	eq(c.body_plan, "base:human_f")
	eq(c.styles["face"], "base:human_face_angular")
	eq(c.styles["hair"], "base:human_hair_braid")
	eq(c.colors["skin"], "#76513a")
	_press("Редактировать внешность")
	_press("Сохранить")
	eq(app.characters.load_character(file).character_id, c.character_id)
	app.start_game({"mode":"local", "world":"equipment", "world_path":app.worlds.db_path("equipment"), "rules":{"seed":"1"}})
	_play(100)
	app.game._key(KEY_C, false)
	check(app.game.character_panel.visible, "C opens the equipment window")
	var slot: CharacterPanel.EquipmentSlot = app.game.character_panel._slots["headwear"]
	check(slot._can_drop_data(Vector2.ZERO, {"item":"base:felt_hat"}), "hat accepted on the head")
	check(not slot._can_drop_data(Vector2.ZERO, {"item":"base:boots"}), "boots refused on the head")
	slot._drop_data(Vector2.ZERO, {"item":"base:felt_hat"})
	for i in 20:
		app.game._process(0.05)
	eq(app.game.client.own["appearance"]["worn"].get("headwear"), "base:felt_hat", "drag equips through the server")
	slot.pressed.emit()
	for i in 20:
		app.game._process(0.05)
	check(not app.game.client.own["appearance"]["worn"].has("headwear"), "click returns it to inventory")
	eq(app.game.client.inventory().get("base:felt_hat"), 1)
	app.game.menu_requested.emit()
	app.menu.show_characters()
	check(not _has_button("Редактировать внешность"), "appearance editing is absent while in a world")


func _has_button(text: String) -> bool:
	for b: Button in app.menu.find_children("*", "Button", true, false):
		if not b.is_queued_for_deletion() and b.text == text:
			return true
	return false


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


func test_world_preview_is_the_plan_written_to_the_database() -> void:
	_press("Новая игра")
	_press("Локально")
	var menu := app.menu
	var preview: WorldPreview = menu.find_children("*", "Control", true, false).filter(func(n: Node) -> bool: return n is WorldPreview)[0]
	var picks: Array[Node] = menu.find_children("*", "OptionButton", true, false)
	picks[0].select(1)
	picks[0].item_selected.emit(1)
	picks[1].select(2)
	picks[1].item_selected.emit(2)
	_press("Создать предпросмотр")
	var expected := preview.plan.to_dict()
	check(preview.globe != null, "a planet is rendered as a sphere")
	var before := preview.globe.rotation.y
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	preview._gui_input(press)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(20, 0)
	preview._gui_input(drag)
	check(preview.globe.rotation.y != before, "drag rotates the sphere")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	for i in 20:
		preview._gui_input(wheel)
	eq(preview.distance, 2.8, "zoom has a near limit")
	_press("Создать и играть")
	_play(100)
	check(app.game != null and app.game.game != null, "the planned world starts")
	if app.game and app.game.game:
		var actual := (app.game.game.world.generator.geography as PlannedGeography).plan
		eq(actual.to_dict(), expected, "the database-backed world is exactly the displayed plan")
		check(app.game.client.geography is PlannedGeography, "the client receives the plan")
