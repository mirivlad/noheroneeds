class_name TalkPanel
extends PanelContainer
## Talk with a dweller (ADR-0042): who it is, what it asks and where one
## stands with it, what its village remembers; to take its request on, to
## tell it is done, to trade. The server says it all again after each step.

signal promise(creature: String)
signal report(creature: String)
signal trade(creature: String)
## Learn a recipe from the dweller (ADR-0047).
signal learn(creature: String, recipe: String)

const WIDTH := 480
var content: ContentRegistry
## The dweller talked with (an entity id) while it is open.
var creature := ""
var talk := {}
var _title := Label.new()
var _says := Label.new()
var _goal := Label.new()
var _news := Label.new()
var _take := Button.new()
var _done := Button.new()
var _trade := Button.new()
var _ask_news := Button.new()
var _teach := Button.new()
var _lessons := ItemList.new()
var _lesson_ids: Array[String] = []
var _lesson_ok := {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_title, _says, _goal, _news, _take, _done, _trade, _ask_news, _teach, _lessons]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry) -> void:
	content = registry
	theme = Art.theme()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(Art.window_head(_title, "E", hide))
	for l: Label in [_says, _goal, _news]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = WIDTH
		box.add_child(l)
	_goal.add_theme_color_override("font_color", Art.TEXT_DIM)
	_news.add_theme_color_override("font_color", Art.TEXT_DIM)
	_news.visible = false
	var row := HBoxContainer.new()
	box.add_child(row)
	_take.text = "Взяться"
	_take.pressed.connect(func() -> void: promise.emit(creature))
	_done.text = "Готово"
	_done.pressed.connect(func() -> void: report.emit(creature))
	_trade.text = "Торговать"
	_trade.pressed.connect(func() -> void: trade.emit(creature))
	_ask_news.text = "Что нового?"
	_ask_news.pressed.connect(func() -> void: _news.visible = not _news.visible)
	_teach.text = "Учиться"
	_teach.pressed.connect(func() -> void: _lessons.visible = not _lessons.visible)
	for b: Button in [_take, _done, _trade, _teach, _ask_news]:
		row.add_child(b)
	# What it would teach, on what terms; a click asks to learn it.
	_lessons.name = "Lessons"
	_lessons.custom_minimum_size = Vector2(WIDTH, 150)
	_lessons.visible = false
	_lessons.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void:
		if bool(_lesson_ok.get(_lesson_ids[i], false)):
			learn.emit(creature, _lesson_ids[i]))
	box.add_child(_lessons)
	var hint := Label.new()
	hint.text = "L — журнал: что вы взялись сделать и что помнят деревни"
	hint.add_theme_color_override("font_color", Art.TEXT_DIM)
	box.add_child(hint)
	visible = false


## Why a dweller will not teach a recipe, for people.
const NOT_TAUGHT := {"known_already": "уже знаете", "grudge": "не станет учить", "standing": "мало доверия: помогите деревне",
	"not_skilled": "рано: не хватает умения", "no_money": "не хватает монет"}


## What the dweller teaches ([{recipe, price, standing, skill, why}]).
func show_lessons(lessons: Array) -> void:
	_lessons.clear()
	_lesson_ids.clear()
	_lesson_ok.clear()
	for t: Dictionary in lessons:
		var r := String(t["recipe"])
		var why := String(t.get("why", ""))
		var text := "%s — %d монет" % [content.get_def(r).get("name", r), int(t.get("price", 0))]
		if why != "":
			text += " (%s)" % NOT_TAUGHT.get(why, why)
		var i := _lessons.add_item(text)
		var terms := PackedStringArray(["Доверие деревни: %d" % int(t.get("standing", 0))])
		for sk: String in t.get("skill", {}):
			terms.append("%s: %d" % [content.get_def(sk).get("name", sk), int(t["skill"][sk])])
		_lessons.set_item_tooltip(i, "\n".join(terms))
		if why != "":
			_lessons.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_lesson_ids.append(r)
		_lesson_ok[r] = why == ""
	_teach.visible = not lessons.is_empty()
	_teach.text = "Учиться (%d)" % lessons.filter(func(t: Dictionary) -> bool: return String(t.get("why", "")) == "").size()


## Shows what the server said ({name, profession, village, request?,
## chronicle, grudge?, thanks?, reward?}).
func open_for(r: Dictionary) -> void:
	creature = String(r.get("creature", creature))
	talk = r
	var trade_name := String(content.get_def(String(r.get("profession", ""))).get("name", "житель")).to_lower()
	_title.text = "%s, %s. Деревня %s" % [r.get("name", "Житель"), trade_name, r.get("village", "")]
	var req: Dictionary = r.get("request", {})
	var state := String(req.get("state", ""))
	if r.get("grudge", false):
		_says.text = "— Не о чем мне с тобой говорить. Ступай."
	elif r.has("thanks"):
		_says.text = "— %s\nНаграда: %d монет." % [r["thanks"], int(r.get("reward", 0))]
	elif not req.is_empty():
		_says.text = "— " + String(req["says"])
	else:
		_says.text = "— Просить мне не о чем. Заходи, коли нужда будет."
	_goal.visible = state in ["doing", "ready"]
	_goal.text = "Вы взялись: " + String(req.get("goal", "")) if _goal.visible else ""
	if state == "offered" and int(req.get("reward", 0)) > 0:
		_goal.visible = true
		_goal.text = "Обещает: %d монет." % int(req["reward"])
	_take.visible = state == "offered"
	_done.visible = state in ["doing", "ready"]
	_done.disabled = state != "ready"
	_done.text = ("Отдать" if String(req.get("kind", "")) != "hunt" else "Сделано") if state == "ready" else "Ещё не сделано"
	_trade.visible = not content.get_def(String(r.get("profession", ""))).get("trade", {}).is_empty() and not r.get("grudge", false)
	show_lessons(r.get("teaches", []))
	var lines: Array = r.get("chronicle", [])
	_news.text = "Деревня помнит:\n" + "\n".join(PackedStringArray(lines.map(func(t: Variant) -> String: return "• " + String(t))))
	_ask_news.visible = not lines.is_empty()
	visible = true
