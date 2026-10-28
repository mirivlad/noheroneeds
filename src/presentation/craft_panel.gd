class_name CraftPanel
extends PanelContainer
## Crafts and skills (K; ADR-0026, ADR-0047). On the left the skills, each
## with its level: choosing one shows what one knows of it — its recipes
## (no list in the code: the content's), each with one's mastery and chance,
## what it takes and makes and at which station; for a skill that is not a
## craft (woodcutting, melee...) what it gives now. Besides: "Все" — every
## recipe one knows, "Чертежи" — the blueprints one carries (made by once,
## sure and whole, or studied for good), "Починка" — worn things to mend at
## their stations (ADR-0046). What one can do here and now comes first. The
## server decides; this only asks.
##
## UI 2.0: a search over the lines (a recipe's name, what it takes and
## makes), short lines (the name and how many it makes, or why not), and the
## chosen line's card beside them: what it takes (had / needed), makes, where,
## the chance and mastery; with no line a skill's card.

signal craft(recipe: String, count: int)
## Mend a thing: the request's fields ({"item", "copy"} or {"slot"}).
signal mend(request: Dictionary)
## Any other ask: by a blueprint, studying one, drafting one (a request).
signal ask(request: Dictionary)
## Names of the kinds of stations, for people.
const STATIONS := {"workbench": "верстак", "forge": "печь", "fire": "костёр"}
const ALL := "all"
const SHEETS := "sheets"
const MENDING := "mending"
const BLUEPRINT := "base:blueprint"
var content: ContentRegistry
var view: WorldView
var client: GameClient
var _skills: ItemList
var _list: ItemList
var _skill_ids: Array[String] = []
var _ids: Array[String] = []
var _can := {}
## Lines that mend a thing: key ("mend:n") -> {"item", "state", "copy" or "slot"}.
var _mends := {}
## Lines of a carried blueprint: key ("sheet:n") -> {"recipe", "copy"}.
var _sheets := {}
var _make: Button
var _second: Button
## How many to make: so many as asked, or as many as the things allow.
var count: SpinBox
var _note := Label.new()
var _title := Label.new()
var _about := Label.new()
## The search over the lines; what is typed there ("" — all).
var search := LineEdit.new()
## The kind of station the window was opened at ("" — K: every recipe).
var station := ""
## The skill chosen on the left (ALL, SHEETS, MENDING or a skill id).
var chosen := ALL
const SKILLS_WIDTH := 190
const LIST_WIDTH := 250
const CARD_WIDTH := 250


func _notification(what: int) -> void:
	# Made up front but never added (a window never set up): freed too.
	if what == NOTIFICATION_PREDELETE:
		for node: Node in [_note, _title, _about, search]:
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
	var columns := HBoxContainer.new()
	box.add_child(columns)
	_skills = ItemList.new()
	_skills.name = "Skills"
	_skills.custom_minimum_size = Vector2(SKILLS_WIDTH, 300)
	_skills.item_selected.connect(func(i: int) -> void:
		chosen = _skill_ids[i]
		refresh())
	columns.add_child(_skills)
	var middle := VBoxContainer.new()
	columns.add_child(middle)
	search.name = "Search"
	search.placeholder_text = "Поиск: название, материал…"
	search.clear_button_enabled = true
	search.custom_minimum_size.x = LIST_WIDTH
	search.text_changed.connect(func(_t: String) -> void: refresh())
	middle.add_child(search)
	_list = ItemList.new()
	_list.name = "Recipes"
	_list.custom_minimum_size = Vector2(LIST_WIDTH, 300)
	_list.fixed_icon_size = Vector2i(32, 32)
	_list.item_selected.connect(func(_i: int) -> void: _buttons())
	_list.item_activated.connect(func(_i: int) -> void: _ask(how_many()))
	middle.add_child(_list)
	var right := VBoxContainer.new()
	columns.add_child(right)
	_about.name = "Card"
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about.custom_minimum_size = Vector2(CARD_WIDTH, 300)
	_about.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_about.add_theme_stylebox_override("normal", Art.hud_box())
	right.add_child(_about)
	var row := HBoxContainer.new()
	right.add_child(row)
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
	_second = Button.new()
	_second.name = "Second"
	_second.visible = false
	_second.pressed.connect(_ask_second)
	row.add_child(_second)
	_note.add_theme_color_override("font_color", Art.TEXT_DIM)
	right.add_child(_note)
	visible = false


