class_name Actions
## What one can do (ADR-0021): from what one holds and what one points at,
## found in content data, never by naming a particular item:
##   a weapon       ("weapon")       — strikes the living, swings at the air;
##                                     a ranged one shoots where one aims;
##   a tool         ("tools": kinds) — gets what a part or plant holds when
##                                     its "gather" asks for that kind;
##   a door         ("openable")     — opens and closes; the one who set it
##                                     up locks it with a code (ADR-0016);
##   a thing lying  (an item entity) — is picked up;
##   a way up/down  (stairs, shafts) — is climbed;
##   one's own part (props "owner")  — may be taken apart (another's only
##                                     broken, ADR-0016); any worn one mended;
##   another person                   — befriended (opens one's chests and
##                                     locked doors) or no longer;
##   food in the hands ("food")       — is eaten (ADR-0026);
##   an animal and what it eats       — it is fed, and tamed (ADR-0030);
##   a bed                            — is slept in (ADR-0035);
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
		var hit := {"type": "attack", "item": held, "x": int(entity.get("x", aim.x)), "y": int(entity.get("y", aim.y))}
		if w.get("kind") != "melee":
			hit["unarmed"] = true  # the free hand
		var with := String(content.get_def(held).get("name", "")) if w.get("kind") == "melee" else "рукой"
		out.append({"id": "strike", "name": "Ударить (%s)" % with, "request": hit, "primary": w.get("kind") == "melee"})
	# Husbandry (ADR-0030): what an animal eats, held out, is fed to it.
	if living and entity.get("kind") == "creature" and held != "" \
			and (content.get_def(String(entity.get("creature", ""))).get("tame", {}).get("food", []) as Array).has(held):
		out.append({"id": "feed", "name": "Покормить", "primary": true,
			"request": {"type": "feed", "creature": target["id"], "item": held}})
	if living and entity.get("kind") == "character":
		var friend := client.friends().has(target["id"])
		out.append({"id": "friend", "name": "Убрать из друзей" if friend else "Добавить в друзья",
			"request": {"type": "unfriend" if friend else "befriend", "character": target["id"]}})
	# On a building level a cell without floor is a drop (ADR-0007): an
	# opening over stairs is gone down, any opening or edge next to one jumped
	# down through — no tools, the fall hurts by its height.
	if kind == "ground" and String(target.get("id", "")) == "" and client.z > 0:
		var d := cell - Movement.cell_of(client.position)
		var stairs := bool(view.props_at(cell).get("stairs_down", false))
		if stairs:
			out.append({"id": "climb", "name": "Спуститься", "quick": true,
				"request": {"type": "climb", "location": loc, "x": cell.x, "y": cell.y, "dir": "down"}})
		out.append({"id": "jump", "name": "Спрыгнуть вниз", "quick": not stairs,
			"enabled": absi(d.x) <= 1 and absi(d.y) <= 1 and d != Vector2i.ZERO, "why": "подойдите к краю",
			"request": {"type": "jump", "dx": d.x, "dy": d.y}})
	# Fields (ADR-0027): a tilling tool turns tillable ground over; a seed in
	# the hands is sown in a field.
	if kind == "ground" and tools.has("tilling") and content.get_def(String(target.get("id", ""))).has("tilled"):
		out.append({"id": "till", "name": "Вспахать", "primary": true,
			"request": {"type": "till", "location": loc, "x": cell.x, "y": cell.y, "item": held}})
	if kind == "ground" and held != "" and content.get_def(held).has("plants") \
			and content.get_def(String(target.get("id", ""))).get("farmland", false):
		out.append({"id": "sow", "name": "Посеять", "primary": true,
			"request": {"type": "sow", "location": loc, "x": cell.x, "y": cell.y, "item": held}})
	if kind == "entity" and entity.get("kind") == "item":
		out.append({"id": "pickup", "name": "Подобрать", "request": {"type": "pickup", "entity": target["id"]},
			"quick": true})
	# What a part, a plant or ground holds is got with its kind of tool (a rod
	# fishes in water: the water stays).
	var g: Dictionary = content.get_def(String(target.get("id", ""))).get("gather", {}) \
		if kind in ["part", "ground"] and String(target.get("id", "")) != "" else {}
	if not g.is_empty():
		var tool := String(g["tool"])
		var ok := tool == "" or tools.has(tool)
		out.append({"id": "gather", "name": String(g["verb"]), "primary": ok, "enabled": ok,
			"why": "нужно взять в руки: " + tool_names(content, tool),
			"request": {"type": "gather", "location": loc, "x": cell.x, "y": cell.y,
				"layer": String(target.get("layer", "ground")), "item": held}})
	if kind == "part":
		var id := String(target["id"])
		var def := content.get_def(id)
		var layer := String(target["layer"])
		if def.get("bed", false) and layer == "structure":  # ADR-0035
			out.append({"id": "sleep", "name": "Лечь спать", "quick": true,
				"request": {"type": "sleep", "location": loc, "x": cell.x, "y": cell.y}})
		if def.has("container") and layer == "structure":
			out.append({"id": "open_container", "name": "Открыть", "quick": true, "local": "container",
				"request": {"type": "look_in", "location": loc, "x": cell.x, "y": cell.y}})
		var props := view.props_at(cell)
		var owner := String((props.get(layer, {}) as Dictionary).get("owner", "") if layer != "structure" else props.get("owner", ""))
		if def.get("openable", false) and layer == "structure":
			var open := bool(props.get("open", false))
			var locked := bool(props.get("locked", false))
			out.append({"id": "use", "name": "Закрыть" if open else ("Открыть (заперто)" if locked else "Открыть"), "quick": true,
				"request": {"type": "use", "location": loc, "x": cell.x, "y": cell.y}})
			if owner != "" and owner == client.character_id:
				out.append({"id": "lock", "name": "Сменить код замка" if locked else "Поставить замок", "local": "lock",
					"request": {"type": "lock", "location": loc, "x": cell.x, "y": cell.y}})
				if locked:
					out.append({"id": "unlock", "name": "Снять замок",
						"request": {"type": "lock", "location": loc, "x": cell.x, "y": cell.y, "pin": ""}})
		var role := String(def.get("role", ""))
		if role == "stairs" or role == "shaft":
			var down := role == "shaft" and String(def.get("leads", "down")) == "down"
			out.append({"id": "climb", "name": "Спуститься" if down else "Подняться", "quick": true,
				"request": {"type": "climb", "location": loc, "x": cell.x, "y": cell.y, "dir": "down" if down else "up"}})
		# A ceiling or a roof is broken too, from the top down (the server
		# refuses while something is over it).
		if layer in ["structure", "ceiling", "roof"] and int(def.get("durability", 0)) > 0:
			var with := String(content.get_def(held).get("name", "")) if w.get("kind") == "melee" else "рукой"
			var blow := {"type": "strike_part", "location": loc, "x": cell.x, "y": cell.y, "item": held}
			var mend := {"type": "repair", "location": loc, "x": cell.x, "y": cell.y}
			if layer != "structure":
				blow["layer"] = layer
				mend["layer"] = layer
			if w.get("kind") != "melee":
				blow["unarmed"] = true
			out.append({"id": "strike_part", "name": "Ударить (%s)" % with, "request": blow})
			var worn: Dictionary = props if layer == "structure" else props.get(layer, {})
			if float(worn.get("damage", 0)) > 0.0:
				out.append({"id": "repair", "name": "Ремонтировать", "request": mend})
		if owner != "":
			var mine := owner == client.character_id
			out.append({"id": "dismantle", "name": "Разобрать", "enabled": mine,
				"why": "поставлено другим: разобрать нельзя, только сломать",
				"request": {"type": "dismantle", "location": loc, "x": cell.x, "y": cell.y, "layer": layer}})
	# A melee weapon swings at the air too: one need not aim exactly to defend.
	if w.get("kind") == "melee" and not living:
		out.append({"id": "swing", "name": "Взмахнуть", "primary": out.filter(func(a: Dictionary) -> bool:
			return a.get("primary", false)).is_empty(), "request": {"type": "attack", "item": held, "x": aim.x, "y": aim.y}})
	# Food in the hands is eaten, unless the left button has better to do.
	if held != "" and not content.get_def(held).get("food", {}).is_empty():
		out.append({"id": "eat", "name": "Съесть (%s)" % String(content.get_def(held).get("name", "")).to_lower(),
			"request": {"type": "eat", "item": held}, "primary": out.filter(func(a: Dictionary) -> bool:
				return a.get("primary", false)).is_empty()})
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
static func describe(content: ContentRegistry, target: Dictionary, me := "") -> String:
	match String(target.get("kind", "")):
		"entity":
			var e: Dictionary = target["entity"]
			var name := String(e.get("name", ""))
			match String(e.get("kind", "")):
				"creature":
					name = String(content.get_def(String(e.get("creature", ""))).get("name", "существо"))
					if String(e.get("owner", "")) != "":
						name += " (ваша)" if me != "" and e["owner"] == me else " (чья-то)"
				"item":
					name = "%s ×%d" % [content.get_def(String(e.get("item", ""))).get("name", "вещь"), int(e.get("count", 1))]
			if e.has("max_health") and int(e["max_health"]) > 0:
				name += " (здоровье %d/%d)" % [int(e.get("health", 0)), int(e["max_health"])]
			return name
		"part", "ground":
			if target.get("kind") == "ground" and String(target.get("id", "")) == "":
				return "Пустота: проём или край — можно спрыгнуть"
			var def := content.get_def(String(target.get("id", "")))
			var name := String(def.get("name", target.get("id", "")))
			var top := int(def.get("durability", 0))
			if target.get("kind") == "part" and top > 0 and target.has("damage"):
				name += " (прочность %d/%d)" % [top - int(target["damage"]), top]
			var work := int(def.get("gather", {}).get("work", 1))
			if target.get("kind") == "part" and work > 1 and int(target.get("work", 0)) > 0:
				name += " (%s: %d из %d)" % [String(def["gather"]["verb"]).to_lower(), int(target["work"]), work]
			return name
	return ""
