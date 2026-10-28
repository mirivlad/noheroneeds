class_name TradePanel
extends PanelContainer
## Trade with a dweller (ADR-0040): its goods on the left (in stock, price),
## what it buys on the right (what one carries of it, price); one's coins
## and its purse. A click buys or sells one; with Shift five. The server
## says the goods again after every deal.

## (item, count, buying?, which copy one sells: -1 any — ADR-0046)
signal deal(item: String, count: int, buying: bool, copy: int)
## A blueprint of a recipe bought (ADR-0047).
signal buy_blueprint(recipe: String)
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
## Each carried copy's state (the client's item_states).
var _states := {}


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
	box.add_child(Art.window_head(_title, "E", hide))
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
		if _their_ids[i].begins_with("sheet|"):
			buy_blueprint.emit(_their_ids[i].substr(6))
		else:
			deal.emit(_their_ids[i], 5 if Input.is_key_pressed(KEY_SHIFT) else 1, true, -1))
	_mine.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void:
		var id := _mine_ids[i]
		if id.begins_with("copy|"):  # a thing of its own: that copy, at its own price; Shift — every one
			var p := id.split("|")
			if Input.is_key_pressed(KEY_SHIFT):
				deal.emit(p[1], int(_inventory.get(p[1], 0)), false, -1)
			else:
				deal.emit(p[1], 1, false, int(p[2]))
		else:
			deal.emit(id, mini(int(_inventory.get(id, 0)), 5 if Input.is_key_pressed(KEY_SHIFT) else 1), false, -1))
	box.add_child(_money)
	var hint := Label.new()
	hint.text = "щелчок — одну, Shift — пять"
	hint.add_theme_color_override("font_color", Art.TEXT_DIM)
	box.add_child(hint)
	visible = false


func open_for(id: String, what: Dictionary, inventory: Dictionary, states := {}) -> void:
	creature = id
	goods = what
	refresh(inventory, states)
	visible = true


func refresh(inventory: Dictionary, states := {}) -> void:
	_inventory = inventory
	_states = states
	var trade := String(content.get_def(String(goods.get("profession", ""))).get("name", "Житель"))
	_title.text = "Торговля — %s" % trade.to_lower()
	_money.text = "Ваши монеты: %d     У него в кошельке: %d" % [int(inventory.get(COIN, 0)), int(goods.get("purse", 0))]
	_theirs.clear()
	_their_ids.clear()
	var sells: Dictionary = goods.get("sells", {})
	for id: String in _sorted(sells.keys()):
		var cheap: bool = (goods.get("plenty", []) as Array).has(id)
		var i := _theirs.add_item("%s ×%d — %d%s" % [content.get_def(id).get("name", id), int(sells[id][0]), int(sells[id][1]),
			"  ↓ вдоволь" if cheap else ""], view.item_picture(id))
		# How well its goods are made (ADR-0047): the card of the next one.
		var made: Dictionary = sells[id][2] if (sells[id] as Array).size() > 2 and typeof(sells[id][2]) == TYPE_DICTIONARY else {}
		_theirs.set_item_tooltip(i, ItemCard.text(content, id, made) + ("\nВ деревне этого вдоволь: дешевле" if cheap else ""))
		if int(sells[id][0]) <= 0 or int(inventory.get(COIN, 0)) < int(sells[id][1]):
			_theirs.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_their_ids.append(id)
	var sheets: Dictionary = goods.get("blueprints", {})
	for r: String in _sorted(sheets.keys()):
		var i := _theirs.add_item("Чертёж: %s — %d" % [content.get_def(r).get("name", r), int(sheets[r])], view.item_picture("base:blueprint"))
		_theirs.set_item_tooltip(i, ItemCard.text(content, "base:blueprint", {"recipe": r}))
		if int(inventory.get(COIN, 0)) < int(sheets[r]):
			_theirs.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_their_ids.append("sheet|" + r)
	_mine.clear()
	_mine_ids.clear()
	var buys: Dictionary = goods.get("buys", {})
	for id: String in _sorted(buys.keys()):
		var have := int(inventory.get(id, 0))
		# Things of their own sell each at what it is worth (ADR-0046, ADR-0047).
		var copies: Array = states.get(id, [])
		if have > 0 and not copies.is_empty():
			for k in have:
				var st: Dictionary = copies[k] if k < copies.size() and typeof(copies[k]) == TYPE_DICTIONARY else {}
				var price := price_of(id, st)
				var line := "%s, %d%% — %d" % [content.get_def(id).get("name", id), roundi(Wear.condition(content, id, st) * 100.0), price]
				var at := _mine.add_item(line, view.item_picture(id))
				_mine.set_item_tooltip(at, ItemCard.text(content, id, st))
				if int(goods.get("purse", 0)) < price:
					_mine.set_item_custom_fg_color(at, Color(Art.TEXT_DIM, 0.6))
				_mine_ids.append("copy|%s|%d" % [id, k])
			continue
		var wanted: bool = (goods.get("short", []) as Array).has(id)
		var i := _mine.add_item("%s ×%d — %d%s" % [content.get_def(id).get("name", id), have, int(buys[id]), "  ↑ нужно деревне" if wanted else ""],
			view.item_picture(id))
		if wanted:
			_mine.set_item_tooltip(i, "Деревне этого не хватает: платят дороже")
		if have <= 0 or int(goods.get("purse", 0)) < int(buys[id]):
			_mine.set_item_custom_fg_color(i, Color(Art.TEXT_DIM, 0.6))
		_mine_ids.append(id)


## What the dweller pays for a copy: its price, as the copy is worth.
func price_of(item: String, state: Dictionary) -> int:
	return maxi(1, roundi(int((goods.get("buys", {}) as Dictionary).get(item, 0)) * Wear.value(content, item, state)))


func _sorted(ids: Array) -> Array:
	ids.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	return ids