## Recipes of the content one knows, by name.
func recipes() -> Array[String]:
	var out: Array[String] = []
	for id: String in content.defs:
		if content.kind_of(id) == "recipe" and client.knows(content, id):
			out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return String(content.get_def(a).get("name", a)) < String(content.get_def(b).get("name", b)))
	return out


## Skills of the content, in their order.
func skills() -> Array[String]:
	var out: Array[String] = []
	for id: String in content.defs:
		if content.kind_of(id) == "skill":
			out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool:
		return int(content.get_def(a).get("order", 0)) < int(content.get_def(b).get("order", 0)))
	return out


## How many times a recipe can be made from these things (0: not once).
func times(id: String, inventory: Dictionary) -> int:
	if id == "" or content.kind_of(id) != "recipe":
		return 1 if _mends.has(id) or _sheets.has(id) else 0
	var n := 1 << 20
	var inputs: Dictionary = content.get_def(id)["inputs"]
	for item: String in inputs:
		n = mini(n, int(inventory.get(item, 0)) / maxi(1, int(inputs[item])))
	return n if not inputs.is_empty() else 1


## Whether a station of a kind stands within reach, as the client sees it
## (the server says for certain).
func station_near(kind: String) -> bool:
	if kind == "":
		return true
	var at := Movement.cell_of(client.position)
	for y in range(at.y - 2, at.y + 3):
		for x in range(at.x - 2, at.x + 3):
			var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, x >> 5, y >> 5))
			if c == null:
				continue
			var part := c.get_cell("structure", x & 31, y & 31)
			if part != "" and content.get_def(part).get("station") == kind \
					and Vector2(client.position).distance_to(Vector2(x * Movement.UNIT + 128, y * Movement.UNIT + 128)) <= ServerWorld.USE_REACH:
				return true
	return false


## K: everything one knows; at a station (E on a workbench), its recipes;
## `on`: the part on the left to show first (SHEETS for one's blueprints).
func open(at_station := "", on := ALL) -> void:
	station = at_station
	chosen = on
	_title.text = "Ремёсла и навыки" if station == "" else "Ремёсла — " + String(STATIONS.get(station, station))
	count.value = 1
	search.text = ""
	refresh()
	visible = true


## The chance one makes a recipe now, and one's mastery of it.
func chance_of(id: String) -> float:
	var d := content.get_def(id)
	return Mastery.chance(int(d.get("difficulty", 0)), client.mastery_level(id), client.skill_level(String(d.get("skill", ""))))


## The lists again (things changed, one moved to another station).
func refresh() -> void:
	_fill_skills()
	var keep := selected()
	var inventory := client.inventory()
	_list.clear()
	_ids.clear()
	_can.clear()
	_mends.clear()
	_sheets.clear()
	_about.text = ""
	var order: Array[String] = []
	if chosen == MENDING or (chosen == ALL and station != ""):
		order.append_array(_mend_lines())
	if chosen == SHEETS or chosen == ALL:
		order.append_array(_sheet_lines())
	if chosen != MENDING and chosen != SHEETS:
		var known := recipes().filter(func(id: String) -> bool:
			return (chosen == ALL or String(content.get_def(id).get("skill", "")) == chosen) \
				and (station == "" or String(content.get_def(id).get("station", "")) == station))
		for id: String in known:
			_can[id] = times(id, inventory) > 0 and station_near(String(content.get_def(id).get("station", "")))
		order.append_array(known)
	for id: String in order:
		if not _can.has(id):
			_can[id] = why_not(id) == ""
	var looking := search.text.strip_edges().to_lower()
	if looking != "":
		order = order.filter(func(id: String) -> bool: return _words_of(id).contains(looking))
	order = order.filter(func(id: String) -> bool: return _can[id]) + order.filter(func(id: String) -> bool: return not _can[id])
	for id: String in order:
		var at := _list.add_item(_line(id), view.item_picture(_picture_of(id)))
		if not _can[id]:
			_list.set_item_custom_fg_color(at, Color(Art.TEXT_DIM, 0.6))
		_ids.append(id)
		if id == keep:
			_list.select(at)
	if _list.get_selected_items().is_empty() and not _ids.is_empty():
		_list.select(0)
	_buttons()


