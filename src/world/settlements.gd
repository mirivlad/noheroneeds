class_name Settlements
extends RefCounted
## Where settlements are and how they are laid out (ADR-0038): a function of
## the world seed, like the caves — a chunk made in any order gets its part
## of a village. Kinds of settlement are content ("settlement"): what they
## are built of, their buildings, fields and pen; this only lays them out.
##
## The world is cut into regions of `region_chunks` chunks; a region may hold
## one settlement of a kind (its "chance"), somewhere dry in it. A kind marked
## "near_spawn" always has one in the spawn's region, a short walk east of
## the spawn clearing.
##
## A village: rows of buildings, each with its door onto a street south of
## it (the doors and windows face south), a fire on the first street, fields
## and a pen beyond the last street. Every cell it sets is in its plan:
## {cell: {"ground", "cover", "structure", "roof", "props"}} — only the layers
## it sets; the rest of the land stays as the generator made it.

const NONE := Vector2i(1 << 30, 1 << 30)
## Cells round each building, field and pen kept free of any plant.
const MARGIN := 1
## Cells round the whole settlement kept free of trees and bushes.
const TREE_FREE := 3
## Tries of a place for a settlement in its region.
const TRIES := 24
## Of a plan's cells, at most this share may be water for it to stand there
## (a pond in a village is let be; under its own cells water becomes land).
const WET_SHARE := 0.12
## Roads (ADR-0038): a settlement is joined with the one of its kind in the
## region east of it, and the one south of it, each by this chance; when it
## is joined both ways, the southern road may instead (JUNCTION_CHANCE) meet
## the eastern one partway, at a crossroads — not every village to every other.
const ROAD_CHANCE := 0.6
const JUNCTION_CHANCE := 0.5
## Roads keep this far out of a settlement's side before turning.
const ROAD_OUT := 3
## Water a road crosses on a bridge (in its path's cells); longer, it breaks off.
const BRIDGE_MAX := 16

var world_seed := 0
var content: ContentRegistry
## Settlement kinds, in content id order: [{"id", "def"}].
var _kinds: Array = []
## The spawn clearing's half size (no settlement in it).
var _clearing := 8
## (x, y) -> whether the surface there is water (the surface generator's).
var _wet: Callable
## (x, y) -> the biome there ("" water): a settlement's style by its middle.
var _biome: Callable
## "kind|rx|ry" -> plan ({} none)
var _plans := {}
## "kind|rx|ry|dir" -> road ({} none)
var _roads := {}


func _init(seed_value: int, registry: ContentRegistry, wet: Callable, clearing: int, biome := Callable()) -> void:
	world_seed = seed_value
	content = registry
	_wet = wet
	_biome = biome
	_clearing = clearing
	var ids: Array = []
	for id: String in registry.defs:
		if registry.kind_of(id) == "settlement":
			ids.append(id)
	ids.sort()
	for id: String in ids:
		_kinds.append({"id": id, "def": registry.get_def(id)})


## Plans of every settlement whose cells may fall in chunk (cx, cy).
func plans_touching(cx: int, cy: int) -> Array:
	var out := []
	var chunk := Rect2i(cx * Chunk.SIZE, cy * Chunk.SIZE, Chunk.SIZE, Chunk.SIZE)
	for k in _kinds.size():
		var size := int(_kinds[k]["def"]["region_chunks"]) * Chunk.SIZE
		var r := Vector2i(floori(float(chunk.position.x) / size), floori(float(chunk.position.y) / size))
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var p := plan(k, r.x + dx, r.y + dy)
				if not p.is_empty() and (p["bounds"] as Rect2i).intersects(chunk):
					out.append(p)
	return out


## Every plan of a kind index in a region ({} if it holds none).
func plan(k: int, rx: int, ry: int) -> Dictionary:
	var key := "%d|%d|%d" % [k, rx, ry]
	if _plans.has(key):
		return _plans[key]
	var made := _make(k, rx, ry)
	if _plans.size() > 1024:
		_plans.clear()
	_plans[key] = made
	return made


## The settlement by the spawn point (of the first kind marked "near_spawn"); {} none.
func home_plan() -> Dictionary:
	for k in _kinds.size():
		if _kinds[k]["def"].get("near_spawn", false):
			return plan(k, 0, 0)
	return {}


