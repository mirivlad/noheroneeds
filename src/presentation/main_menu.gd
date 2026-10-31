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


var worlds: WorldLibrary
var characters: CharacterLibrary
var settings: GameSettings
var content: ContentRegistry
## Over a running game: "Continue" and "Exit to the start screen".
var in_game := false
## Over a world one hosts (ADR-0060): the link to it, and a new one (the old voided).
var share := Callable()
var renew := Callable()

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
	if in_game and share.is_valid():
		_button("Поделиться ссылкой", func() -> void: _give_link(share.call()))
		_button("Новая ссылка", func() -> void: _give_link(renew.call(), true))
	_button("Новая игра", show_new_game)
	_button("Загрузить игру", show_load)
	_button("Подключиться к серверу", show_connect)
	_button("Персонажи", show_characters)
	_button("Настройки", show_settings)
	if not in_game:
		_button("Авторы", show_credits)
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
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 16)
	_body.add_child(columns)
	var fields := VBoxContainer.new()
	fields.custom_minimum_size.x = 300
	fields.add_theme_constant_override("separation", 3)
	columns.add_child(fields)
	_into = fields
	var name_edit := _field("Название", LineEdit.new()) as LineEdit
	name_edit.text = "Новый мир"
	name_edit.max_length = 40
	var seed_edit := _field("Сид", LineEdit.new()) as LineEdit
	seed_edit.text = str(randi())
	seed_edit.max_length = 24
	seed_edit.tooltip_text = "Одинаковый сид — одинаковая местность. Число или слово."
	var random_seed := Button.new()
	random_seed.text = "↻"
	random_seed.tooltip_text = "Случайный сид"
	seed_edit.get_parent().add_child(random_seed)
	random_seed.pressed.connect(func() -> void: seed_edit.text = str(randi()); seed_edit.text_changed.emit(seed_edit.text))
	var size_pick := OptionButton.new()
	for label: String in ["Один континент", "Небольшая планета", "Средняя планета", "Большая планета", "Огромная планета"]:
		size_pick.add_item(label)
	_field("Размер", size_pick)
	var climate_pick := OptionButton.new()
	for label: String in ["Жаркий", "Умеренный", "Холодный"]:
		climate_pick.add_item(label)
	climate_pick.select(1)
	_field("Климат", climate_pick)
	var levels := _spin("Этажей не выше", 1, 20, WorldLibrary.RULES["max_levels"])
	levels.tooltip_text = "Сколько этажей можно надстроить (правило мира)"
	var day := _spin("Сутки длятся, мин", 2, 600, WorldLibrary.RULES["day_minutes"])
	day.tooltip_text = "Сколько реальных минут длятся игровые сутки (правило мира)"
	var kit := _check("Стартовые материалы", true)
	kit.tooltip_text = "Доски, камень и брёвна каждому новому персонажу"
	var outfit := _check("Стартовая одежда", true)
	var known := _check("Все рецепты известны", false)
	known.tooltip_text = "Каждый знает каждый рецепт сразу: без учёбы у мастеров и чертежей"
	var sure := _check("Ремесло не ошибается", false)
	sure.tooltip_text = "Попытки сделать вещь всегда удаются; качество всё равно растёт с мастерством"
	var port: SpinBox
	var players: SpinBox
	var password: LineEdit
	if mode == "host":
		port = _spin("Порт", 1024, 65535, int(settings.get_value("server_port")))
		players = _spin("Игроков не больше", 1, 64, int(settings.get_value("max_players")))
		password = _field("Пароль", LineEdit.new()) as LineEdit
		password.secret = true
		password.text = String(settings.get_value("server_password"))
		password.placeholder_text = "без пароля — открыт всем"
		password.tooltip_text = "Войдут только знающие пароль или получившие ссылку на мир («Поделиться ссылкой» в меню игры)"
	_gap()
	var preview_column := VBoxContainer.new()
	preview_column.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_child(preview_column)
	var preview := WorldPreview.new()
	preview_column.add_child(preview)
	var caption := Label.new()
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_column.add_child(caption)
	var regenerate := Button.new()
	regenerate.text = "Создать предпросмотр"
	preview_column.add_child(regenerate)
	var state := {"plan": null, "valid": false}
	var create_button := _button("Создать и играть", func() -> void:
		if not state["valid"]:
			return
		var rules := {"seed": seed_edit.text.strip_edges(), "world_plan": (state["plan"] as WorldPlan).to_dict(), "max_levels": int(levels.value), "day_minutes": int(day.value),
			"starter_kit": kit.button_pressed, "starter_outfit": outfit.button_pressed,
			"all_recipes_known": known.button_pressed, "crafts_never_fail": sure.button_pressed}
		var id := worlds.create(name_edit.text, rules)
		if password:
			settings.set_value("server_password", password.text)
			settings.save()
		_start_world(id, mode, int(port.value) if port else 0, int(players.value) if players else 0))
	_button("Назад", show_new_game)
	var invalidate := func() -> void:
		state["valid"] = false
		create_button.disabled = true
		caption.text = "Настройки изменены — создайте предпросмотр"
	seed_edit.text_changed.connect(func(_text: String) -> void: invalidate.call())
	size_pick.item_selected.connect(func(_i: int) -> void: invalidate.call())
	climate_pick.item_selected.connect(func(_i: int) -> void: invalidate.call())
	regenerate.pressed.connect(func() -> void:
		if seed_edit.text.strip_edges() == "":
			seed_edit.text = str(randi())
		var seed_number := WorldLibrary.seed_of({"seed": seed_edit.text})
		var presets := ["single_continent", "small", "medium", "large", "huge"]
		var climates := ["hot", "temperate", "cold"]
		state["plan"] = WorldPlan.generate(seed_number, presets[size_pick.selected], climates[climate_pick.selected], content)
		state["valid"] = state["plan"] != null
		create_button.disabled = not state["valid"]
		if state["valid"]:
			preview.show_plan(state["plan"])
			var hint := "Перетащите, чтобы вращать; колесо — масштаб" if size_pick.selected != 0 else "За краем карты — океан без конца"
			caption.text = WorldPreview.describe(state["plan"]) + "\n" + hint)
	regenerate.pressed.emit()
	_into = _body
	name_edit.grab_focus()
	name_edit.select_all()


