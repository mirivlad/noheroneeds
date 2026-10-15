class_name Actions
## What one can do (ADR-0021): from what one holds and what one points at,
## found in content data, never by naming a particular item:
##   a weapon       ("weapon")       — strikes the living, swings at the air;
##                                     a ranged one shoots where one aims;
##   a tool         ("tools": kinds) — gets what a part or plant holds when
##                                     its "gather" asks for that kind;
##   a door         ("openable")     — opens and closes;
##   a thing lying  (an item entity) — is picked up;
##   a way up/down  (stairs, shafts) — is climbed;
##   one's own part (props "owner")  — may be taken apart;
##   anything                         — may be looked at.
## So a scythe and crops, a rod and fish come as data: a tool kind on the
## item, a "gather" on what it works on.
##
## An action: {"id", "name", "request": Dictionary for the server (or
## "local": "inspect"), "primary": true for the left button, "quick": true
## for E, "enabled": false with "why" when it cannot be done now}.

const LIVING := ["character", "creature"]


static func of(content: ContentRegistry, client: GameClient, view: WorldView, held: String, target: Dictionary,
		aim: Vector2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var w: Dictionary = content.get_def(held).get("weapon", {}) if held != "" else {}
	var tools: Array = content.get_def(held).get("tools", []) if held != "" else []
	var kind := String(target.get("kind", ""))
	var loc := String(target.get("location", client.location))
	var cell: Vector2i = target.get("cell", Movement.cell_of(aim))
	var entity: Dictionary = target.get("entity", {})
	var living: bool = kind == "entity" and String(entity.get("kind", "")) in LIVING and target.get("id") != client.character_id
	# A ranged weapon shoots where one aims, whatever is there.
	if w.get("kind") == "ranged":
		var shot := {"type": "attack", "item": held, "x": aim.x, "y": aim.y}
		if living:
			shot["x"] = int(entity.get("x", aim.x))
			shot["y"] = int(entity.get("y", aim.y))
			if int(entity.get("z", client.z)) != client.z:
				shot["z"] = int(entity["z"])
		out.append({"id": "shoot", "name": "Выстрелить", "request": shot, "primary": true})
	if living:
		var hit := {"type": "attack", "item": held if w.get("kind") == "melee" else "",
			"x": int(entity.get("x", aim.x)), "y": int(entity.get("y", aim.y))}
		var with := String(content.get_def(held).get("name", "")) if w.get("kind") == "melee" else "рукой"
		out.append({"id": "strike", "name": "Ударить (%s)" % with, "request": hit, "primary": w.get("kind") == "melee"})
	if kind == "entity" and entity.get("kind") == "item":
		out.append({"id": "pickup", "name": "Подобрать", "request": {"type": "pickup", "entity": target["id"]},
			"quick": true})
	if kind == "part":
		var id := String(target["id"])
		var def := content.get_def(id)
		var layer := String(target["layer"])
		var g: Dictionary = def.get("gather", {})
		if not g.is_empty():
			var tool := String(g["tool"])
			var ok := tool == "" or tools.has(tool)
			out.append({"id": "gather", "name": String(g["verb"]), "primary": ok, "enabled": ok,
				"why": "нужно взять в руки: " + tool_names(content, tool),
				"request": {"type": "gather", "location": loc, "x": cell.x, "y": cell.y, "layer": layer, "item": held}})
		if def.has("container") and layer == "structure":
			out.append({"id": "open_container", "name": "Открыть", "quick": true, "local": "container",
				"request": {"type": "look_in", "location": loc, "x": cell.x, "y": cell.y}})
		if def.get("openable", false) and layer == "structure":
			var open := bool(view.props_at(cell).get("open", false))
			out.append({"id": "use", "name": "Закрыть" if open else "Открыть", "quick": true,
				"request": {"type": "use", "location": loc, "x": cell.x, "y": cell.y}})
		var role := String(def.get("role", ""))
		if role == "stairs" or role == "shaft":
			var down := role == "shaft" and String(def.get("leads", "down")) == "down"
			out.append({"id": "climb", "name": "Спуститься" if down else "Подняться", "quick": true,
				"request": {"type": "climb", "location": loc, "x": cell.x, "y": cell.y, "dir": "down" if down else "up"}})
		var props := view.props_at(cell)
		var owner := String((props.get(layer, {}) as Dictionary).get("owner", "") if layer != "structure" else props.get("owner", ""))
		if layer == "structure" and int(def.get("durability", 0)) > 0:
			var with := String(content.get_def(held).get("name", "")) if w.get("kind") == "melee" else "рукой"
			out.append({"id": "strike_part", "name": "Ударить (%s)" % with,
				"request": {"type": "strike_part", "location": loc, "x": cell.x, "y": cell.y,
					"item": held if w.get("kind") == "melee" else ""}})
			if int(props.get("damage", 0)) > 0 and owner == client.character_id:
				out.append({"id": "repair", "name": "Ремонтировать",
					"request": {"type": "repair", "location": loc, "x": cell.x, "y": cell.y}})
		if owner != "" and owner == client.character_id:
			out.append({"id": "dismantle", "name": "Разобрать",
				"request": {"type": "dismantle", "location": loc, "x": cell.x, "y": cell.y, "layer": layer}})
	# A melee weapon swings at the air too: one need not aim exactly to defend.
	if w.get("kind") == "melee" and not living:
		out.append({"id": "swing", "name": "Взмахнуть", "primary": out.filter(func(a: Dictionary) -> bool:
			return a.get("primary", false)).is_empty(), "request": {"type": "attack", "item": held, "x": aim.x, "y": aim.y}})
	out.append({"id": "inspect", "name": "Осмотреть", "local": "inspect",
		"primary": out.filter(func(a: Dictionary) -> bool: return a.get("primary", false)).is_empty()})
	return out


static func primary(actions: Array[Dictionary]) -> Dictionary:
	for a in actions:
		if a.get("primary", false) and a.get("enabled", true):
			return a
	return {}


static func quick(actions: Array[Dictionary]) -> Dictionary:
	for a in actions:
		if a.get("quick", false) and a.get("enabled", true):
			return a
	return {}


## Things that are a tool of a kind, by name ("Кирка"), for a hint.
static func tool_names(content: ContentRegistry, kind: String) -> String:
	var names := PackedStringArray()
	for id: String in content.defs:
		if content.kind_of(id) == "item" and (content.get_def(id).get("tools", []) as Array).has(kind):
			names.append(String(content.get_def(id).get("name", id)).to_lower())
	return ", ".join(names) if not names.is_empty() else kind


## What one sees looking at a target: its name and what is known of it.
static func describe(content: ContentRegistry, target: Dictionary) -> String:
	match String(target.get("kind", "")):
		"entity":
			var e: Dictionary = target["entity"]
			var name := String(e.get("name", ""))
			match String(e.get("kind", "")):
				"creature":
					name = String(content.get_def(String(e.get("creature", ""))).get("name", "существо"))
				"item":
					name = "%s ×%d" % [content.get_def(String(e.get("item", ""))).get("name", "вещь"), int(e.get("count", 1))]
			if e.has("max_health") and int(e["max_health"]) > 0:
				name += " (здоровье %d/%d)" % [int(e.get("health", 0)), int(e["max_health"])]
			return name
		"part", "ground":
			var def := content.get_def(String(target.get("id", "")))
			var name := String(def.get("name", target.get("id", "")))
			var top := int(def.get("durability", 0))
			if target.get("kind") == "part" and target.get("layer") == "structure" and top > 0 and target.has("damage"):
				name += " (прочность %d/%d)" % [top - int(target["damage"]), top]
			return name
	return ""
