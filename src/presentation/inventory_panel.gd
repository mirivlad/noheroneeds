class_name InventoryPanel
extends PanelContainer
## The things one carries (I), as a grid of cells (ADR-0041): Bag.SIZE cells,
## a stack a cell, laid out as the player arranged them (dragged cell to
## cell; kept in the settings). A cell is dragged onto a quick slot to have
## the thing at hand (ADR-0021), onto the doll to wear it; a quick slot or a
## worn thing dragged back here is emptied or taken off. Right click drops
## one (Shift the cell's stack, Ctrl half of it); a double click wears.
## UI 2.0: the things' part of the character window (I or C), the chosen
## thing's card under the cells with what can be done with it.

## Drop (item, count) on the ground; `copy`: which copy (-1: any).
signal drop(item: String, count: int, copy: int)
## A quick slot was dragged back onto the things: it is emptied.
signal unslot(slot: int)
## Wear or take into the hands (`copy`: which copy, -1: any).
signal wear(item: String, copy: int)
signal take_off(slot: String)
## The cells were arranged anew: the order to keep (item id or "" per cell).
signal arranged(order: Array)
## A blueprint was double-clicked: its use is in the crafts (K, ADR-0047).
signal blueprints

var content: ContentRegistry
var view: WorldView
var grid := SlotGrid.new()
## The order of the cells (an item id or "" each), as the player left them.
var order: Array = []
var _title := Label.new()
var _have := {}
## Each carried copy's state (the client's item_states, ADR-0046).
var _states := {}
var _wear := Button.new()
var _drop := Button.new()
## The chosen thing's card (ItemCard), or what to do when none is chosen.
var card := Label.new()
const NO_CARD := "Выберите вещь — здесь её свойства. Тащите в быстрые слоты или на куклу; двойной щелчок — надеть; ПКМ — бросить (Shift — стопку, Ctrl — половину)"


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [grid, _title, _wear, _drop, card]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	theme = Art.theme()
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())  # a part of the character window
	var box := VBoxContainer.new()
	add_child(box)
	# The pixel font is drawn at its own size (16) or not at all readable.
	_title.add_theme_font_size_override("font_size", 16)
	_title.add_theme_color_override("font_color", Art.TEXT_HOT)
	box.add_child(_title)
	grid.setup(content, view, Bag.COLUMNS, "bag")
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
		_show_card())
	grid.activated.connect(func(i: int) -> void:
		if grid.item_at(i) == "base:blueprint":
			blueprints.emit()
		elif _can_wear(grid.item_at(i)):
			wear.emit(grid.item_at(i), grid.copy_at(i)))
	box.add_child(grid)
	card.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.custom_minimum_size = Vector2(Bag.COLUMNS * (SlotGrid.CELL + 2), 112)
	card.add_theme_stylebox_override("normal", Art.hud_box())
	box.add_child(card)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_wear.text = "Надеть / взять в руки"
	_wear.disabled = true
	_wear.pressed.connect(func() -> void:
		if _can_wear(grid.item_at(grid.selected)):
			wear.emit(grid.item_at(grid.selected), grid.copy_at(grid.selected)))
	_drop.name = "Drop"
	_drop.text = "Бросить"
	_drop.tooltip_text = "Одну на землю; с Shift — всю стопку, с Ctrl — половину"
	_drop.pressed.connect(func() -> void: drop_some(grid.selected))
	var tidy := Button.new()
	tidy.name = "Tidy"
	tidy.text = "Разложить"
	tidy.tooltip_text = "Разложить по названиям: одинаковое рядом"
	tidy.pressed.connect(tidy_up)
	for b: Button in [_wear, _drop, tidy]:
		b.focus_mode = Control.FOCUS_NONE
		buttons.add_child(b)
	visible = false


## The chosen cell's card and what its buttons may do.
func _show_card() -> void:
	var i := grid.selected
	var id := grid.item_at(i) if i >= 0 else ""
	card.text = ItemCard.text(content, id, grid.state_at(i), grid.count_at(i)) if id != "" else NO_CARD
	card.add_theme_color_override("font_color", Art.TEXT if id != "" else Art.TEXT_DIM)
	_wear.disabled = not _can_wear(id)
	_drop.disabled = id == ""


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
	if index < 0 or id == "" or have <= 0:
		return
	var n := have if Input.is_key_pressed(KEY_SHIFT) else (maxi(1, have / 2) if Input.is_key_pressed(KEY_CTRL) else 1)
	if Input.is_key_pressed(KEY_SHIFT) and Bag.stack_of(content, id) == 1:
		drop.emit(id, grid.total_of(id), -1)  # every copy alike (ADR-0048)
		return
	drop.emit(id, n, grid.copy_at(index))


## Lays the bag out anew, by name (things alike side by side).
func tidy_up() -> void:
	order = []
	show_for(_have, 0, _states)
	arranged.emit(order)


## A cell's stack onto another cell: the two change places.
func _move(from: int, to: int) -> void:
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
	var before := order.duplicate()
	var laid := Bag.lay_out(content, inventory, order)
	order = laid["order"]
	_title.text = "Вещи: занято %d из %d" % [Bag.used(content, inventory), Bag.SIZE]
	grid.show_cells(SlotGrid.with_states(content, laid["cells"], states))
	if order != before:
		arranged.emit(order)
	_show_card()
	visible = true
