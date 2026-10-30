class_name Settlements
extends RefCounted
## Where settlements are and how they are laid out (ADR-0038, ADR-0054): a
## function of the world seed, like the caves — a chunk made in any order
## gets its part of a village, worked out only round where someone is. Kinds
## of settlement are content ("settlement"): what they are built of, their
## buildings, fields and pen, their ways of life; this lays them out.
##
## Villages come in clusters (ADR-0054). The world is cut into districts of
## `district_chunks` chunks; a district holds a cluster of a few villages on
## the best places in it (by water, flat low land), or none — wild land. The
## villages of a cluster are joined by roads; a cluster is joined with the
## one in the district east or south of it by chance, so a road leaves a
## cluster into land no one has seen yet and goes on there when someone
## comes; some clusters are joined with none. Roads go round heights and big
## waters, over passes, across rivers by fords and short bridges.
##
## A village's way of life (its "ways") is of its place: by the water it
## fishes, by the mountains it mines and forges, on open grassland it herds,
## else it farms — more houses of that trade.
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
## Tries of a place for each village of a cluster.
const TRIES := 16
## Of a plan's cells, at most this share may be water for it to stand there
## (a pond in a village is let be; under its own cells water becomes land).
const WET_SHARE := 0.12
## Cells between the middles of two villages of a cluster, at least.
const APART := 90
## Cells from a district's edge a village's middle keeps.
const EDGE := 48
## Roads keep this far out of a settlement's side before turning.
const ROAD_OUT := 3
## Water a road crosses on a bridge (in its path's cells); longer, it breaks off.
const BRIDGE_MAX := 16
## Roads are found on a grid of this many cells (then drawn cell by cell).
const ROUTE_STEP := 8
## Cells round two villages a road between them may wander.
const ROUTE_MARGIN := 96

var world_seed := 0
var content: ContentRegistry
## Settlement kinds, in content id order: [{"id", "def"}].
var _kinds: Array = []
## The spawn clearing's half size (no settlement in it).
var _clearing := 8
## (x, y) -> whether a settlement may not stand there (water, shore, rock,
## the heights): the surface generator's.
var _wet: Callable
## (x, y) -> the biome there ("" water): a settlement's style by its middle.
var _biome: Callable
## (x, y) -> the land there: {"what", "height", "biome"} (the surface
## generator's land_at); invalid — flat dry land everywhere.
var _land: Callable
## "kind|dx|dy" -> [plans] of the district's cluster ([] wild land)
var _villages := {}
## "kind|dx|dy" -> the roads the district owns, before their ways are found:
## its cluster's own, and those to the clusters east and south of it.
var _planned := {}
## "kind|dx|dy|i" -> a road with its way ({} — none over the land).
var _roads := {}
## Grid point (Vector2i, in ROUTE_STEP cells) -> how hard a road goes there
## (INF: not at all), and its height.
var _ground_cost := {}
## Forest outlaws share the district map, not the peaceful village economy.
var camps: BanditCampPlans
var inns: HospitalityPlans


func _init(seed_value: int, registry: ContentRegistry, wet: Callable, clearing: int, biome := Callable(), land := Callable()) -> void:
	world_seed = seed_value
	content = registry
	_wet = wet
	_biome = biome
	_land = land
	_clearing = clearing
	var ids: Array = []
	for id: String in registry.defs:
		if registry.kind_of(id) == "settlement":
			ids.append(id)
	ids.sort()
	for id: String in ids:
		_kinds.append({"id": id, "def": registry.get_def(id)})
	camps = BanditCampPlans.new(self)
	inns = HospitalityPlans.new(self)


func _district_size(k: int) -> int:
	return int(_kinds[k]["def"]["district_chunks"]) * Chunk.SIZE


func _district_of(k: int, at: Vector2i) -> Vector2i:
	var size := _district_size(k)
	return Vector2i(floori(float(at.x + size / 2) / size), floori(float(at.y + size / 2) / size))


## The cells of a district: the grid of districts has the spawn point in the
## middle of district (0, 0).
func _district_rect(k: int, dx: int, dy: int) -> Rect2i:
	var size := _district_size(k)
	return Rect2i(dx * size - size / 2, dy * size - size / 2, size, size)


