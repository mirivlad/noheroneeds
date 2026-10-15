class_name ChestPanel
extends PanelContainer
## A container opened (ADR-0021): one's things on the left, its contents on
## the right. A click moves one; with Shift all of it; with Ctrl half (a
## stack split). The server says what is in it after every move.

## (item, count, into the container?)
signal move(item: String, count: int, putting: bool)
var content: ContentRegistry
var view: WorldView
## The container's cell (on the client's location) while it is open.
var cell := Vector2i.ZERO
var contents := {}
var slots := 0
var _mine: ItemList
var _theirs: ItemList
var _title: Label
var _mine_ids: Array[String] = []
var _their_ids: Array[String] = []
var _inventory := {}


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	_mine = ItemList.new()
	_theirs = ItemList.new()
	_title = Label.new()
	theme = Art.theme()
	var box := VBoxContainer.new()
	add_child(box)
	box.add_child(_title)
	var row := HBoxContainer.new()
	box.add_child(row)
	for l: ItemList in [_mine, _theirs]:
		l.custom_minimum_size = Vector2(170, 130)
		l.add_theme_font_override("font", Art.font())
		l.add_theme_font_size_override("font_size", 16)
		l.fixed_icon_size = Vector2i(16, 16)
		row.add_child(l)
	_mine.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void: _pick(_mine_ids[i], _inventory, true))
	_theirs.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void: _pick(_their_ids[i], contents, false))
	var hint := Label.new()
	hint.text = "щелчок — одну, Shift — всё, Ctrl — половину; E или Esc — закрыть"
	hint.add_theme_font_size_override("font_size", 8)
	box.add_child(hint)
	visible = false


func _pick(id: String, from: Dictionary, putting: bool) -> void:
	var have := int(from.get(id, 0))
	var n := 1
	if Input.is_key_pressed(KEY_SHIFT):
		n = have
	elif Input.is_key_pressed(KEY_CTRL):
		n = maxi(1, have / 2)
	if have > 0:
		move.emit(id, n, putting)


func open_at(at: Vector2i, what: Dictionary, room: int, inventory: Dictionary) -> void:
	cell = at
	contents = what
	slots = room
	refresh(inventory)
	visible = true


func refresh(inventory: Dictionary) -> void:
	_inventory = inventory
	_title.text = "Ваши вещи                       Сундук (%d ячеек)" % slots
	_fill(_mine, _mine_ids, inventory)
	_fill(_theirs, _their_ids, contents)


func _fill(list: ItemList, ids: Array[String], stacks: Dictionary) -> void:
	list.clear()
	ids.clear()
	var all: Array = stacks.keys()
	all.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	for id: String in all:
		var v := content.visual_of(id)
		var icon: Texture2D = null
		if not v.is_empty():
			var at := AtlasTexture.new()
			at.atlas = view.texture(v["atlas_path"])
			at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
			icon = at
		list.add_item("%s ×%d" % [content.get_def(id).get("name", id), int(stacks[id])], icon)
		ids.append(id)