## The link to the world one hosts, copied for pasting to friends.
func _give_link(link: String, fresh := false) -> void:
	DisplayServer.clipboard_set(link)
	_message = ("Новая ссылка (старая больше не пускает) скопирована:\n" if fresh else "Ссылка скопирована:\n") + link
	show_start()


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
		text.tooltip_text = "Этажей не выше %d, %s" % [w["max_levels"], _when(int(w["last_played"]))]
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
	var addr := _field("Имя сервера или ссылка на подключение", LineEdit.new()) as LineEdit
	addr.name = "ServerAddress"
	addr.text = String(settings.get_value("last_address"))
	addr.placeholder_text = "адрес:порт или nhn://…"
	addr.custom_minimum_size.x = 200
	var password := _field("Пароль (если нужен)", LineEdit.new()) as LineEdit
	password.name = "ServerPassword"
	password.secret = true
	_label("Например 192.168.1.5:24680 или ссылка, которой поделился хозяин мира", Art.TEXT_DIM,
		HORIZONTAL_ALIGNMENT_CENTER, true)
	_gap()
	var go := func() -> void:
		var cfg := {"mode": "connect", "password": password.text}
		var link := HostedGame.parse_link(addr.text)
		if not link.is_empty():  # a share link: where, and the invite instead of the password
			cfg.merge(link, true)
		else:
			var hp := addr.text.strip_edges().rsplit(":", true, 1)
			cfg["address"] = hp[0] if hp[0] != "" else "127.0.0.1"
			cfg["port"] = int(hp[1]) if hp.size() > 1 and hp[1].is_valid_int() else int(settings.get_value("server_port"))
		settings.set_value("last_address", "%s:%d" % [cfg["address"], cfg["port"]])
		settings.save()
		play.emit(cfg)
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
	row.add_child(_doll(c.body_plan if c else "base:human_m", String(c.styles.get("hair", "")) if c else "", c.styles if c else {}, c.colors if c else {}))
	var about := VBoxContainer.new()
	about.alignment = BoxContainer.ALIGNMENT_CENTER
	var nm := Label.new()
	nm.text = c.name if c else "—"
	about.add_child(nm)
	var hair := Label.new()
	hair.text = _look_name(c.body_plan, String(c.styles.get("hair", ""))) if c else ""
	hair.add_theme_color_override("font_color", Art.TEXT_DIM)
	about.add_child(hair)
	row.add_child(about)
	_body.add_child(row)
	if in_game:
		_label("Смена персонажа — со следующего входа в мир", Art.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, true)
	_button("Сменить персонажа", show_character_list)
	if not in_game:
		_button("Создать нового", show_character_create)
		_button("Редактировать внешность", func() -> void: show_character_edit(current))
	_gap()
	_button("Назад", show_start)