## Cells a village's plan reaches past its district's inner edge (EDGE): its
## half (houses, fields, pen) at most.
const REACH := 64


## Plans of every settlement whose cells may fall in chunk (cx, cy). Only
## the districts whose villages could reach the chunk are worked out.
func plans_touching(cx: int, cy: int) -> Array:
	var out := []
	var chunk := Rect2i(cx * Chunk.SIZE, cy * Chunk.SIZE, Chunk.SIZE, Chunk.SIZE)
	for k in _kinds.size():
		var r := _district_of(k, chunk.position)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var area := _district_rect(k, r.x + dx, r.y + dy).grow(REACH - EDGE)
				if not area.intersects(chunk):
					continue
				for p: Dictionary in villages(k, r.x + dx, r.y + dy):
					if (p["bounds"] as Rect2i).intersects(chunk):
						out.append(p)
	return out


## The villages of a district's cluster ([] — none there).
func villages(k: int, dx: int, dy: int) -> Array:
	var key := "%d|%d|%d" % [k, dx, dy]
	if _villages.has(key):
		return _villages[key]
	var made := _cluster(k, dx, dy)
	if _villages.size() > 512:
		_villages.clear()
	_villages[key] = made
	return made


## The settlement by the spawn point (of the first kind marked "near_spawn"); {} none.
func home_plan() -> Dictionary:
	for k in _kinds.size():
		if _kinds[k]["def"].get("near_spawn", false):
			var d := _district_of(k, Vector2i.ZERO)
			for p: Dictionary in villages(k, d.x, d.y):
				if bool(p.get("home", false)):
					return p
	return {}


## A settlement's plan by its id ("kind@dx,dy#i"); {} if there is none.
func plan_by_id(id: String) -> Dictionary:
	var at := id.rfind("@")
	var hash_at := id.rfind("#")
	if at < 0 or hash_at < at:
		return {}
	var kind := id.substr(0, at)
	var r := id.substr(at + 1, hash_at - at - 1).split(",")
	if r.size() != 2:
		return {}
	var i := int(id.substr(hash_at + 1))
	for k in _kinds.size():
		if _kinds[k]["id"] == kind:
			var list := villages(k, int(r[0]), int(r[1]))
			return list[i] if i >= 0 and i < list.size() else {}
	return {}


## The settlements of all kinds within `radius` cells of a point (villagers, maps).
func plans_near(at: Vector2i, radius: int) -> Array:
	var out := []
	for k in _kinds.size():
		var size := _district_size(k)
		var r := _district_of(k, at)
		var reach := ceili(float(radius) / size) + 1
		for dy in range(r.y - reach, r.y + reach + 1):
			for dx in range(r.x - reach, r.x + reach + 1):
				for p: Dictionary in villages(k, dx, dy):
					if Vector2(p["centre"]).distance_to(Vector2(at)) <= radius:
						out.append(p)
	return out


