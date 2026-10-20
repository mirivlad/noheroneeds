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
## [[id, count], ...] as shown.
var cells: Array = []
var selected := -1
var _cells: Array[Cell] = []


class Cell:
	extends Panel
	var grid: SlotGrid
	var index := 0
	var icon := TextureRect.new()
	var count := Label.new()

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

	func item() -> String:
		return String(grid.cells[index][0]) if index < grid.cells.size() else ""

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
		return {"item": item(), "count": int(grid.cells[index][1]), "grid": grid.tag, "cell": index}

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
		c.icon.texture = view.item_picture(id) if id != "" else null
		c.count.text = str(n) if n > 1 else ""
		c.tooltip_text = "%s ×%d" % [content.get_def(id).get("name", id), n] if id != "" else ""
		c.add_theme_stylebox_override("panel", _box_chosen if i == selected else _box_empty)


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