## A settlement's plan by its id ("kind@rx,ry"); {} if there is none.
func plan_by_id(id: String) -> Dictionary:
	var at := id.rfind("@")
	if at < 0:
		return {}
	var kind := id.substr(0, at)
	var r := id.substr(at + 1).split(",")
	if r.size() != 2:
		return {}
	for k in _kinds.size():
		if _kinds[k]["id"] == kind:
			return plan(k, int(r[0]), int(r[1]))
	return {}


## The settlements of all kinds within `radius` cells of a point (villagers, maps).
func plans_near(at: Vector2i, radius: int) -> Array:
	var out := []
	for k in _kinds.size():
		var size := int(_kinds[k]["def"]["region_chunks"]) * Chunk.SIZE
		var r := Vector2i(floori(float(at.x) / size), floori(float(at.y) / size))
		var reach := ceili(float(radius) / size) + 1
		for ry in range(r.y - reach, r.y + reach + 1):
			for rx in range(r.x - reach, r.x + reach + 1):
				var p := plan(k, rx, ry)
				if not p.is_empty() and Vector2(p["centre"]).distance_to(Vector2(at)) <= radius:
					out.append(p)
	return out


func _make(k: int, rx: int, ry: int) -> Dictionary:
	var d: Dictionary = _kinds[k]["def"]
	var size := int(d["region_chunks"]) * Chunk.SIZE
	var spawn_region := rx == 0 and ry == 0 or (rx == -1 and ry == 0) or (rx == 0 and ry == -1) or (rx == -1 and ry == -1)
	var near_spawn: bool = d.get("near_spawn", false) and rx == 0 and ry == 0
	if not near_spawn and (_hash(k, rx, ry, 1) >= float(d["chance"]) or (d.get("near_spawn", false) and spawn_region)):
		return {}
	var home := _layout(k, rx, ry, d) if near_spawn else {}
	for t in TRIES:
		var centre: Vector2i
		if near_spawn:
			# A short walk from the spawn point, out of its clearing (its own
			# look: no style, the first place one sees).
			if t >= 8:
				break
			var east := _clearing + 4 + int(home["half"])
			centre = [Vector2i(east, 0), Vector2i(-east - 2, 0), Vector2i(0, east + 6), Vector2i(0, -east - 10),
				Vector2i(east + 10, 14), Vector2i(-east - 12, -14), Vector2i(east + 20, -20), Vector2i(-east - 20, 22)][t]
			var placed_home := _place(home, centre, "%s@%d,%d" % [_kinds[k]["id"], rx, ry], d)
			if _dry(placed_home):
				return placed_home
			continue
		else:
			var margin := 48
			centre = Vector2i(rx * size + margin + int(_hash(k, rx, ry, 10 + t) * (size - 2 * margin)),
				ry * size + margin + int(_hash(k, rx, ry, 30 + t) * (size - 2 * margin)))
		var built := style_at(d, centre)
		var layout := _layout(k, rx, ry, built)
		var placed := _place(layout, centre, "%s@%d,%d" % [_kinds[k]["id"], rx, ry], built)
		if _dry(placed):
			return placed
	return {}


## A kind as it is built where its middle is `at`: its style for the biome
## there, if it has one.
func style_at(d: Dictionary, at: Vector2i) -> Dictionary:
	if not _biome.is_valid():
		return d
	var here := String(_biome.call(at.x, at.y))
	for st: Dictionary in d.get("styles", []):
		if (st["biomes"] as Array).has(here):
			var built := d.duplicate()
			built.merge(st, true)
			return built
	return d