## A district's cluster: the first village on the best place in it (by the
## spawn point in the spawn's district), the others round it, each on the
## best of a few places, apart from the rest.
func _cluster(k: int, dx: int, dy: int) -> Array:
	var d: Dictionary = _kinds[k]["def"]
	var area := _district_rect(k, dx, dy).grow(-EDGE)
	var home: bool = d.get("near_spawn", false) and _district_of(k, Vector2i.ZERO) == Vector2i(dx, dy)
	if not home and _hash(k, dx, dy, 1) >= float(d["cluster_chance"]):
		return []
	var counts: Array = d["villages"]
	var n := int(counts[0]) + int(_hash(k, dx, dy, 2) * (int(counts[1]) - int(counts[0]) + 1))
	var out := []
	var seat := NONE
	if home:
		var p := _home(k, dx, dy, d)
		if not p.is_empty():
			out.append(p)
			seat = p["centre"]
	var spread := int(d["spread"])
	for i in range(out.size(), n * 2):
		if out.size() >= n:
			break
		var best := {}
		var best_score := -INF
		for t in TRIES:
			var centre: Vector2i
			if seat == NONE:
				centre = area.position + Vector2i(int(_hash(k, dx, dy, 10 + t + i * 64) * area.size.x),
					int(_hash(k, dx, dy, 30 + t + i * 64) * area.size.y))
			else:
				var angle := _hash(k, dx, dy, 10 + t + i * 64) * TAU
				var far := lerpf(APART, spread, _hash(k, dx, dy, 30 + t + i * 64))
				centre = seat + Vector2i(Vector2.from_angle(angle) * far)
			if not area.has_point(centre) or out.any(func(o: Dictionary) -> bool:
					return Vector2(o["centre"]).distance_to(Vector2(centre)) < APART):
				continue
			var score := _site_score(centre)
			if score <= best_score:
				continue
			var id := "%s@%d,%d#%d" % [_kinds[k]["id"], dx, dy, out.size()]
			var built := _way(style_at(d, centre), centre)
			var placed := _place(_layout(k, dx, dy * 16 + out.size(), built), centre, id, built)
			if _dry(placed) and not out.any(func(o: Dictionary) -> bool:
					return (o["bounds"] as Rect2i).grow(4).intersects(placed["bounds"])):
				best = placed
				best_score = score
		if not best.is_empty():
			out.append(best)
			if seat == NONE:
				seat = best["centre"]
	return out


## The village by the spawn point: a short walk from it, out of its clearing
## (its own look: no style, the first place one sees).
func _home(k: int, dx: int, dy: int, d: Dictionary) -> Dictionary:
	var built := _way(d, Vector2i.ZERO)
	var home := _layout(k, dx, dy * 16, built)
	var east := _clearing + 4 + int(home["half"])
	for centre: Vector2i in [Vector2i(east, 0), Vector2i(-east - 2, 0), Vector2i(0, east + 6), Vector2i(0, -east - 10),
			Vector2i(east + 10, 14), Vector2i(-east - 12, -14), Vector2i(east + 20, -20), Vector2i(-east - 20, 22)]:
		var placed := _place(home, centre, "%s@%d,%d#0" % [_kinds[k]["id"], dx, dy], built)
		if _dry(placed):
			placed["home"] = true
			return placed
	return {}


## How good a place is for a village: water near (to drink, to fish), the
## land low and flat; never the heights.
func _site_score(at: Vector2i) -> float:
	if not _land.is_valid():
		return 0.0
	var here: Dictionary = _land.call(at.x, at.y)
	var h := float(here["height"])
	if String(here["what"]) != "land" or h > Geography.HILLS + 0.1:
		return -INF
	var score := -absf(h - 0.08) * 4.0
	var water := 0
	var rough := 0.0
	for i in 8:
		var dir := Vector2.from_angle(i * TAU / 8.0)
		for r: int in [16, 40]:
			var p := at + Vector2i(dir * r)
			var there: Dictionary = _land.call(p.x, p.y)
			if String(there["what"]) in ["water", "shallows", "shore", "deep"]:
				water += 1
			else:
				rough += absf(float(there["height"]) - h)
	score += minf(water, 4) * 0.5 - rough * 2.0
	return score


## A kind as it lives at a place (ADR-0054): the first of its "ways" whose
## place it is — by the water, by the mountains, on open grassland — more of
## its houses of that trade; the last way (no "near") where none is.
func _way(d: Dictionary, at: Vector2i) -> Dictionary:
	var ways: Array = d.get("ways", [])
	if ways.is_empty():
		return d
	var chosen: Dictionary = ways[-1]
	for w: Dictionary in ways:
		if _near(String(w.get("near", "")), at):
			chosen = w
			break
	var built := d.duplicate()
	var buildings: Array = []
	for b: Dictionary in d["buildings"]:
		var more: Dictionary = (chosen.get("buildings", {}) as Dictionary).get(b["id"], {})
		buildings.append(b.merged(more, true) if not more.is_empty() else b)
	built["buildings"] = buildings
	built["way"] = String(chosen["id"])
	built["first"] = String(chosen.get("first", ""))
	built["way_name"] = String(chosen.get("name", ""))
	return built


