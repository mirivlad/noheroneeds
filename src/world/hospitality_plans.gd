class_name HospitalityPlans
extends RefCounted
## Public houses supplement the old village/road plans without changing
## their identities. A whole building fits in one chunk; old chunks stay old.
var _settlements: WeakRef
var settlements: Settlements:
	get: return _settlements.get_ref()
var _plans := {}
var _by_id := {}
var templates: Array[Dictionary] = []
var services := {}

func _init(s: Settlements) -> void:
	_settlements = weakref(s)
	var ids: Array = s.content.defs.keys()
	ids.sort()
	for id: String in ids:
		var d := s.content.get_def(id)
		if d.get("kind") != "hospitality":
			continue
		if d.get("mode") == "building":
			templates.append(d)
		else:
			services = d

func of_cluster(k: int, dx: int, dy: int) -> Array:
	var key := "%d,%d,%d" % [k, dx, dy]
	if not _plans.has(key):
		_plans[key] = _make(k, dx, dy)
		for p: Dictionary in _plans[key]:
			_by_id[p["id"]] = p
	return _plans[key]

func by_id(id: String) -> Dictionary:
	if _by_id.has(id):
		return _by_id[id]
	if id.begins_with("tavern@"):
		var village := settlements.plan_by_id(id.trim_prefix("tavern@"))
		if not village.is_empty():
			for k in settlements._kinds.size():
				if settlements._kinds[k]["id"] == village["kind"]:
					var d := settlements._district_of(k, village["centre"])
					of_cluster(k, d.x, d.y)
	elif id.begins_with("inn@"):
		var parts := id.trim_prefix("inn@").split(",")
		if parts.size() == 3 and parts[0].is_valid_int() and parts[1].is_valid_int() and parts[2].is_valid_int():
			var k := int(parts[0])
			if k >= 0 and k < settlements._kinds.size():
				of_cluster(k, int(parts[1]), int(parts[2]))
	return _by_id.get(id, {})

func plans_touching(cx: int, cy: int) -> Array:
	var out := []
	var chunk := Rect2i(cx * 32, cy * 32, 32, 32)
	for k in settlements._kinds.size():
		var d := settlements._district_of(k, chunk.position)
		for p: Dictionary in of_cluster(k, d.x, d.y):
			if (p["bounds"] as Rect2i).intersects(chunk):
				out.append(p)
	return out

func near(at: Vector2i, radius: int) -> Array:
	var out := []
	for k in settlements._kinds.size():
		var low := settlements._district_of(k, at - Vector2i(radius, radius))
		var high := settlements._district_of(k, at + Vector2i(radius, radius))
		for dy in range(low.y, high.y + 1):
			for dx in range(low.x, high.x + 1):
				for p: Dictionary in of_cluster(k, dx, dy):
					if at.distance_to(p["centre"]) <= radius:
						out.append(p)
	return out

func _make(k: int, dx: int, dy: int) -> Array:
	if templates.is_empty():
		return []
	var s := settlements
	var villages := s.villages(k, dx, dy)
	var roads := s.roads_of(k, dx, dy)
	var area := s._district_rect(k, dx, dy)
	var camp := s.camps.of_cluster(k, dx, dy)
	var out := []
	for village: Dictionary in villages:
		if not village.get("home", false) and (village["homes"].size() < 5 or absi(hash([village["id"], s.world_seed])) % 3 == 0):
			continue
		var choices := templates.filter(func(t: Dictionary) -> bool: return t["site"] == "tavern")
		if choices.is_empty():
			continue
		var made := _choose("tavern@" + String(village["id"]), choices[0], village["centre"], village, roads, villages, camp, out, area)
		if not made.is_empty():
			out.append(made)
	var choices := templates.filter(func(t: Dictionary) -> bool: return t["site"] == "inn")
	if choices.is_empty():
		return out
	roads = roads.duplicate()
	roads.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["path"].size() > b["path"].size())
	var id := "inn@%d,%d,%d" % [k, dx, dy]
	var template: Dictionary = choices[absi(hash([s.world_seed, id])) % choices.size()]
	for road: Dictionary in roads:
		var path: Array = road["path"]
		if path.size() < int(services.get("min_road", 120)):
			continue
		for fraction in [.5, .3, .7]:
			var anchor: Vector2i = path[int((path.size() - 1) * fraction)]
			var nearest: Dictionary = villages[0]
			for village: Dictionary in villages:
				if anchor.distance_to(village["centre"]) < anchor.distance_to(nearest["centre"]):
					nearest = village
			var made := _choose(id, template, anchor, nearest, roads, villages, camp, out, area)
			if not made.is_empty():
				out.append(made)
				return out  # at most one roadside inn per cluster
	return out

