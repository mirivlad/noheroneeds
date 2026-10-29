class_name JournalPanel
extends PanelContainer
signal leave_escort
## The journal (L, ADR-0042): what one took on to do for dwellers and how far
## it is, and what the villages one talked in remember. UI 2.0: two tabs,
## the requests (each with its reward, those ready marked) and the chronicles.

const WIDTH := 520
var _text := Label.new()
var _scroll := ScrollContainer.new()
var tabs := TabBar.new()
var _leave := Button.new()
var _journal := {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_text, _scroll, tabs, _leave]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup() -> void:
	theme = Art.theme()
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "Журнал"
	box.add_child(Art.window_head(title, "L", hide))
	tabs.add_tab("Задания")
	tabs.add_tab("Летописи деревень")
	tabs.focus_mode = Control.FOCUS_NONE
	tabs.tab_changed.connect(func(_t: int) -> void: _show())
	box.add_child(tabs)
	_scroll.custom_minimum_size = Vector2(WIDTH, 360)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = WIDTH - 16
	_scroll.add_child(_text)
	_leave.text = "Завершить договор охраны"
	_leave.pressed.connect(func() -> void: leave_escort.emit())
	box.add_child(_leave)
	visible = false


## Shows the server's journal ({requests: [{goal, state, reward}],
## chronicles: [{village, entries}]}).
func open_for(j: Dictionary) -> void:
	_journal = j
	_show()
	visible = true


func _show() -> void:
	var out := PackedStringArray()
	var escorts: Array = _journal.get("escorts", [])
	_leave.visible = tabs.current_tab == 0 and escorts.any(func(c: Dictionary) -> bool: return c.get("state", "") == "active")
	if tabs.current_tab == 0:
		for c: Dictionary in escorts:
			var statuses := {"active": "действует", "arrived": "прибытие", "dead": "торговец погиб", "left": "завершён вами",
				"funds": "у торговца закончились деньги", "betrayed": "нарушен нападением на караван"}
			out.append("Охрана: %s → %s — %s." % [c.get("name", "Торговец"), c.get("destination", ""), statuses.get(c.get("state", ""), "завершён")])
			out.append("Ставка: %d монет за сутки. Выплачено: %d. В текущих сутках отработано: %.1f ч." % [
				int(c.get("rate", 0)), int(c.get("paid", 0)), float(c.get("elapsed", 0)) / Daylight.HOUR_MS])
			if c.get("state", "") == "active":
				out.append("Сопровождаете караван." if c.get("accompanying", false) else "Вы далеко от каравана — оплата времени приостановлена.")
			out.append("")
		var requests: Array = _journal.get("requests", [])
		if requests.is_empty() and escorts.is_empty():
			out.append("Вы ни за что не взялись. Поговорите с жителями (E).")
		for r: Dictionary in requests:
			var ready: bool = r.get("state") == "ready"
			out.append("%s %s" % ["✓" if ready else "•", r.get("goal", "")])
			var about := PackedStringArray()
			if int(r.get("reward", 0)) > 0:
				about.append("награда: %d монет" % int(r["reward"]))
			if ready:
				about.append("готово — скажите тому, кто просил")
			if not about.is_empty():
				out.append("   " + ", ".join(about))
	else:
		var chronicles: Array = _journal.get("chronicles", [])
		if chronicles.is_empty():
			out.append("Деревни пока ничего о вас не помнят.")
		for c: Dictionary in chronicles:
			if not out.is_empty():
				out.append("")
			out.append("Деревня %s:" % c.get("village", ""))
			for e: Variant in c.get("entries", []):
				out.append("• " + String(e))
	_text.text = "\n".join(out)
