class_name ActionMenu
extends PanelContainer
## The right button's list of what can be done with what is pointed at
## (ADR-0021): a window of the game's own, drawn in the raster's pixels like
## the others (not a window of the system), beside the cursor and within the
## screen. A click on a line does it; a click elsewhere or Esc lets it go.

signal chosen(index: int)
var _box := VBoxContainer.new()


func _init() -> void:
	theme = Art.theme()
	add_child(_box)
	visible = false


## Lines: {"text", "disabled", "why"}; `title` over them ("" — none).
func open(at: Vector2, title: String, lines: Array[Dictionary]) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	if title != "":
		var head := Label.new()
		head.text = title
		head.add_theme_color_override("font_color", Art.TEXT_HOT)
		_box.add_child(head)
		_box.add_child(HSeparator.new())
	for i in lines.size():
		var b := Button.new()
		b.text = String(lines[i]["text"])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = lines[i].get("disabled", false)
		if b.disabled and String(lines[i].get("why", "")) != "":
			b.text += " — " + String(lines[i]["why"])
		b.pressed.connect(func() -> void:
			hide()
			chosen.emit(i))
		_box.add_child(b)
	visible = true
	size = get_combined_minimum_size()
	var area := get_viewport_rect().size
	position = Vector2(clampf(at.x + 4, 0, maxf(0, area.x - size.x)), clampf(at.y + 4, 0, maxf(0, area.y - size.y))).floor()
