class_name SlotGrid
extends GridContainer
## Cells of things, a stack a cell (ADR-0041): the bag, a chest, what is
## worn beside the doll. A cell's stack is dragged onto another cell, onto a
## quick slot, onto the doll or into another grid; a click picks it. What a
## drop means is the owner's to say (signals); the grid only shows.

## A cell's stack was dragged onto another cell of this grid.
signal moved(from: int, to: int)
## Something dragged from elsewhere (another grid, a quick slot, the doll)
## was let go over a cell.
signal taken(data: Dictionary, at: int)
## A cell was clicked (button: MOUSE_BUTTON_LEFT / RIGHT).
signal clicked(index: int, button: int)
## A cell was double-clicked.
signal activated(index: int)

const CELL := 40

## Tag of this grid in what is dragged out of it ({"grid": tag, ...}).
var tag := ""
## Whether a drop from elsewhere is taken here: (data) -> bool.
var accepts: Callable = func(_data: Dictionary) -> bool: return false
## Whether a click marks the cell chosen.
var selectable := true
var content: ContentRegistry
var view: WorldView
## [[id, count], ...] as shown; a thing whose copies differ (ADR-0046:
## wear) has its copy's state and number too: [id, 1, state, copy].
var cells: Array = []
var selected := -1
var _cells: Array[Cell] = []


class Cell:
	extends Panel
	var grid: SlotGrid
	var index := 0
	var icon := TextureRect.new()
	var count := Label.new()
	var bar := WearBar.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(SlotGrid.CELL, SlotGrid.CELL)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(4, 4)
		icon.size = Vector2(32, 32)  # a 32 px picture a pixel a texel
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(icon)
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count.add_theme_font_override("font", Art.font())
		count.add_theme_font_size_override("font_size", 16)
		count.add_theme_color_override("font_color", Art.TEXT)
		count.add_theme_color_override("font_outline_color", Art.INK)
		count.add_theme_constant_override("outline_size", 2)
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count.position = Vector2(0, 20)
		count.size = Vector2(SlotGrid.CELL - 3, 16)
		add_child(count)
		bar.position = Vector2(4, SlotGrid.CELL - 6)
		bar.size = Vector2(SlotGrid.CELL - 8, 4)
		add_child(bar)

	func item() -> String:
		return String(grid.cells[index][0]) if index < grid.cells.size() else ""

	## Which copy of its thing the cell shows (-1: copies are alike).
	func copy() -> int:
		return grid.copy_at(index)

	func _get_drag_data(_at: Vector2) -> Variant:
		if item() == "":
			return null
		var preview := TextureRect.new()
		preview.texture = icon.texture
		preview.size = Vector2(32, 32)
		if get_viewport() and get_viewport().gui_is_dragging():
			set_drag_preview(preview)
		else:
			preview.free()
		return {"item": item(), "count": int(grid.cells[index][1]), "grid": grid.tag, "cell": index, "copy": copy()}

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		if typeof(data) != TYPE_DICTIONARY:
			return false
		if String((data as Dictionary).get("grid", "")) == grid.tag and grid.tag != "":
			return int(data["cell"]) != index
		return grid.accepts.call(data)

	func _drop_data(_at: Vector2, data: Variant) -> void:
		if String((data as Dictionary).get("grid", "")) == grid.tag and grid.tag != "":
			grid.moved.emit(int(data["cell"]), index)
		else:
			grid.taken.emit(data, index)

	func _gui_input(event: InputEvent) -> void:
		var b := event as InputEventMouseButton
		if b == null or not b.pressed:
			return
		if b.double_click and b.button_index == MOUSE_BUTTON_LEFT:
			grid.activated.emit(index)
		elif b.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if b.button_index == MOUSE_BUTTON_LEFT and grid.selectable:
				grid.select(index)
			grid.clicked.emit(index, b.button_index)


static var _box_empty := _box(Color(0.08, 0.07, 0.1, 0.75), Color(0.45, 0.42, 0.4, 0.8), 1)
static var _box_chosen := _box(Color(0.5, 0.2, 0.75, 0.55), Color(1.0, 0.88, 0.1), 2)


static func _box(fill: Color, frame: Color, width: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = frame
	b.set_border_width_all(width)
	return b


func setup(registry: ContentRegistry, world_view: WorldView, cols: int, grid_tag := "") -> void:
	content = registry
	view = world_view
	columns = cols
	tag = grid_tag
	add_theme_constant_override("h_separation", 2)
	add_theme_constant_override("v_separation", 2)


## Shows the cells ([[id, count], ...]); as many cells as there are.
func show_cells(what: Array) -> void:
	cells = what
	while _cells.size() < cells.size():
		var c := Cell.new()
		c.grid = self
		c.index = _cells.size()
		add_child(c)
		_cells.append(c)
	while _cells.size() > cells.size():
		_cells.pop_back().queue_free()
	if selected >= cells.size() or (selected >= 0 and String(cells[selected][0]) == ""):
		selected = -1
	for i in cells.size():
		var c := _cells[i]
		var id := String(cells[i][0])
		var n := int(cells[i][1])
		var state := state_at(i)
		c.icon.texture = view.item_picture(id) if id != "" else null
		c.icon.modulate = Color(1, 1, 1, 0.45) if id != "" and Wear.broken(content, id, state) else Color.WHITE
		c.count.text = str(n) if n > 1 else ""
		c.bar.show_state(content, id, state)
		# The card of the thing (its condition; later its other marks).
		c.tooltip_text = ItemCard.text(content, id, state, n) if id != "" else ""
		c.add_theme_stylebox_override("panel", _box_chosen if i == selected else _box_empty)


## The state of the copy a cell shows ({} — plain).
func state_at(index: int) -> Dictionary:
	if index < 0 or index >= cells.size() or (cells[index] as Array).size() < 3 or typeof(cells[index][2]) != TYPE_DICTIONARY:
		return {}
	return cells[index][2]


## Which copy of its thing a cell shows (-1: its copies are alike).
func copy_at(index: int) -> int:
	if index < 0 or index >= cells.size() or (cells[index] as Array).size() < 4:
		return -1
	return int(cells[index][3])


## Cells as Bag.lay_out makes them, with each copy's state for things whose
## copies differ (`states`: {id: [state, ...]}, the client's): the n-th cell
## of a thing shows its n-th copy.
static func with_states(content: ContentRegistry, cells: Array, states: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	for cell: Array in cells:
		var id := String(cell[0])
		if id == "" or not (Wear.wears(content, id) or states.has(id)):  # a thing of its own: worn, made, a blueprint
			out.append(cell)
			continue
		var k := int(seen.get(id, 0))
		seen[id] = k + 1
		var list: Array = states.get(id, [])
		out.append([id, cell[1], (list[k] as Dictionary) if k < list.size() and typeof(list[k]) == TYPE_DICTIONARY else {}, k])
	return out


func select(index: int) -> void:
	selected = index if index >= 0 and index < cells.size() and String(cells[index][0]) != "" else -1
	for i in _cells.size():
		_cells[i].add_theme_stylebox_override("panel", _box_chosen if i == selected else _box_empty)


func item_at(index: int) -> String:
	return String(cells[index][0]) if index >= 0 and index < cells.size() else ""


func count_at(index: int) -> int:
	return int(cells[index][1]) if index >= 0 and index < cells.size() else 0


func cell(index: int) -> Control:
	return _cells[index]