func show_character_list() -> void:
	_clear("Сменить персонажа")
	var current := _current_character()
	for c: Dictionary in characters.list():
		var file: String = c["file"]
		var label := "%s — %s" % [c["name"], _look_name(c["body_plan"], c["hair"])]
		var b := _button(label + ("  (сейчас)" if file == current else ""), func() -> void:
			settings.set_value("character", file)
			settings.save()
			show_characters())
		b.disabled = file == current
	_gap()
	_button("Назад", show_characters)


func show_character_create() -> void:
	show_character_edit("")


func show_character_edit(file_id: String) -> void:
	if in_game:
		return
	_clear("Редактор персонажа" if file_id != "" else "Новый персонаж")
	var editor := CharacterEditor.new()
	_body.add_child(editor)
	editor.setup(content, characters.load_character(file_id) if file_id != "" else null)
	editor.cancelled.connect(show_characters)
	editor.accepted.connect(func(char_name: String, plan: String, styles: Dictionary, colors: Dictionary) -> void:
		var file := file_id
		if file == "":
			file = characters.create(char_name, styles, colors, plan)
		elif not characters.edit(file, char_name, plan, styles, colors):
			file = ""
		if file == "":
			_message = "Не удалось сохранить: " + characters.last_error
			show_start()
			return
		settings.set_value("character", file)
		settings.save()
		show_characters())


## Who made the game, under which licence; where its pictures come from and
## under what terms (the whole list of their authors: CREDITS-art.md, written
## by tools/art/import_lpc*.py, shipped with the game).
const CREDITS := "res://CREDITS-art.md"
const LPC_URL := "https://lpc.opengameart.org"
const OGA_URL := "https://opengameart.org"
const ULPC_URL := "https://github.com/LiberatedPixelCup/Universal-LPC-Spritesheet-Character-Generator"
const GPL_URL := "https://www.gnu.org/licenses/gpl-3.0.html"
const REPO_URL := "https://github.com/mirivlad/noheroneeds"


func show_credits() -> void:
	_clear("Авторы")
	var text := _rich(560, 300)
	text.name = "CreditsText"
	var version := String(ProjectSettings.get_setting("application/config/version", ""))
	text.text = "\n".join([
		"[color=#%s]No Hero Needed — «Герой не требуется»[/color]  %s" % [Art.TEXT_HOT.to_html(false), version],
		"[url=%s]%s[/url]" % [REPO_URL, REPO_URL],
		"",
		"[color=#%s]Авторы игры[/color]" % Art.TEXT_HOT.to_html(false),
		"mirivlad — автор: замысел, решения, музыка",
		"Claude (Anthropic) — соавтор: код, инструменты, сборка графики",
		"",
		"[color=#%s]Лицензия[/color]" % Art.TEXT_HOT.to_html(false),
		"Игра — свободная программа по лицензии [url=%s]GNU GPL версии 3[/url] (или более поздней): её можно запускать, изучать, менять и распространять на её условиях. Текст лицензии — в файле LICENSE рядом с игрой." % GPL_URL,
		"",
		"[color=#%s]Графика[/color]" % Art.TEXT_HOT.to_html(false),
		"Почти всё нарисовано участниками [url=%s]Liberated Pixel Cup (LPC)[/url] и авторами других свободных наборов на [url=%s]OpenGameArt[/url]; персонажи собраны из [url=%s]Universal LPC Spritesheet Generator[/url]. Каждая работа взята под лицензией, которую указали её авторы (CC-BY-SA, CC-BY, OGA-BY, GPL, CC0). Кто нарисовал что и под какой лицензией — «Полный список» ниже и файл CREDITS-art.md рядом с игрой." % [LPC_URL, OGA_URL, ULPC_URL],
		"",
		"[color=#%s]Шрифт, звуки, музыка[/color]" % Art.TEXT_HOT.to_html(false),
		"Шрифт Monogram Extended — datagoblin, CC0. Звуки синтезированы для игры. Музыка — mirivlad.",
	])
	_button("Полный список авторов графики", show_art_credits)
	_button("Назад", show_start)


## Every borrowed picture's authors and licences (CREDITS-art.md).
func show_art_credits() -> void:
	_clear("Авторы графики")
	var text := _rich(560, 300)
	text.name = "ArtCreditsText"
	var lines := PackedStringArray()
	for line: String in FileAccess.get_file_as_string(CREDITS).split("\n"):
		lines.append(line.trim_prefix("## ").trim_prefix("# ").replace("`", "").replace("[", "[lb]"))
	text.text = "\n".join(lines).strip_edges()
	_button("Назад", show_credits)