## Whether a place is "near" something (a way's condition): "" — anywhere.
func _near(what: String, at: Vector2i) -> bool:
	if what == "" or not _land.is_valid():
		return what == ""
	var found := 0
	for i in 8:
		var dir := Vector2.from_angle(i * TAU / 8.0)
		for r: int in ([24, 48] if what == "water" else [60, 120]):
			var p := at + Vector2i(dir * r)
			var there: Dictionary = _land.call(p.x, p.y)
			match what:
				"water":
					found += 1 if String(there["what"]) in ["water", "shallows", "deep"] else 0
				"mountains":
					found += 1 if float(there["height"]) > Geography.MOUNTAINS - 0.05 else 0
				"grassland":
					found += 1 if String(_biome.call(p.x, p.y)) in ["base:meadow", "base:steppe"] else 0
	return found >= (2 if what != "grassland" else 12)


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
	# Its way of life's own trade first (ADR-0054): a fishing village has a fisher.
	for b: Dictionary in kinds:
		if String(b["id"]) == String(d.get("first", "")):
			chosen.append(b)
			used[b["id"]] = 1
	for i in range(chosen.size(), n):
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
		"ends": ends, "half": int(layout["half"]), "road": String(d["road"]), "bridge": String(d.get("bridge", "")),
		"way": String(d.get("way", "")), "way_name": String(d.get("way_name", ""))}


## Roads whose cells may fall in chunk (cx, cy): {"id", "key", "bounds",
## "cells", "path"} — cells like a plan's ({cell: {"ground", "cover",
## "over_water"}}), path the road's cells in order. A road's way is found
## only when a chunk lies where it may run (the box round its villages).
func roads_touching(cx: int, cy: int) -> Array:
	var out := []
	var chunk := Rect2i(cx * Chunk.SIZE, cy * Chunk.SIZE, Chunk.SIZE, Chunk.SIZE)
	for k in _kinds.size():
		var size := _district_size(k)
		var r := _district_of(k, chunk.position)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				# A district's roads stay within its area and the next ones'.
				var area := _district_rect(k, r.x + dx, r.y + dy).merge(_district_rect(k, r.x + dx + 1, r.y + dy + 1)).grow(ROUTE_MARGIN + REACH)
				if not area.intersects(chunk):
					continue
				var planned := _planned_roads(k, r.x + dx, r.y + dy)
				for i in planned.size():
					if (planned[i]["box"] as Rect2i).intersects(chunk):
						var road := road_of(k, r.x + dx, r.y + dy, i)
						if not road.is_empty() and (road["bounds"] as Rect2i).intersects(chunk):
							out.append(road)
	return out


## The roads a district owns, their ways found ([] none).
func roads_of(k: int, dx: int, dy: int) -> Array:
	var out := []
	for i in _planned_roads(k, dx, dy).size():
		var road := road_of(k, dx, dy, i)
		if not road.is_empty():
			out.append(road)
	return out


## A road by its key ([kind, dx, dy, i]): its way found once and kept; {} if
## there is none (no way over the land).
func road_of(k: int, dx: int, dy: int, i: int) -> Dictionary:
	var planned := _planned_roads(k, dx, dy)
	if i < 0 or i >= planned.size():
		return {}
	var key := "%d|%d|%d|%d" % [k, dx, dy, i]
	if _roads.has(key):
		return _roads[key]
	var pair: Array = planned[i]["pair"]
	var made := _road(pair[0], pair[1], [k, dx, dy, i])
	if _roads.size() > 1024:
		_roads.clear()
	_roads[key] = made
	return made


## The roads a district owns, before their ways are found: [{"pair": [a, b],
## "box": where its way may run}].
func _planned_roads(k: int, dx: int, dy: int) -> Array:
	var key := "%d|%d|%d" % [k, dx, dy]
	if _planned.has(key):
		return _planned[key]
	var made := []
	for pair: Array in _district_roads(k, dx, dy):
		var box := Rect2i(pair[0]["centre"], Vector2i.ONE).expand(pair[1]["centre"]).grow(ROUTE_MARGIN + REACH)
		made.append({"pair": pair, "box": box})
	if _planned.size() > 512:
		_planned.clear()
	_planned[key] = made
	return made