func _fill_skills() -> void:
	var keep := chosen
	_skills.clear()
	_skill_ids.clear()
	var add := func(id: String, text: String) -> void:
		var i := _skills.add_item(text)
		_skill_ids.append(id)
		if id == keep:
			_skills.select(i)
	add.call(ALL, "Все рецепты")
	add.call(SHEETS, "Чертежи (%d)" % int(client.inventory().get(BLUEPRINT, 0)))
	add.call(MENDING, "Починка")
	for id: String in skills():
		add.call(id, "%s — %d" % [content.get_def(id).get("name", id), client.skill_level(id)])


## What a skill gives now and how many of its recipes one does not know yet.
func _about_skill() -> String:
	if content.kind_of(chosen) != "skill":
		return ""
	var d := content.get_def(chosen)
	var level := client.skill_level(chosen)
	var parts := PackedStringArray()
	var effects: Dictionary = d.get("effects", {})
	for name: String in effects:
		var v := Mastery.effect(content, chosen, level, name)
		match name:
			"pace":
				parts.append("быстрее на %d%%" % roundi((1.0 - v) * 100.0))
			"wear":
				parts.append("износ меньше на %d%%" % roundi((1.0 - v) * 100.0))
			"chance":
				parts.append("удача больше на %d%%" % roundi((v - 1.0) * 100.0))
			"damage":
				parts.append("урон +%.1f" % v)
			"yield":
				parts.append("лишняя добыча: %d%%" % roundi(v * 100.0))
	var text := "%s. Уровень %d." % [d.get("description", ""), level]
	if not parts.is_empty():
		text += " Сейчас: " + ", ".join(parts) + "."
	var unknown := 0
	for id: String in content.defs:
		if content.kind_of(id) == "recipe" and String(content.get_def(id).get("skill", "")) == chosen and not client.knows(content, id):
			unknown += 1
	if unknown > 0:
		text += " Ещё рецептов: %d — у мастеров в деревнях и в чертежах." % unknown
	return text


func _picture_of(id: String) -> String:
	if _mends.has(id):
		return String(_mends[id]["item"])
	if _sheets.has(id):
		return BLUEPRINT
	var outs: Dictionary = content.get_def(id).get("outputs", {})
	return String(outs.keys()[0]) if not outs.is_empty() else ""


## A line of the list: the name, and how many can be made (or that it can't).
func _line(id: String) -> String:
	if _mends.has(id):
		var m: Dictionary = _mends[id]
		return "Починить: %s%s, %d%%" % [content.get_def(String(m["item"])).get("name", m["item"]), " (надето)" if m.has("slot") else "",
			floori(Wear.condition(content, String(m["item"]), m["state"]) * 100.0 + 0.5)]
	if _sheets.has(id):
		var r := String(_sheets[id]["recipe"])
		return "Чертёж: %s%s" % [content.get_def(r).get("name", r), " ✓" if client.knows(content, r) else ""]
	var n := times(id, client.inventory())
	return "%s%s" % [content.get_def(id).get("name", id), "  ×%d" % n if bool(_can.get(id, false)) and n > 1 else ""]


## What a line is found by: its name, what it takes and makes.
func _words_of(id: String) -> String:
	var r := String(_sheets[id]["recipe"]) if _sheets.has(id) else (String(_mends[id]["item"]) if _mends.has(id) else id)
	var d := content.get_def(r)
	var words := PackedStringArray([String(d.get("name", r))])
	for key: String in ["inputs", "outputs"]:
		for item: String in d.get(key, {}):
			words.append(_name(item))
	return " ".join(words).to_lower()


