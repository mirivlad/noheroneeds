class_name ChestPanel
extends PanelContainer
## A container opened (ADR-0021, ADR-0041): its cells above, one's bag below,
## as in the bag's window. A click moves one of a cell's stack; with Shift
## the whole stack, with Ctrl half (a stack split); a cell dragged into the
## other grid moves its stack. The server says what is in it after every move.

## (item, count, into the container?)
signal move(item: String, count: int, putting: bool)
var content: ContentRegistry
var view: WorldView
## The container's cell (on the client's location) while it is open.
var cell := Vector2i.ZERO
var contents := {}
var slots := 0
## The bag's cells as the player arranged them (the bag window's order).
var bag_order: Array = []
var box := SlotGrid.new()
var mine := SlotGrid.new()
var _title := Label.new()
var _mine_title := Label.new()
var _inventory := {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [box, mine, _title, _mine_title]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	theme = Art.theme()
	var col := VBoxContainer.new()
	add_child(col)
	col.add_child(_title)
	box.setup(content, view, Bag.COLUMNS, "box")
	mine.setup(content, view, Bag.COLUMNS, "chest_bag")
	box.accepts = func(data: Dictionary) -> bool: return String(data.get("grid", "")) == "chest_bag"
	mine.accepts = func(data: Dictionary) -> bool: return String(data.get("grid", "")) == "box"
	box.taken.connect(func(data: Dictionary, _at: int) -> void: move.emit(String(data["item"]), int(data["count"]), true))
	mine.taken.connect(func(data: Dictionary, _at: int) -> void: move.emit(String(data["item"]), int(data["count"]), false))
	for g: SlotGrid in [box, mine]:
		g.selectable = false
		g.clicked.connect(func(i: int, _b: int) -> void: _pick(g, i))
	col.add_child(box)
	_mine_title.text = "Ваши вещи"
	col.add_child(_mine_title)
	col.add_child(mine)
	var hint := Label.new()
	hint.text = "щелчок — одну, Shift — стопку, Ctrl — половину; тащите стопку в другую сетку; E или Esc — закрыть"
	hint.add_theme_color_override("font_color", Art.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = Bag.COLUMNS * (SlotGrid.CELL + 2)
	col.add_child(hint)
	visible = false


func _pick(g: SlotGrid, i: int) -> void:
	var have := g.count_at(i)
	if have <= 0:
		return
	var n := 1
	if Input.is_key_pressed(KEY_SHIFT):
		n = have
	elif Input.is_key_pressed(KEY_CTRL):
		n = maxi(1, have / 2)
	move.emit(g.item_at(i), n, g == mine)


func open_at(at: Vector2i, what: Dictionary, room: int, inventory: Dictionary) -> void:
	cell = at
	contents = what
	slots = room
	refresh(inventory)
	visible = true


func refresh(inventory: Dictionary) -> void:
	_inventory = inventory
	_title.text = "Сундук: занято %d из %d" % [Bag.used(content, contents), slots]
	box.show_cells(Bag.lay_out(content, contents, [], slots)["cells"])
	var laid := Bag.lay_out(content, inventory, bag_order)
	bag_order = laid["order"]
	mine.show_cells(laid["cells"])
	_mine_title.text = "Ваши вещи: занято %d из %d" % [Bag.used(content, inventory), Bag.SIZE]
