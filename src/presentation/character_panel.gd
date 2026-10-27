class_name CharacterPanel
extends PanelContainer
## RPG equipment window (C): the doll, worn slots, and the actual inventory.

signal wear(item: String, copy: int)
signal take_off(slot: String)
signal drop(item: String, count: int, copy: int)
signal unslot(slot: int)

const SLOTS := {"headwear": "Голова", "torso": "Торс", "armor": "Доспех", "legs": "Ноги", "feet": "Обувь", "back_item": "Спина", "belt": "Пояс", "main_hand": "В руках"}

class EquipmentSlot:
	extends Button
	var slot := ""
	var item := ""
	var panel: CharacterPanel

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		if typeof(data) != TYPE_DICTIONARY or not data.has("item") or data.has("equipment_slot"):
			return false
		return slot == "main_hand" or panel.content.get_def(String(data["item"])).get("equip_slot", "") == slot

	func _drop_data(_at: Vector2, data: Variant) -> void:
		panel.wear.emit(String(data["item"]), int(data.get("copy", -1)))

	func _get_drag_data(_at: Vector2) -> Variant:
		return {"equipment_slot": slot, "item": item} if item != "" else null

var content: ContentRegistry
var _view: WorldView
var bag := InventoryPanel.new()
var preview := CharacterPreview.new()
var _title := Label.new()
var _slots := {}
var _seen := 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [bag, preview, _title]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()


func setup(registry: ContentRegistry, view: WorldView) -> void:
	content = registry
	_view = view
	theme = Art.theme()
	custom_minimum_size = Vector2(456, 0)
	var box := VBoxContainer.new()
	add_child(box)
	box.add_child(Art.window_head(_title, "C", hide))
	var columns := HBoxContainer.new()
	box.add_child(columns)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 204
	columns.add_child(left)
	preview.custom_minimum_size = Vector2(204, 200)
	preview.walking = false
	left.add_child(preview)
	var grid := GridContainer.new()
	grid.columns = 2
	left.add_child(grid)
	for slot: String in SLOTS:
		var b := EquipmentSlot.new()
		b.slot = slot
		b.panel = self
		b.name = "Equip_" + slot
		b.custom_minimum_size = Vector2(99, 52)
		b.add_theme_font_size_override("font_size", 16)
		b.clip_text = true
		var bar := WearBar.new()
		bar.name = "Wear"
		bar.position = Vector2(6, 44)
		bar.size = Vector2(87, 4)
		b.add_child(bar)
		b.pressed.connect(func() -> void:
			if b.item != "":
				take_off.emit(b.slot))
		grid.add_child(b)
		_slots[slot] = b
	bag.setup(content, view, true)
	bag.wear.connect(func(item: String, copy: int) -> void: wear.emit(item, copy))
	bag.take_off.connect(func(slot: String) -> void: take_off.emit(slot))
	bag.drop.connect(func(item: String, n: int, copy: int) -> void: drop.emit(item, n, copy))
	bag.unslot.connect(func(slot: int) -> void: unslot.emit(slot))
	columns.add_child(bag)
	visible = false


func show_for(own: Dictionary, held: String) -> void:
	visible = true
	var state := [own.get("appearance", {}), own.get("inventory", {}), own.get("name", ""), held,
		own.get("states", {}), own.get("worn_states", {})].hash()
	if state == _seen:
		return
	_seen = state
	var look: Dictionary = own.get("appearance", {"body_plan": "base:human_m"})
	_title.text = "Персонаж: " + String(own.get("name", ""))
	var armor := 0
	var worn_states: Dictionary = own.get("worn_states", {})
	for slot: String in (look.get("worn", {}) as Dictionary):
		var item := String(look["worn"][slot])
		if not Wear.broken(content, item, worn_states.get(slot, {})):  # broken armour keeps nothing off
			armor += int(content.get_def(item).get("armor", 0))
	if armor > 0:
		_title.text += ", защита %d" % armor  # off every blow (ADR-0029)
	preview.show_look(content, look)
	# Twice the size of the world's: a pixel of the picture is 2x2 on the screen.
	preview.doll.scale = Vector2.ONE * 2.0 / maxf(0.5, float(content.visual_of(String(look.get("body_plan", ""))).get("pixel_scale", 1.0)))
	preview.doll.position = Vector2(102, 170)
	preview.doll.hold(_view.item_picture(held), _view.item_grip(held), held)
	var worn: Dictionary = look.get("worn", {})
	for slot: String in _slots:
		var b: EquipmentSlot = _slots[slot]
		b.item = held if slot == "main_hand" else String(worn.get(slot, ""))
		b.text = SLOTS[slot] + ("" if b.item != "" else " —")
		b.icon = _view.item_picture(b.item) if b.item != "" else null
		# The copy in the hands is the first one carried; worn ones keep their own.
		var st: Dictionary = worn_states.get(slot, {})
		if slot == "main_hand":
			var mine: Array = (own.get("states", {}) as Dictionary).get(held, [])
			st = mine[0] if not mine.is_empty() else {}
		(b.get_node("Wear") as WearBar).show_state(content, b.item, st)
		b.tooltip_text = SLOTS[slot] + ": " + (ItemCard.text(content, b.item, st) + "\nНажать или перетащить в инвентарь, чтобы снять" if b.item != "" else "перетащите вещь из инвентаря")
	bag.show_for(own.get("inventory", {}), 0, own.get("states", {}))
