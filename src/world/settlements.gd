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
const TRIES := 8
## Of a plan's cells, at most this share may be water for it to stand there.
const WET_SHARE := 0.03

var world_seed := 0
var content: ContentRegistry
## Settlement kinds, in content id order: [{"id", "def"}].
var _kinds: Array = []
## The spawn clearing's half size (no settlement in it).
var _clearing := 8
## (x, y) -> whether the surface there is water (the surface generator's).
var _wet: Callable
## "kind|rx|ry" -> plan ({} none)
var _plans := {}


func _init(seed_value: int, registry: ContentRegistry, wet: Callable, clearing: int) -> void:
	world_seed = seed_value
	content = registry
	_wet = wet
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
	var layout := _layout(k, rx, ry, d)
	for t in TRIES:
		var centre: Vector2i
		if near_spawn:
			# A short walk from the spawn point, out of its clearing.
			var east := _clearing + 4 + int(layout["half"])
			centre = [Vector2i(east, 0), Vector2i(-east - 2, 0), Vector2i(0, east + 6), Vector2i(0, -east - 10),
				Vector2i(east + 10, 14), Vector2i(-east - 12, -14), Vector2i(east + 20, -20), Vector2i(-east - 20, 22)][t]
		else:
			var margin := 48
			centre = Vector2i(rx * size + margin + int(_hash(k, rx, ry, 10 + t) * (size - 2 * margin)),
				ry * size + margin + int(_hash(k, rx, ry, 30 + t) * (size - 2 * margin)))
		var placed := _place(layout, centre, "%s@%d,%d" % [_kinds[k]["id"], rx, ry], d)
		if _dry(placed):
			return placed
	return {}


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
	return {"id": id, "kind": String(d.get("id", "")), "name": String(d.get("name", "")), "centre": centre,
		"bounds": bounds, "cells": cells, "homes": homes, "fields": fields, "pen": pen, "fire": fire}


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