## The chosen line's card; with none, the chosen skill's.
func _card(id: String) -> String:
	if id == "":
		return _about_skill()
	if _mends.has(id):
		return _mend_text(_mends[id]) + "\n\n" + ItemCard.text(content, String(_mends[id]["item"]), _mends[id]["state"])
	var r := String(_sheets[id]["recipe"]) if _sheets.has(id) else id
	var d := content.get_def(r)
	var lines := PackedStringArray([String(d.get("name", r)) + (" — по чертежу" if _sheets.has(id) else "")])
	var made := PackedStringArray()
	for item: String in d["outputs"]:
		made.append("%s ×%d" % [_name(item), int(d["outputs"][item])])
	lines.append("Получится: " + ", ".join(made))
	lines.append("Нужно:")
	for item: String in d["inputs"]:
		var have := int(client.inventory().get(item, 0))
		var need := int(d["inputs"][item])
		lines.append("  %s %d/%d%s" % [_name(item), mini(have, need), need, "" if have >= need else "  — мало"])
	var where := String(d.get("station", ""))
	if where != "":
		lines.append("Где: %s%s" % [STATIONS.get(where, where), "" if station_near(where) else " — нет рядом"])
	if not _sheets.has(id):
		lines.append("Удача: %d%%, мастерство: %d" % [roundi(chance_of(r) * 100.0), client.mastery_level(r)])
		var skill := String(d.get("skill", ""))
		if skill != "":
			lines.append("Навык: %s, %d" % [content.get_def(skill).get("name", skill), client.skill_level(skill)])
	else:
		lines.append("По чертежу — наверняка и в полную силу; чертёж уйдёт." + (" Уже знаете." if client.knows(content, r) else ""))
	return "\n".join(lines)


func _sheet_lines() -> Array[String]:
	var out: Array[String] = []
	var list: Array = client.item_states().get(BLUEPRINT, [])
	for k in int(client.inventory().get(BLUEPRINT, 0)):
		var st: Dictionary = list[k] if k < list.size() and typeof(list[k]) == TYPE_DICTIONARY else {}
		var r := String(st.get("recipe", ""))
		if content.kind_of(r) != "recipe" or (station != "" and String(content.get_def(r).get("station", "")) != station):
			continue
		var key := "sheet:%d" % k
		_sheets[key] = {"recipe": r, "copy": k}
		out.append(key)
	return out


func _mend_lines() -> Array[String]:
	var out: Array[String] = []
	for m: Dictionary in worn_things():
		if station != "" and Wear.mend_station(content, m["item"]) != station:
			continue
		var key := "mend:%d" % _mends.size()
		_mends[key] = m
		out.append(key)
	return out


func selected() -> String:
	var sel := _list.get_selected_items()
	return _ids[sel[0]] if not sel.is_empty() else ""


func _buttons() -> void:
	var id := selected()
	_about.text = _card(id)
	_about.add_theme_color_override("font_color", Art.TEXT if id != "" else Art.TEXT_DIM)
	var ok: bool = id != "" and bool(_can.get(id, false))
	_make.disabled = not ok
	_second.visible = false
	count.editable = not (_mends.has(id) or _sheets.has(id))
	if _mends.has(id):
		_make.text = "Починить"
		_note.text = "" if ok else why_not(id)
		return
	if _sheets.has(id):
		var r := String(_sheets[id]["recipe"])
		_make.text = "Сделать по чертежу"
		_second.text = "Изучить"
		_second.visible = true
		_second.disabled = client.knows(content, r)
		_note.text = "по чертежу — наверняка и в полную силу, чертёж уйдёт" if ok else why_not(id)
		return
	_make.text = "Сделать"
	# A recipe one has mastered enough is put down for others (on leather).
	if content.kind_of(id) == "recipe" and not bool(content.get_def(id).get("innate", false)):
		_second.text = "Записать чертёж"
		_second.visible = true
		_second.disabled = client.mastery_level(id) < ServerWorld.DRAFT_MASTERY or int(client.inventory().get("base:leather", 0)) < 1
		_second.tooltip_text = "Нужно мастерство %d и кожа" % ServerWorld.DRAFT_MASTERY
	var can := times(id, client.inventory())
	_note.text = "хватит на %d" % can if ok else why_not(id)


