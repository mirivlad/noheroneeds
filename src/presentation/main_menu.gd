class_name MainMenu
extends Control
## The game's menu: the start screen, and the same menu over a running game
## (Esc), where "Exit" becomes "Exit to the start screen". Screens:
##   start: new game, load game, connect, characters, settings, exit;
##   new game: locally or as a server, then the new world's rules;
##   load game: the saved worlds, each to play locally or to host;
##   connect: a server's address;
##   characters: the current one, switch, create;
##   settings.
## The menu does the choosing; App starts and ends games (signals).

signal play(cfg: Dictionary)
signal resume
signal to_start_screen
signal quit_game
signal settings_changed

const HAIR := {"base:hair_short": "Короткая стрижка", "base:hair_long": "Длинные волосы", "base:hair_braid": "Коса"}

var worlds: WorldLibrary
var characters: CharacterLibrary
var settings: GameSettings
var content: ContentRegistry
## Over a running game: "Continue" and "Exit to the start screen".
var in_game := false

var _panel := PanelContainer.new()
var _body := VBoxContainer.new()
## Where the helpers put what they make (the body, or a column of it).
var _into: Container
var _message := ""
var _preview: Control


func _init(world_lib: WorldLibrary, char_lib: CharacterLibrary, player_settings: GameSettings,
		registry: ContentRegistry, over_game: bool) -> void:
	worlds = world_lib
	characters = char_lib
	settings = player_settings
	content = registry
	in_game = over_game
	theme = Art.theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.06, 0.04, 0.07, 0.55 if over_game else 0.0)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel.custom_minimum_size = Vector2(240, 0)
	center.add_child(_panel)
	_body.add_theme_constant_override("separation", 3)
	_panel.add_child(_body)
	_into = _body
	show_start()


## Something to tell on the start screen (a refused connection...).
func tell(text: String) -> void:
	_message = text
	show_start()


func _unhandled_input(event: InputEvent) -> void:
	if in_game and event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		resume.emit()


# --- screens -----------------------------------------------------------------