## What a settlement has, before it is put anywhere: its buildings (sizes,
## furniture, dwellers), fields and pen, laid out relative to its centre.
func _layout(k: int, rx: int, ry: int, d: Dictionary) -> Dictionary:
	var houses: Array = d["houses"]
	var n := int(houses[0]) + int(_hash(k, rx, ry, 2) * (int(houses[1]) - int(houses[0]) + 1))
	var kinds: Array = d["buildings"]
	var used := {}
	var chosen := []
	for i in n:
		var total := 0.0
		for b: Dictionary in kinds:
			if not b.has("max") or int(used.get(b["id"], 0)) < int(b["max"]):
				total += float(b.get("weight", 1.0))
		var roll := _hash(k, rx, ry, 100 + i) * total
		for b: Dictionary in kinds:
			if b.has("max") and int(used.get(b["id"], 0)) >= int(b["max"]):
				continue
			roll -= float(b.get("weight", 1.0))
			if roll < 0.0:
				chosen.append(b)
				used[b["id"]] = int(used.get(b["id"], 0)) + 1
				break
	# Rows along streets: a row is at most WIDTH cells; a building's door on
	# its south wall opens onto the street just below it.
	const WIDTH := 30
	var rows := [[]]
	var x := 0
	var tallest := 4
	for b: Dictionary in chosen:
		var w := int(b["size"][0])
		tallest = maxi(tallest, int(b["size"][1]))
		if x > 0 and x + w > WIDTH:
			rows.append([])
			x = 0
		(rows[-1] as Array).append([b, x])
		x += w + 2
	var row_step := tallest + 4
	var buildings := []
	var widest := 0
	for r in rows.size():
		var row: Array = rows[r]
		var width := int(row[-1][1]) + int(row[-1][0]["size"][0]) if not row.is_empty() else 0
		widest = maxi(widest, width)
		for e: Array in row:
			var b: Dictionary = e[0]
			var w := int(b["size"][0])
			var h := int(b["size"][1])
			buildings.append({"template": b, "rect": Rect2i(int(e[1]) - width / 2, r * row_step - h, w, h)})
	var streets := []
	for r in rows.size():
		streets.append(Rect2i(-widest / 2 - 2, r * row_step, widest + 4, 2))
	var low := (rows.size() - 1) * row_step + 4
	var fields := []
	var fx := -widest / 2
	var fd: Dictionary = d.get("fields", {})
	if not fd.is_empty():
		var count: Array = fd["count"]
		var fn := int(count[0]) + int(_hash(k, rx, ry, 3) * (int(count[1]) - int(count[0]) + 1))
		for i in fn:
			var crop := _pick(fd["crops"], _hash(k, rx, ry, 200 + i))
			fields.append({"rect": Rect2i(fx, low, int(fd["size"][0]), int(fd["size"][1])), "crop": crop,
				"planted_hours": _hash(k, rx, ry, 220 + i) * 60.0})
			fx += int(fd["size"][0]) + 1
	var pen := {}
	var pd: Dictionary = d.get("pen", {})
	if not pd.is_empty():
		pen = {"rect": Rect2i(fx + 1, low, int(pd["size"][0]), int(pd["size"][1])), "animals": pd.get("animals", {})}
	var far := maxi(widest / 2 + 3, fx + 1 + int(pd.get("size", [0, 0])[0]))
	return {"buildings": buildings, "streets": streets, "fields": fields, "pen": pen,
		"half": far, "fire": Vector2i(0, 1)}