## What one carries or wears that is worn and can be mended at all:
## [{"item", "state", "copy" (in the bag) or "slot" (worn)}].
func worn_things() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var states := client.item_states()
	var ids: Array = states.keys()
	ids.sort()
	for id: String in ids:
		if not content.get_def(id).has("repair"):
			continue
		var list: Array = states[id]
		for k in list.size():
			if typeof(list[k]) == TYPE_DICTIONARY and Wear.spent(list[k]) > 0:
				out.append({"item": id, "copy": k, "state": list[k]})
	var worn: Dictionary = (client.own.get("appearance", {}) as Dictionary).get("worn", {})
	var worn_states := client.worn_states()
	for slot: String in worn_states:
		var id := String(worn.get(slot, ""))
		if id != "" and content.get_def(id).has("repair") and Wear.spent(worn_states[slot]) > 0:
			out.append({"item": id, "slot": slot, "state": worn_states[slot]})
	return out


func _mend_text(m: Dictionary) -> String:
	var id := String(m["item"])
	var st: Dictionary = m["state"]
	var cost := PackedStringArray()
	var need := Wear.mend_cost(content, id, st)
	for item: String in need:
		cost.append("%s %d" % [_name(item), int(need[item])])
	var where := Wear.mend_station(content, id)
	var text := "Починить: %s%s, %d%%" % [content.get_def(id).get("name", id), " (надето)" if m.has("slot") else "",
		floori(Wear.condition(content, id, st) * 100.0 + 0.5)]
	if Wear.mends_left(content, id, st) <= 0:
		return text + " — больше не починить"
	text += " → " + ", ".join(cost)
	if where != "":
		text += "  [%s]" % STATIONS.get(where, where)
	return text


## Why a line cannot be done here and now ("" — it can).
func why_not(id: String) -> String:
	if id == "":
		return ""
	if _mends.has(id):
		var m: Dictionary = _mends[id]
		if Wear.mends_left(content, String(m["item"]), m["state"]) <= 0:
			return "износилось до предела — сделайте новое"
		var where := Wear.mend_station(content, String(m["item"]))
		if not station_near(where):
			return "чинят рядом: " + String(STATIONS.get(where, where))
		return _lack(Wear.mend_cost(content, String(m["item"]), m["state"]), 1)
	if _sheets.has(id):
		var r := String(_sheets[id]["recipe"])
		var at := String(content.get_def(r).get("station", ""))
		if not station_near(at):
			return "нужен рядом: " + String(STATIONS.get(at, at))
		return _lack(content.get_def(r)["inputs"], 1)
	var d := content.get_def(id)
	var where := String(d.get("station", ""))
	if not station_near(where):
		return "нужен рядом: " + String(STATIONS.get(where, where))
	return _lack(d["inputs"], 1)


func _lack(need: Dictionary, n: int) -> String:
	var short := PackedStringArray()
	for item: String in need:
		var lack := int(need[item]) * n - int(client.inventory().get(item, 0))
		if lack > 0:
			short.append("%s %d" % [_name(item), lack])
	return "не хватает: " + ", ".join(short) if not short.is_empty() else ""


## So many as asked, as many as the things allow.
func how_many() -> int:
	return mini(int(count.value), times(selected(), client.inventory()))


func _ask(n: int) -> void:
	var id := selected()
	if not bool(_can.get(id, false)):
		return
	if _mends.has(id):
		var m: Dictionary = _mends[id]
		mend.emit({"slot": m["slot"]} if m.has("slot") else {"item": m["item"], "copy": m["copy"]})
		return
	if _sheets.has(id):
		ask.emit({"type": "craft", "recipe": _sheets[id]["recipe"], "count": 1, "blueprint": _sheets[id]["copy"]})
		return
	if id != "" and n > 0:
		craft.emit(id, n)


## The second button: study a blueprint, or draft one of a mastered recipe.
func _ask_second() -> void:
	var id := selected()
	if _sheets.has(id):
		ask.emit({"type": "study", "copy": _sheets[id]["copy"]})
	elif content.kind_of(id) == "recipe":
		ask.emit({"type": "draft", "recipe": id})


func _name(item: String) -> String:
	return String(content.get_def(item).get("name", item)).to_lower()