## A district's roads (pairs of villages): its villages joined by the shortest ways that join
## them all (each to the nearest not yet joined), then, by chance, its
## cluster with the one east and the one south — from the nearest two.
func _district_roads(k: int, dx: int, dy: int) -> Array:
	var mine := villages(k, dx, dy)
	if mine.is_empty():
		return []
	var pairs := []
	var joined := [mine[0]]
	var left := mine.slice(1)
	while not left.is_empty():
		var best := []
		var best_d := INF
		for a: Dictionary in joined:
			for b: Dictionary in left:
				var dist := Vector2(a["centre"]).distance_to(Vector2(b["centre"]))
				if dist < best_d:
					best_d = dist
					best = [a, b]
		pairs.append(best)
		joined.append(best[1])
		left.erase(best[1])
	var d: Dictionary = _kinds[k]["def"]
	for dir in 2:
		var other := villages(k, dx + (1 - dir), dy + dir)
		if other.is_empty() or _hash(k, dx, dy, 600 + dir) >= float(d["link_chance"]):
			continue
		var best := []
		var best_d := INF
		for a: Dictionary in mine:
			for b: Dictionary in other:
				var dist := Vector2(a["centre"]).distance_to(Vector2(b["centre"]))
				if dist < best_d:
					best_d = dist
					best = [a, b]
		pairs.append(best)
	return pairs


## A road between two villages: out along the street of each, past its
## fields, then the easiest way over the land between (A* on a grid of
## ROUTE_STEP cells); {} if there is none (the sea between).
func _road(a: Dictionary, b: Dictionary, key: Array) -> Dictionary:
	var from_a := _way_out(a, b["centre"])
	var from_b := _way_out(b, a["centre"])
	var route := _route(from_a[-1], from_b[-1], [a["bounds"], b["bounds"]])
	if route.is_empty():
		return {}
	var path: Array[Vector2i] = []
	path.append_array(from_a)
	for i in range(1, route.size()):
		var seg: Array[Vector2i] = []
		_line(seg, route[i - 1], route[i])
		path.append_array(seg.slice(1))
	var back := from_b.duplicate()
	back.reverse()
	path.append_array(back)
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
		for o: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:  # two cells wide
			var at := p + o
			cells[at] = {"ground": ground, "cover": "", "over_water": bridge}
			bounds = bounds.merge(Rect2i(at, Vector2i.ONE))
	return {"id": "road:%d,%d,%d" % [key[1], key[2], key[3]], "key": key, "bounds": bounds, "cells": cells, "path": dry,
		"from": a["id"], "to": b["id"]}


## A village's way out toward `to`: along its first street past its side,
## ROAD_OUT beyond its fields and pen.
func _way_out(p: Dictionary, to: Vector2i) -> Array[Vector2i]:
	var ends: Array = p["ends"]
	var centre: Vector2i = p["centre"]
	var side := 1 if to.x >= centre.x else -1
	var from: Vector2i = ends[1] if side > 0 else ends[0]
	var out: Array[Vector2i] = []
	_line(out, from, Vector2i(centre.x + side * (int(p["half"]) + ROAD_OUT), from.y))
	return out