## The layout put at `centre`: every cell it sets.
func _place(layout: Dictionary, centre: Vector2i, id: String, d: Dictionary) -> Dictionary:
	var cells := {}
	var bounds := Rect2i(centre, Vector2i.ONE)
	var village := {"village": id}
	var put := func(at: Vector2i, layer: String, what: String, props := {}) -> void:
		var cell: Dictionary = cells.get_or_add(at, {})
		cell[layer] = what
		if not props.is_empty():
			(cell.get_or_add("props", {}) as Dictionary).merge(props, true)
	var clear_round := func(r: Rect2i) -> void:
		for y in range(r.position.y - MARGIN, r.end.y + MARGIN):
			for x in range(r.position.x - MARGIN, r.end.x + MARGIN):
				(cells.get_or_add(Vector2i(x, y), {}) as Dictionary)["cover"] = ""
	for s: Rect2i in layout["streets"]:
		var r := Rect2i(s.position + centre, s.size)
		bounds = bounds.merge(r)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				put.call(Vector2i(x, y), "ground", String(d["road"]))
				put.call(Vector2i(x, y), "cover", "")
	var homes := []
	for b: Dictionary in layout["buildings"]:
		var r := Rect2i((b["rect"] as Rect2i).position + centre, (b["rect"] as Rect2i).size)
		bounds = bounds.merge(r.grow(MARGIN))
		clear_round.call(r)
		var door := Vector2i(r.position.x + r.size.x / 2, r.end.y - 1)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var at := Vector2i(x, y)
				put.call(at, "ground", String(d["floor"]))
				var edge := x == r.position.x or x == r.end.x - 1 or y == r.position.y or y == r.end.y - 1
				if not edge:
					put.call(at, "roof", String(d["roof"]))
					put.call(at, "structure", "")
					continue
				if at == door:
					put.call(at, "structure", String(d["door"]), village)
				elif y == r.end.y - 1 and r.size.x >= 5 and (x == r.position.x + 1 or x == r.end.x - 2):
					put.call(at, "structure", String(d["window"]), village.merged({"facing": "s"}))
				else:
					put.call(at, "structure", String(d["wall"]), village)
		# Furniture along the back wall; the first is where its dweller sleeps.
		var furniture: Array = b["template"].get("furniture", [])
		var bed := NONE
		for i in furniture.size():
			var at := Vector2i(r.position.x + 1 + i, r.position.y + 1)
			var props := village.duplicate()
			if content.get_def(String(furniture[i])).has("container"):
				props["store"] = "%s|%d|%d" % [id, at.x, at.y]  # its own inventory, the same every time
			put.call(at, "structure", String(furniture[i]), props)
			if content.get_def(String(furniture[i])).get("bed", false) and bed == NONE:
				bed = at
		homes.append({"name": String(b["template"].get("name", "")), "dweller": String(b["template"]["dweller"]),
			"rect": r, "door": door, "bed": bed})
	var fire: Vector2i = layout["fire"] + centre
	put.call(fire, "structure", String(d["square"]), village)
	var fields := []
	for f: Dictionary in layout["fields"]:
		var r := Rect2i((f["rect"] as Rect2i).position + centre, (f["rect"] as Rect2i).size)
		bounds = bounds.merge(r.grow(MARGIN))
		clear_round.call(r)
		var planted := -int(float(f["planted_hours"]) * Daylight.HOUR_MS)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				put.call(Vector2i(x, y), "ground", String(d["fields"]["ground"]))
				put.call(Vector2i(x, y), "cover", String(f["crop"]), {"cover": {"planted": planted}})
		fields.append(r)
	var pen := {}
	if not (layout["pen"] as Dictionary).is_empty():
		var p: Dictionary = layout["pen"]
		var r := Rect2i((p["rect"] as Rect2i).position + centre, (p["rect"] as Rect2i).size)
		bounds = bounds.merge(r.grow(MARGIN))
		clear_round.call(r)
		var gate := Vector2i(r.position.x + r.size.x / 2, r.position.y)
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var at := Vector2i(x, y)
				if x == r.position.x or x == r.end.x - 1 or y == r.position.y or y == r.end.y - 1:
					put.call(at, "structure", String(d["pen"]["gate"] if at == gate else d["pen"]["fence"]), village)
				else:
					put.call(at, "structure", "")
		pen = {"rect": r, "gate": gate, "animals": p["animals"]}
	# Where roads come in: either end of the first street, and how far out
	# its fields and pen reach on each side (a road turns beyond them).
	var first: Rect2i = layout["streets"][0]
	var ends := [Vector2i(first.position.x - 1, first.position.y) + centre, Vector2i(first.end.x, first.position.y) + centre]
	return {"id": id, "kind": String(d.get("id", "")), "name": String(d.get("name", "")), "centre": centre,
		"bounds": bounds, "cells": cells, "homes": homes, "fields": fields, "pen": pen, "fire": fire,
		"ends": ends, "half": int(layout["half"]), "road": String(d["road"]), "bridge": String(d.get("bridge", ""))}


## Roads whose cells may fall in chunk (cx, cy): {"id", "bounds", "cells"}
## like a plan's ({cell: {"ground", "cover"}}), water left as it is.
func roads_touching(cx: int, cy: int) -> Array:
	var out := []
	var chunk := Rect2i(cx * Chunk.SIZE, cy * Chunk.SIZE, Chunk.SIZE, Chunk.SIZE)
	for k in _kinds.size():
		var size := int(_kinds[k]["def"]["region_chunks"]) * Chunk.SIZE
		var r := Vector2i(floori(float(chunk.position.x) / size), floori(float(chunk.position.y) / size))
		for dy in range(-2, 2):
			for dx in range(-2, 2):
				for dir in 2:
					var road := road_of(k, r.x + dx, r.y + dy, dir)
					if not road.is_empty() and (road["bounds"] as Rect2i).intersects(chunk):
						out.append(road)
	return out


## The road from a region's settlement east (dir 0) or south (dir 1); {} none.
func road_of(k: int, rx: int, ry: int, dir: int) -> Dictionary:
	var key := "%d|%d|%d|%d" % [k, rx, ry, dir]
	if _roads.has(key):
		return _roads[key]
	var made := _road(k, rx, ry, dir)
	if _roads.size() > 1024:
		_roads.clear()
	_roads[key] = made
	return made


