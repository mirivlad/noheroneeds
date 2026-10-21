class_name JournalPanel
extends PanelContainer
## The journal (L, ADR-0042): what one took on to do for dwellers and how far
## it is, and what the villages one talked in remember.

const WIDTH := 520
var _text := Label.new()
var _scroll := ScrollContainer.new()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_text, _scroll]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup() -> void:
	theme = Art.theme()
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "Журнал"
	box.add_child(Art.window_head(title, "L", hide))
	_scroll.custom_minimum_size = Vector2(WIDTH, 360)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size.x = WIDTH - 16
	_scroll.add_child(_text)
	visible = false


## Shows the server's journal ({requests: [{goal, state, reward}],
## chronicles: [{village, entries}]}).
func open_for(j: Dictionary) -> void:
	var out := PackedStringArray()
	var requests: Array = j.get("requests", [])
	out.append("Взялись сделать:" if not requests.is_empty() else "Вы ни за что не взялись. Поговорите с жителями (E).")
	for r: Dictionary in requests:
		out.append("• %s%s" % [r.get("goal", ""), "  — готово, можно сказать" if r.get("state") == "ready" else ""])
	for c: Dictionary in j.get("chronicles", []):
		out.append("")
		out.append("Деревня %s помнит:" % c.get("village", ""))
		for e: Variant in c.get("entries", []):
			out.append("• " + String(e))
	_text.text = "\n".join(out)
	visible = true
