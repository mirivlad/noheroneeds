class_name TalkPanel
extends PanelContainer
## Talk with a dweller (ADR-0042): who it is, what it asks and where one
## stands with it, what its village remembers; to take its request on, to
## tell it is done, to trade. The server says it all again after each step.
## UI 2.0: the dweller's portrait at the left, what it says in a box of its
## own, where the village stands with one as a bar and a word.

signal promise(creature: String)
signal report(creature: String)
signal trade(creature: String)
signal escort(creature: String)
## Learn a recipe from the dweller (ADR-0047).
signal learn(creature: String, recipe: String)

const WIDTH := 400
var content: ContentRegistry
## The dweller talked with (an entity id) while it is open.
var creature := ""
var talk := {}
var _title := Label.new()
var _says := Label.new()
var _goal := Label.new()
var _trust := Label.new()
var _news := Label.new()
var _take := Button.new()
var _done := Button.new()
var _trade := Button.new()
var _ask_news := Button.new()
var _teach := Button.new()
var _lessons := ItemList.new()
var _lesson_ids: Array[String] = []
var _lesson_ok := {}
## The dweller as it looks, and the village's trust in one (-3..5 drawn).
var portrait := CharacterPreview.new()
var _trust_bar := HudBoxes.Bar.new()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_title, _says, _goal, _trust, _news, _take, _done, _trade, _ask_news, _teach, _lessons, portrait, _trust_bar]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry) -> void:
	content = registry
	theme = Art.theme()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(Art.window_head(_title, "E", hide))
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", Art.GAP * 3)
	box.add_child(columns)
	portrait.walking = false
	columns.add_child(portrait)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	columns.add_child(right)
	_says.add_theme_stylebox_override("normal", Art.hud_box())
	for l: Label in [_says, _goal, _news]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = WIDTH
		right.add_child(l)
	var trust_row := HBoxContainer.new()
	_trust_bar.custom_minimum_size = Vector2(80, 6)
	_trust_bar.color = Art.GOOD
	trust_row.add_child(_trust)
	trust_row.add_child(_trust_bar)
	right.add_child(trust_row)
	box = right
	_goal.add_theme_color_override("font_color", Art.TEXT_DIM)
	_trust.add_theme_color_override("font_color", Art.TEXT_DIM)
	_news.add_theme_color_override("font_color", Art.TEXT_DIM)
	_news.visible = false
	var row := HBoxContainer.new()
	box.add_child(row)
	_take.text = "Взяться"
	_take.pressed.connect(func() -> void:
		if talk.has("escort"):
			escort.emit(creature)
		else:
			promise.emit(creature))
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


## How a village stands with one, in a word (ADR-0047: requests done, harm).
static func trust_word(standing: int, grudge: bool) -> String:
	if grudge or standing < 0:
		return "в обиде"
	if standing == 0:
		return "чужак"
	return "знакомый" if standing < 3 else "свой"


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
func open_for(r: Dictionary, looks := {}) -> void:
	portrait.visible = not looks.is_empty()
	if not looks.is_empty():
		portrait.show_look(content, looks)
	creature = String(r.get("creature", creature))
	talk = r
	var trade_name := String(content.get_def(String(r.get("profession", ""))).get("name", "житель")).to_lower()
	_title.text = "%s, %s. Деревня %s" % [r.get("name", "Житель"), trade_name, r.get("village", "")] if not r.get("trader", false) \
		else "%s, торговец. Идёт в деревню %s" % [r.get("name", "Торговец"), r.get("village", "")]
	var req: Dictionary = r.get("request", {})
	var state := String(req.get("state", ""))
	if r.has("says"):  # a trader on the road (ADR-0067)
		_says.text = "— " + String(r["says"])
	elif r.get("grudge", false):
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
	_take.disabled = false
	_take.text = "Взяться"
	_done.visible = state in ["doing", "ready"]
	_done.disabled = state != "ready"
	_done.text = ("Отдать" if String(req.get("kind", "")) != "hunt" else "Сделано") if state == "ready" else "Ещё не сделано"
	if r.has("escort"):
		var terms: Dictionary = r["escort"]
		var active: bool = terms.get("state", "") == "active"
		_goal.visible = true
		_goal.text = "Охрана до деревни %s: %d монет за игровые сутки.\nОплачивается сопровождение и ночлег рядом с караваном; отсутствие не оплачивается." % [
			terms.get("destination", ""), int(terms.get("rate", 0))]
		if active:
			_goal.text += "\nДоговор с %s действует. Выплачено: %d монет. Подробности и отказ — в журнале (L)." % [
				terms.get("name", "торговцем"), int(terms.get("paid", 0))]
		elif not terms.get("can_hire", false):
			_goal.text += "\nСейчас у торговца не хватает денег на оплату."
		_take.visible = not active
		_take.disabled = not terms.get("can_hire", false)
		_take.text = "Наняться в охрану"
		_done.visible = false
	_trade.visible = not content.get_def(String(r.get("profession", ""))).get("trade", {}).is_empty() and not r.get("grudge", false)
	show_lessons(r.get("teaches", []))
	var standing := int(r.get("standing", 0))
	_trust.text = "Деревня к вам: %s (%+d)" % [trust_word(standing, r.get("grudge", false)), standing]
	_trust_bar.share = clampf((float(standing) + 3.0) / 8.0, 0.0, 1.0)
	_trust_bar.color = Art.DANGER if r.get("grudge", false) or standing < 0 else Art.GOOD
	_trust_bar.queue_redraw()
	_trust.get_parent().visible = not r.get("trader", false)  # a stranger: no village's trust
	var short: Array = r.get("short", [])
	if not short.is_empty() and not r.get("grudge", false):
		_goal.visible = true
		_goal.text += ("\n" if _goal.text != "" else "") + ("Там не хватает: " if r.get("trader", false) else "Деревне не хватает: ") + ", ".join(PackedStringArray(short.map(
			func(i: Variant) -> String: return String(content.get_def(String(i)).get("name", i)).to_lower()))) + " — за это заплатят дороже."
	var lines: Array = r.get("chronicle", [])
	_news.text = "Деревня помнит:\n" + "\n".join(PackedStringArray(lines.map(func(t: Variant) -> String: return "• " + String(t))))
	_ask_news.visible = not lines.is_empty()
	visible = true
