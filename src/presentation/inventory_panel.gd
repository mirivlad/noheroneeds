class_name InventoryPanel
extends PanelContainer
## The things one carries (I): a click puts one into the chosen quick slot
## (ADR-0021); G drops one of what is in the hands.

signal chosen(item: String)
## Drop (item, count) on the ground: right click one, Shift all, Ctrl half.
signal drop(item: String, count: int)


## The list a thing is dragged out of, onto a quick slot.
class DragList:
	extends ItemList
	var ids: Array[String] = []

	func _get_drag_data(at: Vector2) -> Variant:
		var i := get_item_at_position(at, true)
		if i < 0 or i >= ids.size():
			return null
		var preview := TextureRect.new()
		preview.texture = get_item_icon(i)
		preview.size = Vector2(16, 16)
		set_drag_preview(preview)
		return {"item": ids[i]}


var content: ContentRegistry
var view: WorldView
var _list: DragList
var _title: Label
var _ids: Array[String] = []
var _have := {}


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	_list = DragList.new()
	_title = Label.new()
	theme = Art.theme()
	custom_minimum_size = Vector2(260, 160)
	var box := VBoxContainer.new()
	add_child(box)
	_title.add_theme_font_size_override("font_size", 8)
	box.add_child(_title)
	_list.custom_minimum_size = Vector2(210, 130)
	_list.add_theme_font_override("font", Art.font())
	_list.add_theme_font_size_override("font_size", 16)
	_list.fixed_icon_size = Vector2i(16, 16)
	_list.allow_rmb_select = true
	_list.item_clicked.connect(func(i: int, _at: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			var have := int(_have.get(_ids[i], 0))
			var n := have if Input.is_key_pressed(KEY_SHIFT) else (maxi(1, have / 2) if Input.is_key_pressed(KEY_CTRL) else 1)
			drop.emit(_ids[i], n)
		else:
			chosen.emit(_ids[i]))
	box.add_child(_list)
	visible = false


func show_for(inventory: Dictionary, slot: int) -> void:
	_title.text = "Вещи: щелчок или перетаскивание — в ячейку %d, ПКМ — бросить (Shift — всё, Ctrl — половину)" % (slot + 1)
	_have = inventory
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
	_list.ids = _ids
	visible = true
