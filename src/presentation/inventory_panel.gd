class_name InventoryPanel
extends PanelContainer
## The things one carries (I): a click puts one into the chosen quick slot
## (ADR-0021); G drops one of what is in the hands.

signal chosen(item: String)
var content: ContentRegistry
var view: WorldView
var _list: ItemList
var _title: Label
var _ids: Array[String] = []


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	_list = ItemList.new()
	_title = Label.new()
	theme = Art.theme()
	custom_minimum_size = Vector2(220, 160)
	var box := VBoxContainer.new()
	add_child(box)
	_title.add_theme_font_size_override("font_size", 16)
	box.add_child(_title)
	_list.custom_minimum_size = Vector2(210, 130)
	_list.add_theme_font_override("font", Art.font())
	_list.add_theme_font_size_override("font_size", 16)
	_list.fixed_icon_size = Vector2i(16, 16)
	_list.item_clicked.connect(func(i: int, _at: Vector2, _button: int) -> void: chosen.emit(_ids[i]))
	box.add_child(_list)
	visible = false


func show_for(inventory: Dictionary, slot: int) -> void:
	_title.text = "Вещи — щёлкните, чтобы взять в ячейку %d" % (slot + 1)
	_list.clear()
	_ids.clear()
	var ids: Array = inventory.keys()
	ids.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	for id: String in ids:
		var v := content.visual_of(id)
		var icon: Texture2D = null
		if not v.is_empty():
			var at := AtlasTexture.new()
			at.atlas = view.texture(v["atlas_path"])
			at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
			icon = at
		_list.add_item("%s  ×%d" % [content.get_def(id).get("name", id), int(inventory[id])], icon)
		_ids.append(id)
	visible = true