## The easiest way from `a` to `b` (cells), as points ROUTE_STEP apart: A*
## over the grid, the cost of a point by the land there — rock and deep
## water not at all, water dear (a bridge), shallows a little (a ford), the
## heights and slopes dear (so passes); `avoid` rects (the villages' own) not
## gone through. [] if there is no way.
func _route(a: Vector2i, b: Vector2i, avoid: Array) -> Array[Vector2i]:
	var s := ROUTE_STEP
	var ga := Vector2i(roundi(float(a.x) / s), roundi(float(a.y) / s))
	var gb := Vector2i(roundi(float(b.x) / s), roundi(float(b.y) / s))
	var box := Rect2i(ga, Vector2i.ONE).expand(gb).grow(ROUTE_MARGIN / s)
	var w := box.size.x + 1
	var h := box.size.y + 1
	var cost := PackedFloat32Array()
	cost.resize(w * h)
	cost.fill(INF)
	var came := PackedInt32Array()
	came.resize(w * h)
	came.fill(-1)
	var heap := _Heap.new()
	var start := (ga.y - box.position.y) * w + (ga.x - box.position.x)
	var goal := (gb.y - box.position.y) * w + (gb.x - box.position.x)
	cost[start] = 0.0
	heap.push(start, 0.0)
	var done := PackedByteArray()
	done.resize(w * h)
	while not heap.is_empty():
		var at := heap.pop()
		if at == goal:
			break
		if done[at]:
			continue
		done[at] = 1
		var p := Vector2i(at % w, at / w)
		var here := _point(box.position + p)
		for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
			var q := p + o
			if q.x < 0 or q.y < 0 or q.x >= w or q.y >= h:
				continue
			var m := q.y * w + q.x
			if done[m]:
				continue
			var g := box.position + q
			var cell := g * s
			var inside := false
			for r: Rect2i in avoid:
				inside = inside or r.grow(2).has_point(cell)
			if inside and m != goal:
				continue
			var there := _point(g)
			if there.x == INF:
				continue
			var step := (1.4142 if o.x != 0 and o.y != 0 else 1.0) * (there.x + 40.0 * absf(there.y - here.y))
			if cost[at] + step < cost[m]:
				cost[m] = cost[at] + step
				came[m] = at
				heap.push(m, cost[m] + Vector2(q - Vector2i(gb - box.position)).length())
	if came[goal] < 0 and goal != start:
		return []
	var out: Array[Vector2i] = [b]
	var at := came[goal]
	while at >= 0 and at != start:
		out.append((box.position + Vector2i(at % w, at / w)) * s)
		at = came[at]
	out.append(a)
	out.reverse()
	return out


## How hard a road goes at a grid point, and the land's height there:
## Vector2(cost or INF, height). Kept, a road beside another asks again.
func _point(g: Vector2i) -> Vector2:
	var known: Variant = _ground_cost.get(g)
	if known != null:
		return known
	var v := Vector2(1.0, 0.1)
	if _land.is_valid():
		var at := g * ROUTE_STEP
		var land: Dictionary = _land.call(at.x, at.y)
		var height := float(land["height"])
		var c := 1.0
		match String(land["what"]):
			"deep", "rock":
				c = INF
			"water":
				c = 12.0  # a bridge
			"shallows":
				c = 2.5  # a ford
			"shore":
				c = 1.3
		if c != INF and height > Geography.HILLS:
			c += (height - Geography.HILLS) * 30.0  # heights are hard, mountains very
		v = Vector2(c, height)
	if _ground_cost.size() > 200000:
		_ground_cost.clear()
	_ground_cost[g] = v
	return v


## A small binary heap of (index, priority), least first.
class _Heap:
	var _keys := PackedInt32Array()
	var _pri := PackedFloat32Array()

	func is_empty() -> bool:
		return _keys.is_empty()

	func push(key: int, pri: float) -> void:
		_keys.append(key)
		_pri.append(pri)
		var i := _keys.size() - 1
		while i > 0:
			var up := (i - 1) / 2
			if _pri[up] <= _pri[i]:
				break
			_swap(i, up)
			i = up

	func pop() -> int:
		var top := _keys[0]
		var last := _keys.size() - 1
		_swap(0, last)
		_keys.resize(last)
		_pri.resize(last)
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var least := i
			if l < last and _pri[l] < _pri[least]:
				least = l
			if r < last and _pri[r] < _pri[least]:
				least = r
			if least == i:
				break
			_swap(i, least)
			i = least
		return top

	func _swap(a: int, b: int) -> void:
		var k := _keys[a]
		_keys[a] = _keys[b]
		_keys[b] = k
		var p := _pri[a]
		_pri[a] = _pri[b]
		_pri[b] = p


## Cells from a to b, each next to the last (diagonal steps too).
static func _line(out: Array[Vector2i], a: Vector2i, b: Vector2i) -> void:
	var d := b - a
	var n := maxi(absi(d.x), absi(d.y))
	out.append(a)
	for i in range(1, n + 1):
		out.append(a + Vector2i(roundi(float(d.x) * i / n), roundi(float(d.y) * i / n)))


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
