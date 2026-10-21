class_name PinPanel
extends PanelContainer
## A door's code of four digits (ADR-0016): given to open a locked door, or
## chosen by the one who set the door up to lock it. Enter — done, Esc — no.

## The code given, for the door at `cell`; `setting`: it is a new code.
signal entered(cell: Vector2i, pin: String, setting: bool)
var cell := Vector2i.ZERO
var setting := false
var _title: Label
var _code: LineEdit


func setup() -> void:
	theme = Art.theme()
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	box.add_child(Art.window_head(_title, "Esc", hide))
	_code = LineEdit.new()
	_code.max_length = 4
	_code.secret = true
	_code.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code.custom_minimum_size = Vector2(80, 0)
	_code.text_changed.connect(func(t: String) -> void:
		var digits := ""
		for ch in t:
			if ch >= "0" and ch <= "9":
				digits += ch
		if digits != t:
			_code.text = digits
			_code.caret_column = digits.length())
	_code.text_submitted.connect(func(t: String) -> void: submit(t))
	box.add_child(_code)
	var hint := Label.new()
	hint.text = "четыре цифры; Enter — готово"
	hint.add_theme_color_override("font_color", Art.TEXT_DIM)
	box.add_child(hint)
	visible = false


func open_for(at: Vector2i, new_code: bool) -> void:
	cell = at
	setting = new_code
	_title.text = "Новый код замка" if new_code else "Дверь заперта: код"
	_code.text = ""
	visible = true
	_code.grab_focus()


func submit(t: String) -> void:
	if t.length() != 4 or not t.is_valid_int():
		return
	visible = false
	entered.emit(cell, t, setting)
