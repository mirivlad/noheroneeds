class_name TalkPanel
extends PanelContainer
## Talk with a dweller (ADR-0042): who it is, what it asks and where one
## stands with it, what its village remembers; to take its request on, to
## tell it is done, to trade. The server says it all again after each step.

signal promise(creature: String)
signal report(creature: String)
signal trade(creature: String)

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


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_title, _says, _goal, _news, _take, _done, _trade, _ask_news]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry) -> void:
	content = registry
	theme = Art.theme()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(_title)
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
	var close := Button.new()
	close.text = "Закрыть (E)"
	close.pressed.connect(func() -> void: hide())
	for b: Button in [_take, _done, _trade, _ask_news, close]:
		row.add_child(b)
	var hint := Label.new()
	hint.text = "L — журнал: что вы взялись сделать и что помнят деревни"
	hint.add_theme_color_override("font_color", Art.TEXT_DIM)
	box.add_child(hint)
	visible = false


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
	var lines: Array = r.get("chronicle", [])
	_news.text = "Деревня помнит:\n" + "\n".join(PackedStringArray(lines.map(func(t: Variant) -> String: return "• " + String(t))))
	_ask_news.visible = not lines.is_empty()
	visible = true