func _choose(id: String, template: Dictionary, anchor: Vector2i, village: Dictionary,
		roads: Array, villages: Array, camp: Dictionary, others: Array, area: Rect2i) -> Dictionary:
	var size := Vector2i(String(template["rows"][0]).length(), template["rows"].size())
	var yard := int(template.get("yard", 4))
	var candidates: Array[Vector2i] = []
	var base := Vector2i(anchor.x >> 5, anchor.y >> 5)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for x in [2, 30 - size.x]:
				for y in [2, 30 - size.y - yard]:
					candidates.append((base + Vector2i(dx, dy)) * 32 + Vector2i(x, y))
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a + size / 2).distance_squared_to(anchor) < (b + size / 2).distance_squared_to(anchor))
	for at: Vector2i in candidates:
		var rect := Rect2i(at, size)
		var bounds := Rect2i(at - Vector2i.ONE, size + Vector2i(2, yard + 1))
		if not area.encloses(bounds) or rect.get_center().distance_to(anchor) > 55:
			continue
		if villages.any(func(v: Dictionary) -> bool: return (v["bounds"] as Rect2i).grow(3 if template["site"] == "tavern" else 18).intersects(bounds)):
			continue
		if others.any(func(p: Dictionary) -> bool: return (p["bounds"] as Rect2i).grow(4).intersects(bounds)) \
				or (not camp.is_empty() and (camp["bounds"] as Rect2i).grow(4).intersects(bounds)):
			continue
		var nearby := settlements.roads_touching(at.x >> 5, at.y >> 5)
		if nearby.any(func(r: Dictionary) -> bool: return (r["cells"] as Dictionary).keys().any(func(c: Vector2i) -> bool: return bounds.has_point(c))):
			continue
		var dry := true
		var low := INF
		var high := -INF
		for y in range(bounds.position.y, bounds.end.y):
			for x in range(bounds.position.x, bounds.end.x):
				if settlements._wet.call(x, y):
					dry = false
				if settlements._land.is_valid():
					var land: Dictionary = settlements._land.call(x, y)
					low = minf(low, float(land["height"]))
					high = maxf(high, float(land["height"]))
		if not dry or high - low > .08:
			continue
		var plan := _layout(id, template, at, String(village["id"]))
		var access := _access(plan, roads, village, villages, others, camp)
		if access.is_empty() or access.any(func(p: Vector2i) -> bool: return not area.has_point(p)):
			continue
		if template["site"] == "inn":
			if (plan["camp_spot"] as Vector2i).distance_to(access.back()) > 32:
				continue
			for road: Dictionary in roads:
				if road["cells"].has(access.back()):
					plan["road"] = road["key"].duplicate()
					break
			if plan["road"].is_empty():
				continue
		for p: Vector2i in access:
			if not (plan["cells"] as Dictionary).has(p) and not roads.any(func(r: Dictionary) -> bool: return r["cells"].has(p)):
				plan["cells"][p] = {"ground": "base:dirt", "cover": ""}
			plan["bounds"] = (plan["bounds"] as Rect2i).expand(p)
		return plan
	return {}

func _access(plan: Dictionary, roads: Array, village: Dictionary, villages: Array, others: Array, camp: Dictionary) -> Array[Vector2i]:
	var door: Vector2i = plan["door"]
	var goal: Vector2i = village["ends"][0]
	for road: Dictionary in roads:
		for p: Vector2i in road["path"]:
			if door.distance_to(p) < door.distance_to(goal):
				goal = p
	var rect: Rect2i = plan["rect"]
	var side := rect.position.x - 2 if goal.x < door.x else rect.end.x + 2
	var points := [door, door + Vector2i(0, 2), Vector2i(side, door.y + 2), Vector2i(side, goal.y), goal]
	var out: Array[Vector2i] = []
	for i in range(1, points.size()):
		var at: Vector2i = points[i - 1]
		var end: Vector2i = points[i]
		while at != end:
			at += Vector2i(signi(end.x - at.x), signi(end.y - at.y))
			if others.any(func(p: Dictionary) -> bool: return (p["bounds"] as Rect2i).has_point(at)) \
					or (not camp.is_empty() and (camp["bounds"] as Rect2i).has_point(at)):
				return []
			if settlements._wet.call(at.x, at.y) and not roads.any(func(r: Dictionary) -> bool: return r["cells"].has(at)):
				return []
			for v: Dictionary in villages:
				var part := String(v["cells"].get(at, {}).get("structure", ""))
				if part != "" and settlements.content.get_def(part).get("solid", true):
					return []
			out.append(at)
	return out