func _road(k: int, rx: int, ry: int, dir: int) -> Dictionary:
	var a := plan(k, rx, ry)
	if a.is_empty():
		return {}
	var east := plan(k, rx + 1, ry)
	var east_road := not east.is_empty() and _hash(k, rx, ry, 500) < ROAD_CHANCE
	var path: Array[Vector2i] = []
	if dir == 0:
		if not east_road:
			return {}
		var meet := _meeting(k, rx, ry, a, east)
		path = _leg(a, meet) + _leg(east, meet)
	else:
		var south := plan(k, rx, ry + 1)
		if south.is_empty() or _hash(k, rx, ry, 501) >= ROAD_CHANCE:
			return {}
		if east_road and _hash(k, rx, ry, 502) < JUNCTION_CHANCE:
			# A crossroads: partway along the eastern road's first stretch.
			var meet := _meeting(k, rx, ry, a, east)
			var leg := _leg(a, meet)
			var at := leg[int(leg.size() * (0.4 + 0.3 * _hash(k, rx, ry, 503)))]
			path = _leg(south, at)
		else:
			path = _leg(a, _meeting(k, rx, ry + 1, a, south)) + _leg(south, _meeting(k, rx, ry + 1, a, south))
	var cells := {}
	var ground := String(a["road"])
	var bridge := String(a["bridge"])
	var bounds := Rect2i(path[0], Vector2i.ONE)
	# Wet stretches of the way: short ones are bridged, long ones not crossed.
	var dry := []
	var run := []
	for p: Vector2i in path + [Vector2i(1 << 30, 0)]:
		if p.x != 1 << 30 and _wet.call(p.x, p.y):
			run.append(p)
			continue
		if run.size() <= BRIDGE_MAX:
			dry.append_array(run)
		run.clear()
		if p.x != 1 << 30:
			dry.append(p)
	for p: Vector2i in dry:
		for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:  # two cells wide
			var at := p + d
			cells[at] = {"ground": ground, "cover": "", "over_water": bridge}
			bounds = bounds.merge(Rect2i(at, Vector2i.ONE))
	return {"id": "road:%d,%d,%d" % [rx, ry, dir], "key": [k, rx, ry, dir], "bounds": bounds, "cells": cells, "path": dry}


## Where a road between two settlements turns to meet itself: halfway,
## a little off the middle.
func _meeting(k: int, rx: int, ry: int, a: Dictionary, b: Dictionary) -> Vector2i:
	var mid := (Vector2(a["centre"]) + Vector2(b["centre"])) * 0.5
	var off := Vector2(_hash(k, rx, ry, 510) - 0.5, _hash(k, rx, ry, 511) - 0.5) * 16.0
	return Vector2i(mid + off)


## A road's cells from a settlement's street end out to `to`: along the
## street's line out past its fields, then straight across, then along.
func _leg(p: Dictionary, to: Vector2i) -> Array[Vector2i]:
	var ends: Array = p["ends"]
	var centre: Vector2i = p["centre"]
	var side := 1 if to.x >= centre.x else -1
	var from: Vector2i = ends[1] if side > 0 else ends[0]
	var turn := centre.x + side * (int(p["half"]) + ROAD_OUT)
	if (to.x - turn) * side > 0:
		turn = to.x
	var out: Array[Vector2i] = []
	_line(out, from, Vector2i(turn, from.y))
	_line(out, Vector2i(turn, from.y), Vector2i(turn, to.y))
	_line(out, Vector2i(turn, to.y), to)
	return out


static func _line(out: Array[Vector2i], a: Vector2i, b: Vector2i) -> void:
	var step := Vector2i(signi(b.x - a.x), signi(b.y - a.y))
	var at := a
	out.append(at)
	while at != b:
		at += step
		out.append(at)


## Whether a placed plan stands on dry land (a little water at its edge is
## let be: it is made ground under its cells).
func _dry(p: Dictionary) -> bool:
	var r: Rect2i = p["bounds"]
	if r.intersects(Rect2i(-_clearing - 1, -_clearing - 1, 2 * _clearing + 3, 2 * _clearing + 3)):
		return false
	var wet := 0
	var all := 0
	for y in range(r.position.y, r.end.y, 2):
		for x in range(r.position.x, r.end.x, 2):
			all += 1
			if _wet.call(x, y):
				wet += 1
	return all > 0 and float(wet) / all <= WET_SHARE


func _pick(weights: Dictionary, roll: float) -> String:
	var total := 0.0
	for id: String in weights:
		total += float(weights[id])
	var r := roll * total
	for id: String in weights:
		r -= float(weights[id])
		if r < 0.0:
			return id
	return String(weights.keys()[0]) if not weights.is_empty() else ""


func _hash(k: int, rx: int, ry: int, salt: int) -> float:
	return float(absi(hash([world_seed, "settlement", k, rx, ry, salt])) % 1000003) / 1000003.0
