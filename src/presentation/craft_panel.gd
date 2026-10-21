class_name CraftPanel
extends PanelContainer
## Crafts (K, ADR-0026): every recipe of the content (no list in the code),
## what it takes and makes and at which station; what one can make here and
## now first. The server decides; this only asks.

signal craft(recipe: String, count: int)
## Names of the kinds of stations, for people.
const STATIONS := {"workbench": "верстак", "forge": "печь", "fire": "костёр"}
var content: ContentRegistry
var view: WorldView
var client: GameClient
var _list: ItemList
var _ids: Array[String] = []
var _can := {}
var _make: Button
## How many to make: so many as asked, or as many as the things allow.
var count: SpinBox
var _note := Label.new()
var _title := Label.new()
## The kind of station the window was opened at ("" — K: every recipe).
var station := ""
const WIDTH := 460


func _notification(what: int) -> void:
	# Made up front but never added (a window never set up): freed too.
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_note, _title]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry, world_view: WorldView, game_client: GameClient) -> void:
	content = registry
	view = world_view
	client = game_client
	theme = Art.theme()
	var box := VBoxContainer.new()
	add_child(box)
	box.add_child(Art.window_head(_title, "K", hide))
	_list = ItemList.new()
	_list.name = "Recipes"
	_list.custom_minimum_size = Vector2(WIDTH, 260)
	_list.fixed_icon_size = Vector2i(32, 32)
	_list.item_selected.connect(func(_i: int) -> void: _buttons())
	_list.item_activated.connect(func(_i: int) -> void: _ask(how_many()))
	box.add_child(_list)
	var row := HBoxContainer.new()
	box.add_child(row)
	var label := Label.new()
	label.text = "Сколько:"
	row.add_child(label)
	count = SpinBox.new()
	count.name = "Count"
	count.min_value = 1
	count.max_value = 999
	count.value = 1
	count.custom_minimum_size.x = 90
	count.get_line_edit().text_submitted.connect(func(_t: String) -> void: _ask(how_many()))
	count.value_changed.connect(func(_v: float) -> void: _buttons())
	row.add_child(count)
	_make = Button.new()
	_make.name = "Make"
	_make.text = "Сделать"
	_make.pressed.connect(func() -> void: _ask(how_many()))
	row.add_child(_make)
	_note.add_theme_color_override("font_color", Art.TEXT_DIM)
	row.add_child(_note)
	visible = false


## Recipes of the content, by name.
func recipes() -> Array[String]:
	var out: Array[String] = []
	for id: String in content.defs:
		if content.kind_of(id) == "recipe":
			out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	return out


## How many times a recipe can be made from these things (0: not once).
func times(id: String, inventory: Dictionary) -> int:
	if id == "":
		return 0
	var n := 1 << 20
	var inputs: Dictionary = content.get_def(id)["inputs"]
	for item: String in inputs:
		n = mini(n, int(inventory.get(item, 0)) / maxi(1, int(inputs[item])))
	return n if not inputs.is_empty() else 1


## Whether a station of a kind stands within reach, as the client sees it
## (the server says for certain).
func station_near(station: String) -> bool:
	if station == "":
		return true
	var at := Movement.cell_of(client.position)
	for y in range(at.y - 2, at.y + 3):
		for x in range(at.x - 2, at.x + 3):
			var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, x >> 5, y >> 5))
			if c == null:
				continue
			var part := c.get_cell("structure", x & 31, y & 31)
			if part != "" and content.get_def(part).get("station") == station \
					and Vector2(client.position).distance_to(Vector2(x * Movement.UNIT + 128, y * Movement.UNIT + 128)) <= ServerWorld.USE_REACH:
				return true
	return false


## K: every recipe; at a station (E on a workbench), its recipes.
func open(at_station := "") -> void:
	station = at_station
	_title.text = "Ремёсла" if station == "" else "Ремёсла — " + String(STATIONS.get(station, station))
	count.value = 1
	refresh()
	visible = true


## The list again (things changed, one moved to another station).
func refresh() -> void:
	var keep := selected()
	var inventory := client.inventory()
	_list.clear()
	_ids.clear()
	_can.clear()
	var order := recipes()
	if station != "":
		order = order.filter(func(id: String) -> bool: return String(content.get_def(id).get("station", "")) == station)
	for id: String in order:
		_can[id] = times(id, inventory) > 0 and station_near(String(content.get_def(id).get("station", "")))
	order = order.filter(func(id: String) -> bool: return _can[id]) + order.filter(func(id: String) -> bool: return not _can[id])
	for id: String in order:
		var d := content.get_def(id)
		var parts := PackedStringArray()
		for item: String in d["inputs"]:
			parts.append("%s %d" % [_name(item), int(d["inputs"][item])])
		var made := PackedStringArray()
		for item: String in d["outputs"]:
			made.append("%s %d" % [_name(item), int(d["outputs"][item])])
		var station := String(d.get("station", ""))
		var text := "%s: %s → %s" % [d.get("name", id), ", ".join(parts), ", ".join(made)]
		if station != "":
			text += "  [%s]" % STATIONS.get(station, station)
		var first := String(d["outputs"].keys()[0]) if not (d["outputs"] as Dictionary).is_empty() else ""
		var i := _list.add_item(text, view.item_picture(first))
		if not _can[id]:
			_list.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_ids.append(id)
		if id == keep:
			_list.select(i)
	if _list.get_selected_items().is_empty() and not _ids.is_empty():
		_list.select(0)
	_buttons()


func selected() -> String:
	var sel := _list.get_selected_items()
	return _ids[sel[0]] if not sel.is_empty() else ""


func _buttons() -> void:
	var id := selected()
	var ok: bool = id != "" and bool(_can.get(id, false))
	_make.disabled = not ok
	var can := times(id, client.inventory())
	_note.text = "хватит на %d" % can if ok else why_not(id)


## Why a recipe cannot be made here and now ("" — it can).
func why_not(id: String) -> String:
	if id == "":
		return ""
	var d := content.get_def(id)
	var station := String(d.get("station", ""))
	if not station_near(station):
		return "нужен рядом: " + String(STATIONS.get(station, station))
	var inventory := client.inventory()
	var short := PackedStringArray()
	for item: String in d["inputs"]:
		var lack := int(d["inputs"][item]) - int(inventory.get(item, 0))
		if lack > 0:
			short.append("%s %d" % [_name(item), lack])
	return "не хватает: " + ", ".join(short) if not short.is_empty() else ""


## So many as asked, as many as the things allow.
func how_many() -> int:
	return mini(int(count.value), times(selected(), client.inventory()))


func _ask(n: int) -> void:
	var id := selected()
	if id != "" and n > 0 and bool(_can.get(id, false)):
		craft.emit(id, n)


func _name(item: String) -> String:
	return String(content.get_def(item).get("name", item)).to_lower()