func _layout(id: String, template: Dictionary, at: Vector2i, village: String) -> Dictionary:
	var roll := absi(hash([settlements.world_seed, id, "decor"]))
	var rows: Array = template["rows"]
	var size := Vector2i(String(rows[0]).length(), rows.size())
	var yard := int(template.get("yard", 4))
	var rect := Rect2i(at, size)
	var names: Array = services.get("names", ["Тёплый очаг"])
	var out := {"id": id, "template": template["id"], "site": template["site"], "name": names[roll % names.size()],
		"village": village, "rect": rect, "centre": rect.get_center(), "bounds": Rect2i(at - Vector2i.ONE, size + Vector2i(2, yard + 1)),
		"cells": {}, "upper": {}, "beds": [], "seats": [], "host": at, "door": at, "road": [],
		"camp_spot": at + Vector2i(size.x / 2, size.y + yard / 2)}
	for y in range(-1, size.y + yard):
		for x in range(-1, size.x + 1):
			out["cells"][at + Vector2i(x, y)] = {"cover": "", "structure": ""}
	var wall := String(template["walls"][roll % template["walls"].size()])
	for z in (2 if not template.get("upper", []).is_empty() else 1):
		var floor_rows: Array = rows if z == 0 else template["upper"]
		var cells: Dictionary = out["cells"] if z == 0 else out["upper"]
		for y in floor_rows.size():
			for x in size.x:
				var tile := String(floor_rows[y]).substr(x, 1)
				var px := size.x - 1 - x if roll % 2 else x
				var p := at + Vector2i(px, y)
				var props := {"hospitality": id, "village": village, "decor": roll % 3}
				var parts := {"#": wall, "w": "base:wood_window", "D": "base:wood_door", "d": "base:wood_door",
					"=": "base:inn_counter", "T": "base:inn_round_table" if roll % 3 == 0 else "base:inn_table", "C": "base:inn_chair",
					"c": "base:inn_chair" if roll % 3 != 0 else "", "F": "base:campfire", "K": "base:forge", "O": "base:bed", "B": "base:bed", "P": "base:bed", "S": "base:wood_stairs"}
				var part := String(parts.get(tile, ""))
				props["facing"] = "w" if x == 0 else ("e" if x == size.x - 1 else ("n" if y == 0 else "s"))
				var spec := {"ground": "base:wood_floor" if tile != "V" else "", "cover": "", "structure": part, "props": props}
				if z == 0 and not template.get("upper", []).is_empty() and tile != "S":
					spec["ceiling"] = "base:wood_ceiling"
					props["ceiling"] = {"building": id}
				else:
					spec["roof"] = "base:thatch_roof"
				if tile == "S":
					props["facing"] = "n"
					props["arrive"] = [p.x, p.y - 1]
					spec.erase("roof")
				if tile == "V":
					props["stairs_down"] = true
				if tile in ["B", "P"]:
					props["inn_bed"] = out["beds"].size()
					props["bed_kind"] = "shared" if tile == "B" else "private"
					out["beds"].append({"x": p.x, "y": p.y, "z": z, "kind": props["bed_kind"]})
				if part == "base:inn_chair":
					props["facing"] = "s" if tile == "C" else "n"
					out["seats"].append(p)
				if tile == "H":
					out["host"] = p
				if tile == "D":
					out["door"] = p
				cells[p] = spec
	var sign: Vector2i = out["door"] + Vector2i(2 if roll % 2 else -2, 1)
	out["cells"][sign] = {"structure": "base:inn_sign", "cover": "", "props": {"hospitality": id, "village": village, "facing": "s", "decor": roll % 3}}
	return out
