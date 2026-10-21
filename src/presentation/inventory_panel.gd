class_name InventoryPanel
extends PanelContainer
## The things one carries (I), as a grid of cells (ADR-0041): Bag.SIZE cells,
## a stack a cell, laid out as the player arranged them (dragged cell to
## cell; kept in the settings). A cell is dragged onto a quick slot to have
## the thing at hand (ADR-0021), onto the doll to wear it; a quick slot or a
## worn thing dragged back here is emptied or taken off. Right click drops
## one (Shift the cell's stack, Ctrl half of it); a double click wears.
## Compact, beside the doll (C): only what can be worn or held.

## Drop (item, count) on the ground; `copy`: which copy (-1: any).
signal drop(item: String, count: int, copy: int)
## A quick slot was dragged back onto the things: it is emptied.
signal unslot(slot: int)
## Wear or take into the hands (`copy`: which copy, -1: any).
signal wear(item: String, copy: int)
signal take_off(slot: String)
## The cells were arranged anew: the order to keep (item id or "" per cell).
signal arranged(order: Array)

var content: ContentRegistry
var view: WorldView
var grid := SlotGrid.new()
## The order of the cells (an item id or "" each), as the player left them.
var order: Array = []
var _title := Label.new()
var _hint := Label.new()
var _have := {}
## Each carried copy's state (the client's item_states, ADR-0046).
var _states := {}
var _wear := Button.new()
var _compact := false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [grid, _title, _hint, _wear]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry, world_view: WorldView, compact := false) -> void:
	content = registry
	view = world_view
	_compact = compact
	theme = Art.theme()
	var box := VBoxContainer.new()
	add_child(box)
	# The pixel font is drawn at its own size (16) or not at all readable.
	_title.add_theme_font_size_override("font_size", 16)
	box.add_child(_title if compact else Art.window_head(_title, "I", hide))
	grid.setup(content, view, 5 if compact else Bag.COLUMNS, "worn_bag" if compact else "bag")
	grid.accepts = func(data: Dictionary) -> bool:
		return int(data.get("from_slot", -1)) >= 0 or data.has("equipment_slot")
	grid.taken.connect(func(data: Dictionary, _at: int) -> void:
		if data.has("equipment_slot"):
			take_off.emit(String(data["equipment_slot"]))
		elif int(data.get("from_slot", -1)) >= 0:
			unslot.emit(int(data["from_slot"])))
	grid.moved.connect(_move)
	grid.clicked.connect(func(i: int, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			drop_some(i)
		else:
			_wear.disabled = not _can_wear(grid.item_at(i)))
	grid.activated.connect(func(i: int) -> void:
		if _can_wear(grid.item_at(i)):
			wear.emit(grid.item_at(i), grid.copy_at(i)))
	box.add_child(grid)
	_hint.add_theme_font_size_override("font_size", 16)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = grid.columns * (SlotGrid.CELL + 2)
	_hint.add_theme_color_override("font_color", Art.TEXT_DIM)
	_hint.text = "Двойной щелчок — надеть" if compact else \
		"Тащите: в ячейку, на панель внизу, на куклу (C). Двойной щелчок — надеть. ПКМ — бросить (Shift — стопку, Ctrl — половину)"
	box.add_child(_hint)
	_wear.text = "Надеть / взять в руки"
	_wear.disabled = true
	_wear.pressed.connect(func() -> void:
		if _can_wear(grid.item_at(grid.selected)):
			wear.emit(grid.item_at(grid.selected), grid.copy_at(grid.selected)))
	box.add_child(_wear)
	visible = false


func _can_wear(id: String) -> bool:
	if id == "":
		return false
	var d := content.get_def(id)
	return String(d.get("equip_slot", "")) != "" or d.has("tools") or d.has("weapon")


## Right click on a cell: one of it on the ground; with Shift the cell's
## stack, with Ctrl half of it.
func drop_some(index: int) -> void:
	var id := grid.item_at(index)
	var have := grid.count_at(index)
	if id == "" or have <= 0:
		return
	var n := have if Input.is_key_pressed(KEY_SHIFT) else (maxi(1, have / 2) if Input.is_key_pressed(KEY_CTRL) else 1)
	drop.emit(id, n, grid.copy_at(index))


## A cell's stack onto another cell: the two change places.
func _move(from: int, to: int) -> void:
	if _compact:
		return  # beside the doll the cells keep to names
	while order.size() <= maxi(from, to):
		order.append("")
	var was: Variant = order[to]
	order[to] = order[from]
	order[from] = was
	show_for(_have, 0, _states)
	arranged.emit(order)


func show_for(inventory: Dictionary, _slot: int, states := {}) -> void:
	_have = inventory
	_states = states
	if _compact:  # beside the doll: only what is worn or held (the rest is in the things, I)
		var mine := {}
		for id: String in inventory:
			if _can_wear(id):
				mine[id] = inventory[id]
		var laid := Bag.lay_out(content, mine, [], 0)
		var cells: Array = laid["cells"]
		while cells.size() < 30 or cells.size() % grid.columns != 0:
			cells.append(["", 0])
		_title.text = "Снаряжение"
		grid.show_cells(SlotGrid.with_states(content, cells, states))
	else:
		var before := order.duplicate()
		var laid := Bag.lay_out(content, inventory, order)
		order = laid["order"]
		_title.text = "Вещи: занято %d из %d" % [Bag.used(content, inventory), Bag.SIZE]
		grid.show_cells(SlotGrid.with_states(content, laid["cells"], states))
		if order != before:
			arranged.emit(order)
	_wear.disabled = not _can_wear(grid.item_at(grid.selected))
	visible = true
