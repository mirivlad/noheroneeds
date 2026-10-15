class_name Hotbar
extends HBoxContainer
## The quick slots at the bottom (ADR-0021): nine things the player chose to
## have at hand — a weapon, a tool, a torch, food — one of them in the hands.
## 1-9 or the wheel pick the slot; I opens the things to put into it. Kept
## for each character in the player's settings.

const SLOTS := 9
var content: ContentRegistry
var view: WorldView
## Item ids ("" empty), and the slot in the hands.
var items: Array[String] = []
var selected := 0
## A slot: a thing may be dragged onto it (from the things, or another slot).
class Slot:
	extends Panel
	var bar: Hotbar
	var index := 0

	func _get_drag_data(_at: Vector2) -> Variant:
		var id := bar.items[index]
		if id == "":
			return null
		var preview := TextureRect.new()
		preview.texture = (get_child(0) as TextureRect).texture
		preview.size = Vector2(16, 16)
		if get_viewport() and get_viewport().gui_is_dragging():
			set_drag_preview(preview)
		else:
			preview.free()
		return {"item": id, "from_slot": index}

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.has("item")

	func _drop_data(_at: Vector2, data: Variant) -> void:
		bar.put(index, String(data["item"]), int(data.get("from_slot", -1)))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			bar.select_slot.emit(index)


## The player chose a slot with the mouse; the slots changed (to keep them).
signal select_slot(index: int)
signal changed
var _slots: Array[Panel] = []
## The slot in the hands stands out at once: a bright yellow frame on a
## see-through violet (the author's choice); the others are quiet.
var _chosen_box := _box(Color(0.5, 0.2, 0.75, 0.55), Color(1.0, 0.88, 0.1), 2)
var _slot_box := _box(Color(0.08, 0.07, 0.1, 0.55), Color(0.45, 0.42, 0.4, 0.8), 1)


static func _box(fill: Color, frame: Color, width: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = frame
	b.set_border_width_all(width)
	return b
var _icons: Array[TextureRect] = []
var _counts: Array[Label] = []


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	add_theme_constant_override("separation", 2)
	items.resize(SLOTS)
	items.fill("")
	for i in SLOTS:
		var slot := Slot.new()
		slot.bar = self
		slot.index = i
		slot.custom_minimum_size = Vector2(20, 20)
		var icon := TextureRect.new()
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(2, 2)
		icon.size = Vector2(16, 16)
		slot.add_child(icon)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var count := Label.new()
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count.add_theme_font_override("font", Art.font())
		count.add_theme_font_size_override("font_size", 16)
		count.add_theme_color_override("font_color", Art.TEXT)
		count.add_theme_color_override("font_outline_color", Art.INK)
		count.add_theme_constant_override("outline_size", 2)
		count.position = Vector2(1, 6)
		slot.add_child(count)
		var key := Label.new()
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key.add_theme_font_override("font", Art.font())
		key.add_theme_font_size_override("font_size", 16)
		key.add_theme_color_override("font_color", Art.TEXT_DIM)
		key.add_theme_color_override("font_outline_color", Art.INK)
		key.add_theme_constant_override("outline_size", 2)
		key.text = str(i + 1)
		key.position = Vector2(14, -9)
		slot.add_child(key)
		add_child(slot)
		_slots.append(slot)
		_icons.append(icon)
		_counts.append(count)


## Q (ADR-0021): the weapon last chosen or used comes into the hands; Q again
## gives back what was held before. Remembered by the things, not the slots,
## so moving things between slots, dropping or storing them breaks nothing.
var _weapon_item := ""
var _back_item := ""
var _back_slot := -1
var _snatched := false


## A weapon to fight with (an axe counts: a tool too, but a weapon); a pick
## strikes too, but is a tool first ("improvised").
func is_arm(id: String) -> bool:
	if id == "":
		return false
	var w: Dictionary = content.get_def(id).get("weapon", {})
	return not w.is_empty() and not bool(w.get("improvised", false))


## The player picked a slot (keys, wheel, click).
func choose(slot: int) -> void:
	selected = slot
	_snatched = false
	if is_arm(items[slot]):
		_weapon_item = items[slot]


## A weapon was used: it is the one Q brings next time.
func used(id: String) -> void:
	if is_arm(id):
		_weapon_item = id


## Q. Returns a note for the player ("" when done).
func snatch(inventory: Dictionary) -> String:
	if _snatched and items[selected] == _weapon_item:
		var back := items.find(_back_item) if _back_item != "" else -1
		selected = back if back >= 0 else maxi(_back_slot, 0)
		_snatched = false
		return ""
	var target := items.find(_weapon_item) if _weapon_item != "" else -1
	if target < 0 or not is_arm(items[target]) or int(inventory.get(items[target], 0)) <= 0:
		target = -1
		for i in SLOTS:
			if is_arm(items[i]) and int(inventory.get(items[i], 0)) > 0:
				target = i
				break
	if target < 0:
		return "оружия в ячейках нет (I — положить)"
	if target == selected:
		return "оружие уже в руках"
	_back_item = items[selected]
	_back_slot = selected
	selected = target
	_weapon_item = items[target]
	_snatched = true
	return ""


## The item in the hands: the chosen slot's, if it is carried.
func held(inventory: Dictionary) -> String:
	var id := items[selected]
	return id if id != "" and int(inventory.get(id, 0)) > 0 else ""


## A thing into a slot; dragged from another slot, the two swap.
func put(slot: int, id: String, from_slot: int) -> void:
	var was := items[slot]
	for i in SLOTS:
		if items[i] == id:
			items[i] = ""  # one slot per thing
	items[slot] = id
	if from_slot >= 0 and from_slot != slot:
		items[from_slot] = was
	changed.emit()


## Slots filled for a character seen first: weapons and tools it carries.
func fill_from(inventory: Dictionary) -> void:
	var ids: Array = inventory.keys()
	ids.sort()
	var i := 0
	for id: String in ids:
		var d := content.get_def(id)
		if (d.has("weapon") or d.has("tools")) and i < SLOTS:
			items[i] = id
			i += 1


func refresh(inventory: Dictionary) -> void:
	for i in SLOTS:
		var id := items[i]
		var v := content.visual_of(id) if id != "" else {}
		if v.is_empty():
			_icons[i].texture = null
		else:
			var at := AtlasTexture.new()
			at.atlas = view.texture(v["atlas_path"])
			at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
			_icons[i].texture = at
		var n := int(inventory.get(id, 0)) if id != "" else 0
		_counts[i].text = str(n) if n > 1 else ""
		_icons[i].modulate = Color.WHITE if id == "" or n > 0 else Color(1, 1, 1, 0.35)
		_slots[i].add_theme_stylebox_override("panel", _chosen_box if i == selected else _slot_box)
