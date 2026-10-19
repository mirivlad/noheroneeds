class_name BuildCatalog
extends PanelContainer
## The building catalogue (B, ADR-0021): every part one may build, from the
## content (no list in the code), in groups; a choice becomes a blueprint
## under the cursor. "Разобрать" is a tool of its own here, not a stray
## right click.

signal chosen(part: String)
const DEMOLISH := "~demolish"
## Groups by role, unless a part names its own "category".
const GROUPS := {"wall": "Стены и проёмы", "door": "Стены и проёмы", "window": "Стены и проёмы",
	"fence": "Стены и проёмы", "column": "Стены и проёмы", "beam": "Стены и проёмы",
	"ceiling": "Перекрытия и крыши", "roof": "Перекрытия и крыши",
	"stairs": "Лестницы и ходы", "shaft": "Лестницы и ходы", "furniture": "Обстановка"}
var content: ContentRegistry
var view: WorldView
var _tabs: HBoxContainer
var _list: ItemList
var _group := ""
var _ids: Array[String] = []


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	_tabs = HBoxContainer.new()
	_list = ItemList.new()
	theme = Art.theme()
	custom_minimum_size = Vector2(240, 170)
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "Строительство  (B — закрыть)"
	box.add_child(title)
	box.add_child(_tabs)
	_list.custom_minimum_size = Vector2(230, 110)
	_list.add_theme_font_override("font", Art.font())
	_list.add_theme_font_size_override("font_size", 16)
	_list.fixed_icon_size = Vector2i(16, 16)
	_list.item_clicked.connect(func(i: int, _at: Vector2, _button: int) -> void: chosen.emit(_ids[i]))
	box.add_child(_list)
	var demolish := Button.new()
	demolish.text = "Разобрать своё"
	demolish.pressed.connect(func() -> void: chosen.emit(DEMOLISH))
	box.add_child(demolish)
	for g: String in groups():
		var b := Button.new()
		b.text = g
		b.add_theme_font_size_override("font_size", 8)
		b.pressed.connect(func() -> void: _show(g, _inventory))
		_tabs.add_child(b)
	visible = false


var _inventory := {}


static func group_of(def: Dictionary) -> String:
	return String(def.get("category", GROUPS.get(String(def.get("role", "")), "Прочее")))


func groups() -> Array:
	var out := []
	for id in buildable():
		var g := group_of(content.get_def(id))
		if not out.has(g):
			out.append(g)
	return out


## Parts one can build: structures that are not natural, by name.
func buildable() -> Array:
	var out := []
	for id: String in content.defs:
		if content.kind_of(id) == "structure" and not content.get_def(id).get("natural", false):
			out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	return out


func open(inventory: Dictionary) -> void:
	_inventory = inventory
	_show(_group if _group != "" else String(groups()[0]), inventory)
	visible = true


func _show(group: String, inventory: Dictionary) -> void:
	_group = group
	_list.clear()
	_ids.clear()
	for id: String in buildable():
		var d := content.get_def(id)
		if group_of(d) != group:
			continue
		var cost := content.structure_cost(id)
		var parts := PackedStringArray()
		var enough := true
		for m: String in cost:
			parts.append("%s %d" % [String(content.get_def(m).get("name", m)).to_lower(), int(cost[m])])
			enough = enough and int(inventory.get(m, 0)) >= int(cost[m])
		var v := content.visual_of(id)
		var icon: Texture2D = null
		if not v.is_empty():
			var at := AtlasTexture.new()
			at.atlas = view.texture(v["atlas_path"])
			# The top of a tall picture, a cell wide (LPC sheets are twice as fine).
			var px := 1.0 / float(v.get("pixel_scale", 1.0))
			at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], mini(int(v["rect"][3]), int(32 * px)))
			icon = at
		var i := _list.add_item("%s — %s" % [d.get("name", id), ", ".join(parts)], icon)
		if not enough:
			_list.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_ids.append(id)
