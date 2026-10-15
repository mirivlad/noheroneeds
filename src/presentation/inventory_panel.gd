class_name InventoryPanel
extends PanelContainer
## The things one carries (I): dragged onto a quick slot to have them at hand
## (ADR-0021, 16.10.2026: by dragging, not by a click); a slot dragged back
## here is emptied. Right click drops (Shift all, Ctrl half); G drops one of
## what is in the hands.

## Drop (item, count) on the ground: right click one, Shift all, Ctrl half.
signal drop(item: String, count: int)
## A quick slot was dragged back onto the things: it is emptied.
signal unslot(slot: int)


## The list a thing is dragged out of, onto a quick slot — and where a slot's
## thing is dragged back to.
class DragList:
	extends ItemList
	var ids: Array[String] = []
	var panel: InventoryPanel

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and int(data.get("from_slot", -1)) >= 0

	func _drop_data(_at: Vector2, data: Variant) -> void:
		panel.unslot.emit(int(data["from_slot"]))

	func _get_drag_data(at: Vector2) -> Variant:
		var i := get_item_at_position(at, true)
		if i < 0 and is_anything_selected():
			i = get_selected_items()[0]  # the row the press chose
		if i < 0 or i >= ids.size():
			return null
		var preview := TextureRect.new()
		preview.texture = get_item_icon(i)
		preview.size = Vector2(16, 16)
		if get_viewport() and get_viewport().gui_is_dragging():
			set_drag_preview(preview)
		else:
			preview.free()
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
	_list.panel = self
	_title = Label.new()
	theme = Art.theme()
	custom_minimum_size = Vector2(300, 170)
	var box := VBoxContainer.new()
	add_child(box)
	# The pixel font is drawn at its own size (16) or not at all readable.
	_title.add_theme_font_size_override("font_size", 16)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.custom_minimum_size = Vector2(290, 0)
	box.add_child(_title)
	_list.custom_minimum_size = Vector2(290, 130)
	_list.add_theme_font_override("font", Art.font())
	_list.add_theme_font_size_override("font_size", 16)
	_list.fixed_icon_size = Vector2i(16, 16)
	_list.allow_rmb_select = true
	_list.item_clicked.connect(func(i: int, _at: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			drop_some(_ids[i]))
	box.add_child(_list)
	visible = false


## Right click on a thing: one of it on the ground; with Shift all, with Ctrl half.
func drop_some(id: String) -> void:
	var have := int(_have.get(id, 0))
	var n := have if Input.is_key_pressed(KEY_SHIFT) else (maxi(1, have / 2) if Input.is_key_pressed(KEY_CTRL) else 1)
	drop.emit(id, n)


func show_for(inventory: Dictionary, _slot: int) -> void:
	_title.text = "Вещи. Перетащите в ячейку внизу — будет под рукой; из ячейки сюда — убрать. ПКМ — бросить (Shift — всё, Ctrl — половину)"
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