## A scrolling text with links that open in the browser.
func _rich(width: float, height: float) -> RichTextLabel:
	var t := RichTextLabel.new()
	t.bbcode_enabled = true
	t.scroll_active = true
	t.custom_minimum_size = Vector2(width, height)
	t.add_theme_font_override("normal_font", Art.font())
	t.add_theme_font_size_override("normal_font_size", 16)
	t.add_theme_color_override("default_color", Art.TEXT)
	t.meta_underlined = true
	t.meta_clicked.connect(func(meta: Variant) -> void: OS.shell_open(String(meta)))
	_into.add_child(t)
	return t


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
	_check("Ходить клавишами (W A S D)", settings.get_value("keyboard_walk")).toggled.connect(
		func(on: bool) -> void: changed.call("keyboard_walk", on))
	var auto := _check("Автоудары", settings.get_value("auto_attack"))
	auto.tooltip_text = "Щелчок по противнику — бить, пока цель не сменится (без этого — один удар; Ctrl+щелчок — всегда до конца)"
	auto.toggled.connect(func(on: bool) -> void: changed.call("auto_attack", on))
	_label("Свой сервер", Art.TEXT_DIM)
	_spin("Порт", 1024, 65535, int(settings.get_value("server_port"))).value_changed.connect(
		func(v: float) -> void: changed.call("server_port", int(v)))
	_spin("Игроков не больше", 1, 64, int(settings.get_value("max_players"))).value_changed.connect(
		func(v: float) -> void: changed.call("max_players", int(v)))
	# The keys (UI 2.0, KeyMap): a click on one, then the new key; Esc leaves it.
	var keys := VBoxContainer.new()
	columns.add_child(keys)
	_into = keys
	_label("Клавиши", Art.TEXT_DIM)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("v_separation", 1)
	keys.add_child(grid)
	for a: Array in KeyMap.ACTIONS:
		var what := Label.new()
		what.text = String(a[1])
		grid.add_child(what)
		var b := Button.new()
		b.name = "Key_" + String(a[0])
		b.text = KeyMap.key_name(KeyMap.key(settings, String(a[0])))
		b.custom_minimum_size = Vector2(72, 0)
		b.tooltip_text = "Щёлкните и нажмите новую клавишу (Esc — оставить)"
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func() -> void:
			rebinding = String(a[0])
			b.text = "…")
		grid.add_child(b)
	var reset := Button.new()
	reset.text = "Клавиши как было"
	reset.pressed.connect(func() -> void:
		settings.set_value("keys", {})
		_keys_changed())
	keys.add_child(reset)
	_into = _body
	_gap()
	_button("Назад", show_start)


## The action whose key is being set (the next key pressed), "" — none.
var rebinding := ""


func _input(event: InputEvent) -> void:
	if rebinding == "" or not (event is InputEventKey) or not event.pressed or (event as InputEventKey).echo:
		return
	get_viewport().set_input_as_handled()
	var e := event as InputEventKey
	var k := e.physical_keycode if e.physical_keycode != KEY_NONE else e.keycode
	if k != KEY_ESCAPE:
		KeyMap.bind(settings, rebinding, k)
	rebinding = ""
	_keys_changed()


func _keys_changed() -> void:
	settings.save()
	settings.apply()
	settings_changed.emit()
	show_settings()


# --- helpers -----------------------------------------------------------------

func _start_world(id: String, mode: String, port := 0, players := 0) -> void:
	var cfg := {"mode": mode, "world": id, "world_path": worlds.db_path(id), "rules": worlds.read_meta_only(id)}
	if mode == "host":
		cfg["port"] = port if port > 0 else int(settings.get_value("server_port"))
		cfg["max_players"] = players if players > 0 else int(settings.get_value("max_players"))
		cfg["password"] = String(settings.get_value("server_password"))
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


## A character's looks in a few words: the body and the hairstyle.
static func _look_name(body: String, hair: String) -> String:
	var sex := "женщина" if body.begins_with("base:human_f") or body == "base:human_ro_f" else "мужчина"
	var style := String(CharacterEditor.HAIRS.get(hair, CharacterEditor.RO_HAIRS.get(hair, ""))).to_lower()
	return sex + (", причёска: " + style if style != "" else "")


## A turning paper doll with a hairstyle and the starter outfit.
func _doll(body_plan: String, hair: String, styles: Dictionary = {}, colors: Dictionary = {}) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(48, 48)
	var body := content.visual_of(body_plan)
	if body.is_empty():
		return box
	var look := {"styles": styles if not styles.is_empty() else {"hair": hair}, "colors": colors,
		"worn": WorldLibrary.STARTER_OUTFIT.duplicate()}
	var doll := Art.character_sprite(content, body, look)
	doll.scale = Vector2.ONE / maxf(0.5, float(body.get("pixel_scale", 1.0)))  # an LPC texel a pixel; finer ones (RO) as in the world
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