func show_start() -> void:
	_clear("" if in_game else "Герой не требуется")
	if not in_game:
		_label("No Hero Needed", Art.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
		_gap()
	if in_game:
		_button("Продолжить", func() -> void: resume.emit())
	_button("Новая игра", show_new_game)
	_button("Загрузить игру", show_load)
	_button("Подключиться к серверу", show_connect)
	_button("Персонажи", show_characters)
	_button("Настройки", show_settings)
	if in_game:
		_button("Выход в главное меню", func() -> void: to_start_screen.emit())
	else:
		_button("Выход", func() -> void: quit_game.emit())
	var c := characters.load_character(_current_character())
	_gap()
	_label("Персонаж: " + (c.name if c else "—"), Art.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	if _message != "":
		_label(_message, Color("e8907a"), HORIZONTAL_ALIGNMENT_CENTER, true)
		_message = ""


func show_new_game() -> void:
	_clear("Новая игра")
	_button("Локально", func() -> void: show_world_form("local"))
	_button("Создать сервер и играть", func() -> void: show_world_form("host"))
	_gap()
	_button("Назад", show_start)


## The new world's rules (and, for a server, its port and size).
func show_world_form(mode: String) -> void:
	_clear("Новый мир" if mode == "local" else "Новый мир на сервере")
	var name_edit := _field("Название", LineEdit.new()) as LineEdit
	name_edit.text = "Новый мир"
	name_edit.max_length = 40
	var seed_edit := _field("Сид", LineEdit.new()) as LineEdit
	seed_edit.placeholder_text = "случайный"
	seed_edit.max_length = 24
	seed_edit.tooltip_text = "Одинаковый сид — одинаковая местность. Число или слово."
	var levels := _spin("Этажей не выше", 1, 20, WorldLibrary.RULES["max_levels"])
	levels.tooltip_text = "Сколько этажей можно надстроить (правило мира)"
	var day := _spin("Сутки длятся, мин", 2, 600, WorldLibrary.RULES["day_minutes"])
	day.tooltip_text = "Сколько реальных минут длятся игровые сутки (правило мира)"
	var kit := _check("Стартовые материалы", true)
	kit.tooltip_text = "Доски, камень и брёвна каждому новому персонажу"
	var outfit := _check("Стартовая одежда", true)
	var port: SpinBox
	var players: SpinBox
	if mode == "host":
		port = _spin("Порт", 1024, 65535, int(settings.get_value("server_port")))
		players = _spin("Игроков не больше", 1, 64, int(settings.get_value("max_players")))
	_gap()
	_button("Создать и играть", func() -> void:
		var rules := {"seed": seed_edit.text.strip_edges(), "max_levels": int(levels.value), "day_minutes": int(day.value),
			"starter_kit": kit.button_pressed, "starter_outfit": outfit.button_pressed}
		var id := worlds.create(name_edit.text, rules)
		_start_world(id, mode, int(port.value) if port else 0, int(players.value) if players else 0))
	_button("Назад", show_new_game)
	name_edit.grab_focus()
	name_edit.select_all()


## Dev pictures (--menu=world_form_host).
func show_world_form_host() -> void:
	show_world_form("host")


func show_load() -> void:
	_clear("Загрузить игру")
	var all := worlds.list()
	if all.is_empty():
		_label("Сохранённых миров нет", Art.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(300, mini(all.size(), 6) * 22)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	if not all.is_empty():
		_body.add_child(scroll)
	for w: Dictionary in all:
		var row := HBoxContainer.new()
		var text := Label.new()
		text.text = String(w["name"])
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.clip_text = true
		text.tooltip_text = "Этажей не выше %d · %s" % [w["max_levels"], _when(int(w["last_played"]))]
		text.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(text)
		var when := Label.new()
		when.text = _when(int(w["last_played"]))
		when.add_theme_color_override("font_color", Art.TEXT_DIM)
		row.add_child(when)
		var id: String = w["id"]
		row.add_child(_icon_button("play", "Играть локально", func() -> void: _start_world(id, "local")))
		row.add_child(_icon_button("server", "Запустить сервер и играть", func() -> void: _start_world(id, "host")))
		rows.add_child(row)
	_gap()
	_button("Назад", show_start)


func show_connect() -> void:
	_clear("Подключиться к серверу")
	var addr := _field("Адрес", LineEdit.new()) as LineEdit
	addr.text = String(settings.get_value("last_address"))
	addr.placeholder_text = "адрес:порт"
	_label("Например 192.168.1.5:24680", Art.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_gap()
	var go := func() -> void:
		var hp := addr.text.strip_edges().rsplit(":", true, 1)
		var host := hp[0] if hp[0] != "" else "127.0.0.1"
		var port := int(hp[1]) if hp.size() > 1 and hp[1].is_valid_int() else int(settings.get_value("server_port"))
		settings.set_value("last_address", "%s:%d" % [host, port])
		settings.save()
		play.emit({"mode": "connect", "address": host, "port": port})
	addr.text_submitted.connect(func(_t: String) -> void: go.call())
	_button("Подключиться", go)
	_button("Назад", show_start)
	addr.grab_focus()


func show_characters() -> void:
	_clear("Персонажи")
	var current := _current_character()
	var c := characters.load_character(current)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(_doll(String(c.styles.get("hair", "")) if c else ""))
	var about := VBoxContainer.new()
	about.alignment = BoxContainer.ALIGNMENT_CENTER
	var nm := Label.new()
	nm.text = c.name if c else "—"
	about.add_child(nm)
	var hair := Label.new()
	hair.text = HAIR.get(String(c.styles.get("hair", "")), "") if c else ""
	hair.add_theme_color_override("font_color", Art.TEXT_DIM)
	about.add_child(hair)
	row.add_child(about)
	_body.add_child(row)
	if in_game:
		_label("Смена персонажа — со следующего входа в мир", Art.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, true)
	_button("Сменить персонажа", show_character_list)
	_button("Создать нового", show_character_create)
	_gap()
	_button("Назад", show_start)


func show_character_list() -> void:
	_clear("Сменить персонажа")
	var current := _current_character()
	for c: Dictionary in characters.list():
		var file: String = c["file"]
		var label := "%s — %s" % [c["name"], HAIR.get(String(c["hair"]), "")]
		var b := _button(label + ("  (сейчас)" if file == current else ""), func() -> void:
			settings.set_value("character", file)
			settings.save()
			show_characters())
		b.disabled = file == current
	_gap()
	_button("Назад", show_characters)


func show_character_create() -> void:
	_clear("Новый персонаж")
	var hairs := HAIR.keys()
	var chosen := [hairs[0]]
	var doll_box := CenterContainer.new()
	_body.add_child(doll_box)
	doll_box.add_child(_doll(chosen[0]))
	var name_edit := _field("Имя", LineEdit.new()) as LineEdit
	name_edit.placeholder_text = "Путник"
	name_edit.max_length = PortableCharacter.NAME_MAX
	var pick := OptionButton.new()
	for h: String in hairs:
		pick.add_item(HAIR[h])
	_field("Причёска", pick)
	pick.item_selected.connect(func(i: int) -> void:
		chosen[0] = hairs[i]
		for old: Node in doll_box.get_children():
			old.queue_free()
		doll_box.add_child(_doll(chosen[0])))
	_gap()
	_button("Создать", func() -> void:
		var file := characters.create(name_edit.text, {"hair": chosen[0]})
		if file == "":
			_message = "не удалось создать: " + characters.last_error
			show_start()
			return
		settings.set_value("character", file)
		settings.save()
		show_characters())
	_button("Назад", show_characters)
	name_edit.grab_focus()


func show_settings() -> void:
	_clear("Настройки")
	var changed := func(key: String, value: Variant) -> void:
		settings.set_value(key, value)
		settings.save()
		settings.apply()
		settings_changed.emit()
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 12)
	_body.add_child(columns)
	var left := VBoxContainer.new()
	var right := VBoxContainer.new()
	columns.add_child(left)
	columns.add_child(right)
	_into = left
	_label("Экран", Art.TEXT_DIM)
	_check("Во весь экран", settings.get_value("fullscreen")).toggled.connect(
		func(on: bool) -> void: changed.call("fullscreen", on))
	_check("Вертикальная синхронизация", settings.get_value("vsync")).toggled.connect(
		func(on: bool) -> void: changed.call("vsync", on))
	var zoom := OptionButton.new()
	zoom.add_item("Обычный")
	zoom.add_item("Дальний")
	zoom.selected = 1 if float(settings.get_value("view_zoom")) < 0.9 else 0
	zoom.tooltip_text = "Дальний вид показывает больше мира теми же пикселями"
	_field("Вид", zoom)
	zoom.item_selected.connect(func(i: int) -> void: changed.call("view_zoom", 0.75 if i == 1 else 1.0))
	_label("Звук", Art.TEXT_DIM)
	for pair: Array in [["volume", "Общая"], ["music_volume", "Музыка"], ["effects_volume", "Эффекты"],
			["ambience_volume", "Окружение"]]:
		var key: String = pair[0]
		var vol := HSlider.new()
		vol.min_value = 0.0
		vol.max_value = 1.0
		vol.step = 0.05
		vol.value = float(settings.get_value(key))
		vol.custom_minimum_size = Vector2(100, 12)
		_field(pair[1], vol)
		vol.value_changed.connect(func(v: float) -> void: changed.call(key, v))
	_into = right
	_label("Игра", Art.TEXT_DIM)
	_check("Подсказки управления", settings.get_value("show_hints")).toggled.connect(
		func(on: bool) -> void: changed.call("show_hints", on))
	_check("Показывать частоту кадров", settings.get_value("show_fps")).toggled.connect(
		func(on: bool) -> void: changed.call("show_fps", on))
	_label("Свой сервер", Art.TEXT_DIM)
	_spin("Порт", 1024, 65535, int(settings.get_value("server_port"))).value_changed.connect(
		func(v: float) -> void: changed.call("server_port", int(v)))
	_spin("Игроков не больше", 1, 64, int(settings.get_value("max_players"))).value_changed.connect(
		func(v: float) -> void: changed.call("max_players", int(v)))
	_into = _body
	_gap()
	_button("Назад", show_start)


# --- helpers -----------------------------------------------------------------

func _start_world(id: String, mode: String, port := 0, players := 0) -> void:
	var cfg := {"mode": mode, "world": id, "world_path": worlds.db_path(id), "rules": worlds.read_meta_only(id)}
	if mode == "host":
		cfg["port"] = port if port > 0 else int(settings.get_value("server_port"))
		cfg["max_players"] = players if players > 0 else int(settings.get_value("max_players"))
	play.emit(cfg)


var _click_player := AudioStreamPlayer.new()


func _click() -> void:
	var d := content.sound_of("ui", "click")
	if d.is_empty():
		return
	if _click_player.get_parent() == null:
		_click_player.bus = &"Effects"
		add_child(_click_player)
	_click_player.stream = Art.audio(String((d["paths"] as PackedStringArray)[0]))
	_click_player.volume_db = float(d["volume_db"])
	_click_player.play()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_click_player) and _click_player.get_parent() == null:
		_click_player.free()


func _current_character() -> String:
	return characters.current(String(settings.get_value("character")))


func _clear(title: String) -> void:
	_into = _body
	for c: Node in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	if title != "":
		var t := Label.new()
		t.text = title
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		t.add_theme_font_size_override("font_size", 32 if title == "Герой не требуется" else 24)
		t.add_theme_color_override("font_color", Art.TEXT_HOT)
		_body.add_child(t)


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(_click)
	b.pressed.connect(action)
	_into.add_child(b)
	return b


func _icon_button(kind: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.icon = Art.icon(kind)
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(20, 18)
	b.pressed.connect(_click)
	b.pressed.connect(action)
	return b


func _label(text: String, color := Art.TEXT, align := HORIZONTAL_ALIGNMENT_LEFT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(230, 0)
	_into.add_child(l)
	return l


func _gap() -> void:
	var g := Control.new()
	g.custom_minimum_size = Vector2(0, 4)
	_into.add_child(g)


## A row: a label on the left, the control on the right.
func _field(text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	control.custom_minimum_size.x = maxf(control.custom_minimum_size.x, 100)
	row.add_child(control)
	_into.add_child(row)
	return control


func _spin(text: String, lo: int, hi: int, value: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = value
	s.rounded = true
	return _field(text, s) as SpinBox


func _check(text: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	_into.add_child(c)
	return c


## A turning paper doll with a hairstyle and the starter outfit.
func _doll(hair: String) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(48, 48)
	var body := content.visual_of("base:humanoid_adult")
	if body.is_empty():
		return box
	var layers := []
	var hv := content.visual_of(hair)
	if hv.get("mode") == "layer":
		layers.append([String(hv["layer"]), Art.texture(hv["atlas_path"])])
	for item: String in WorldLibrary.STARTER_OUTFIT.values():
		var worn: Dictionary = content.visual_of(item).get("worn", {})
		if not worn.is_empty():
			layers.append([String(worn["layer"]), Art.texture(worn["atlas_path"])])
	var doll := CharacterSprite.new(Art.texture(body["atlas_path"]), body, layers)
	doll.position = Vector2(24, 46)
	box.add_child(doll)
	var turn := Timer.new()
	turn.wait_time = 1.2
	turn.autostart = true
	var angle := [0]
	turn.timeout.connect(func() -> void:
		angle[0] = (angle[0] + 1) % 8
		var a := float(angle[0]) * PI / 4.0 + PI / 2.0
		doll.turn_to(Vector2(cos(a), sin(a))))
	box.add_child(turn)
	return box


static func _when(unix: int) -> String:
	if unix <= 0:
		return "не начат"
	var d := Time.get_datetime_dict_from_unix_time(unix + int(Time.get_time_zone_from_system()["bias"]) * 60)
	return "%02d.%02d.%04d %02d:%02d" % [d["day"], d["month"], d["year"], d["hour"], d["minute"]]
