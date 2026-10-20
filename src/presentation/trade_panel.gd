class_name TradePanel
extends PanelContainer
## Trade with a dweller (ADR-0040): its goods on the left (in stock, price),
## what it buys on the right (what one carries of it, price); one's coins
## and its purse. A click buys or sells one; with Shift five. The server
## says the goods again after every deal.

## (item, count, buying?)
signal deal(item: String, count: int, buying: bool)
const COIN := "base:coin"
var content: ContentRegistry
var view: WorldView
## The dweller traded with (an entity id) while it is open.
var creature := ""
var goods := {}
var _theirs: ItemList
var _mine: ItemList
var _title: Label
var _money: Label
var _their_ids: Array[String] = []
var _mine_ids: Array[String] = []
var _inventory := {}


func setup(registry: ContentRegistry, world_view: WorldView) -> void:
	content = registry
	view = world_view
	theme = Art.theme()
	_theirs = ItemList.new()
	_mine = ItemList.new()
	_title = Label.new()
	_money = Label.new()
	var box := VBoxContainer.new()
	add_child(box)
	box.add_child(_title)
	var heads := HBoxContainer.new()
	box.add_child(heads)
	for t: String in ["Купить", "Продать"]:
		var l := Label.new()
		l.text = t
		l.custom_minimum_size.x = 214
		heads.add_child(l)
	var row := HBoxContainer.new()
	box.add_child(row)
	for l: ItemList in [_theirs, _mine]:
		l.custom_minimum_size = Vector2(210, 190)
		l.add_theme_font_override("font", Art.font())
		l.add_theme_font_size_override("font_size", 16)
		l.fixed_icon_size = Vector2i(32, 32)
		row.add_child(l)
	_theirs.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void:
		deal.emit(_their_ids[i], 5 if Input.is_key_pressed(KEY_SHIFT) else 1, true))
	_mine.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void:
		var id := _mine_ids[i]
		deal.emit(id, mini(int(_inventory.get(id, 0)), 5 if Input.is_key_pressed(KEY_SHIFT) else 1), false))
	box.add_child(_money)
	var hint := Label.new()
	hint.text = "щелчок — одну, Shift — пять; E или Esc — закрыть"
	hint.add_theme_font_size_override("font_size", 8)
	box.add_child(hint)
	visible = false


func open_for(id: String, what: Dictionary, inventory: Dictionary) -> void:
	creature = id
	goods = what
	refresh(inventory)
	visible = true


func refresh(inventory: Dictionary) -> void:
	_inventory = inventory
	var trade := String(content.get_def(String(goods.get("profession", ""))).get("name", "Житель"))
	_title.text = "Торговля — %s" % trade.to_lower()
	_money.text = "Ваши монеты: %d     У него в кошельке: %d" % [int(inventory.get(COIN, 0)), int(goods.get("purse", 0))]
	_theirs.clear()
	_their_ids.clear()
	var sells: Dictionary = goods.get("sells", {})
	for id: String in _sorted(sells.keys()):
		var i := _theirs.add_item("%s ×%d — %d" % [content.get_def(id).get("name", id), int(sells[id][0]), int(sells[id][1])],
			view.item_picture(id))
		if int(sells[id][0]) <= 0 or int(inventory.get(COIN, 0)) < int(sells[id][1]):
			_theirs.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_their_ids.append(id)
	_mine.clear()
	_mine_ids.clear()
	var buys: Dictionary = goods.get("buys", {})
	for id: String in _sorted(buys.keys()):
		var have := int(inventory.get(id, 0))
		var i := _mine.add_item("%s ×%d — %d" % [content.get_def(id).get("name", id), have, int(buys[id])], view.item_picture(id))
		if have <= 0 or int(goods.get("purse", 0)) < int(buys[id]):
			_mine.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_mine_ids.append(id)


func _sorted(ids: Array) -> Array:
	ids.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	return ids
