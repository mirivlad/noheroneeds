class_name SettlementLife
extends RefCounted
## Permanent changes to the seeded settlement, stored with the affected
## chunks. The geographical plan remains a reproducible starting point.

const WORK_DAYS := 3
const WAGES := 60
const SITE_TRIES := 24

var world: ServerWorld
var _states := {}


func _init(w: ServerWorld) -> void:
	world = w


func state(id: String) -> Dictionary:
	if not _states.has(id):
		var raw := world.fact("settlement_life|" + id)
		var initial := {"day": world.world_time / Daylight.DAY_MS, "next": 0, "homes": [], "project": {}}
		if raw != "":
			var saved := Cbor.decode(Marshalls.base64_to_raw(raw))
			assert(saved.ok and saved.value is Dictionary, "corrupt settlement state: " + id)
			_states[id] = saved.value
		else:
			_states[id] = initial
	return _states[id]


func _save(id: String) -> void:
	world.operation_fact("settlement_life|" + id, Marshalls.raw_to_base64(Cbor.encode(state(id))))
	# Materials, wages, construction and its news belong to one operation.
	world.operation_facts()


func step(id: String) -> void:
	var s := state(id)
	var today := world.world_time / Daylight.DAY_MS
	if today <= int(s["day"]):
		return
	var days := mini(today - int(s["day"]), WORK_DAYS)
	s["day"] = today
	world.settlement_population.step(id)
	if not (s["project"] as Dictionary).is_empty():
		for i in days:
			if not _advance(id, s):
				break
	else:
		var condition := world.economy.development(id)
		if String(condition["state"]) == "prosperous" and String(condition["trend"]) == "prosperous":
			_start(id, s)
	world.settlement_population.populate(id)
	_save(id)


## NPCs and chronicles see completed additions without mutating the
## generator's cached starting plan or changing the geographical snapshot.
func plan(id: String) -> Dictionary:
	var base := world.generator.settlements.plan_by_id(id) if world.generator else {}
	if base.is_empty():
		return {}
	var result := base.duplicate()
	var homes := (base["homes"] as Array).duplicate()
	for record: Dictionary in state(id)["homes"]:
		var r: Array = record["rect"]
		var bed: Array = record["bed"]
		var door: Array = record["door"]
		homes.append({"rect": Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])),
			"bed": Vector2i(int(bed[0]), int(bed[1])), "door": Vector2i(int(door[0]), int(door[1])),
			"dweller": record["dweller"], "name": record["name"], "building_id": String(record["building"]).trim_prefix(id + "|"),
			"architecture": {"turns": record["turns"], "storeys": 1 if (record["upper"] as Array).is_empty() else 2}})
	result["homes"] = homes
	return result


## A village stays active beside a player even when its last loaded
## household has left. Do not explore new districts for this hourly check.
func near_players() -> Array[String]:
	var out: Array[String] = []
	for id: String in _states.keys():
		var p := world.generator.settlements.plan_by_id(id) if world.generator else {}
		if p.is_empty():
			continue
		for actor: String in world.present:
			var player: Dictionary = world.present[actor]
			if world.levels.kind(String(player["location"])) not in [Levels.SURFACE, Levels.BUILDING_LEVEL]:
				continue
			var at: Vector2i = p["centre"] + world.cell_vector(p["centre"], Movement.cell_of(player["pos"]))
			if (p["bounds"] as Rect2i).grow(Chunk.SIZE).has_point(at):
				out.append(id)
				break
	return out


func _materials(id: String) -> Dictionary:
	var plan := world.generator.settlements.plan_by_id(id)
	var base := world.content.get_def(String(plan["kind"]))
	return world.generator.settlements.style_at(base, plan["centre"])


func _start(id: String, s: Dictionary) -> void:
	var people := world.settlement_population.state(id)
	if not (people["departed"] as Dictionary).is_empty() or not (people["leaving"] as Dictionary).is_empty():
		return  # restore existing households before spending on more houses
	for i in (s["homes"] as Array).size():
		if String(s["homes"][i].get("resident", "")) == "" and not (people["dead"] as Dictionary).has(str(int(people["base_homes"]) + i)):
			return
	var project := propose(id, int(s["next"]))
	if project.is_empty():
		# A house that cannot fit must not prevent trying a different design
		# on the next day. No resources have been reserved yet.
		s["next"] = int(s["next"]) + 1
		return
	var store := world.economy.store(id)
	if int(store["coins"]) < WAGES + VillageEconomy.POOR:
		return
	world.economy.earn(id, -WAGES)
	s["next"] = int(s["next"]) + 1
	s["project"] = project
	project["stage"] = -1
	project["remaining"] = (project["cost"] as Dictionary).duplicate()
	_collect(id, project)
	world.chronicles.note(id, "В поселении %s готовят новый дом: выделена оплата работ, материалы собирают из излишков и закупают у соседей." % world.chronicles.village_name(id))
	if (project["remaining"] as Dictionary).is_empty():
		_begin(id, project)


## Construction demand is additional to daily consumption, never eaten by
## the ordinary economy tick. Procurement must fit in the village's treasury.
func procurement(id: String) -> Dictionary:
	var project: Dictionary = state(id)["project"]
	var out := (project.get("remaining", {}) as Dictionary).duplicate() if int(project.get("stage", 0)) == -1 else {}
	if world.settlement_population:
		var repair := world.settlement_population.repair_demand(id)
		for item: String in repair:
			out[item] = int(out.get(item, 0)) + int(repair[item])
	return out


func _collect(id: String, project: Dictionary) -> void:
	var store := world.economy.store(id)
	if int(store["coins"]) < VillageEconomy.POOR:
		return
	var remaining: Dictionary = project["remaining"]
	for item: String in remaining.keys():
		var reserve := int(world.economy.needs(id).get(item, 0)) * VillageEconomy.SHORT_DAYS
		var n := mini(int(remaining[item]), maxi(0, int(store["stock"].get(item, 0)) - reserve))
		if n > 0:
			world.economy.take(id, item, n)
			remaining[item] = int(remaining[item]) - n
		if int(remaining[item]) == 0:
			remaining.erase(item)


func _begin(id: String, project: Dictionary) -> void:
	# Procurement can outlive the free plot. Recheck before laying anything;
	# reserved goods remain safe if a player has since occupied the site.
	var cells := {}
	for row: Array in project["cells"]:
		cells[Vector2i(int(row[0]), int(row[1]))] = row[2]
	if not _site_clear(cells):
		return
	_apply(project, 0)
	project["stage"] = 0
	world.chronicles.note(id, "В поселении %s начали возводить новый дом: материалы собраны, основание готово." % world.chronicles.village_name(id))


## A bounded search beside existing streets, using the full plot and all
## live cells. A failed search spends neither materials nor coins.
func propose(id: String, serial: int) -> Dictionary:
	var plan := world.generator.settlements.plan_by_id(id)
	if plan.is_empty():
		return {}
	var materials := _materials(id)
	var template: Dictionary = materials["buildings"][0]
	var preferred := String(world.economy.way_of(id).get("first", "house"))
	for candidate: Dictionary in materials["buildings"]:
		if String(candidate["id"]) == preferred:
			template = candidate
			break
	var design := SettlementArchitecture.plan(world.world_seed, id, "growth:%d" % serial, template, String(plan["tradition"]))
	if world.max_levels < 1:
		design["storeys"] = 1
	var streets: Array[Vector2i] = []
	for at: Vector2i in plan["cells"]:
		var spec: Dictionary = plan["cells"][at]
		if String(spec.get("ground", "")) == String(plan["road"]) and String(spec.get("structure", "")) == "" and (at.x + at.y) % 4 == 0:
			streets.append(at)
	streets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a - (plan["centre"] as Vector2i)).length_squared()
		var db := (b - (plan["centre"] as Vector2i)).length_squared()
		return da < db if da != db else (a.x < b.x if a.x != b.x else a.y < b.y))
	var tried := 0
	for street: Vector2i in streets:
		for turns in 4:
			design["turns"] = turns
			var outward: Vector2i = ContentRegistry.FACINGS[SettlementArchitecture.facing(design)]
			var door := street - outward * 2
			var origin := door - SettlementArchitecture.local_cell(design, design["door"])
			var rect := SettlementArchitecture.local_rect(design, Rect2i(Vector2i.ZERO, design["size"]))
			rect.position += origin
			var plot := rect
			var yard: Rect2i = design["yard"]
			if yard.has_area():
				yard = SettlementArchitecture.local_rect(design, yard)
				yard.position += origin
				plot = plot.merge(yard)
			if (plan["plots"] as Array).any(func(p: Rect2i) -> bool: return p.grow(2).intersects(plot)):
				continue
			if not _planned_clear(plan, plot):
				continue
			tried += 1
			if tried > SITE_TRIES:
				return {}
			var cells := SettlementArchitecture.cells(design, origin, id, materials, world.content)
			for n in range(1, 3):
				cells[door + outward * n] = {"ground": plan["road"], "cover": "", "structure": "", "props": {"village": id}}
			var upper := SettlementArchitecture.upper_cells(design, origin, id, materials, world.content)
			if not _site_clear(cells):
				continue
			var building := id + "|" + String(design["id"])
			for at: Vector2i in cells:
				cells[at]["props"]["construction"] = building
			var bed := Settlements.NONE
			for furniture: Dictionary in design["furniture"]:
				if world.content.get_def(String(furniture["id"])).get("bed", false):
					bed = SettlementArchitecture.local_cell(design, furniture["cell"]) + origin
			return {"building": building, "stage": 0, "rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
				"door": [door.x, door.y], "bed": [bed.x, bed.y], "turns": turns, "dweller": template["dweller"],
				"name": template["name"], "cells": _rows(cells), "upper": _rows(upper), "cost": _cost(cells, upper)}
	return {}


func _planned_clear(plan: Dictionary, plot: Rect2i) -> bool:
	for key: String in ["square", "parking_yard", "parking_reserve"]:
		if (plan[key] as Rect2i).grow(2).intersects(plot):
			return false
	var heights: Array[float] = []
	for at: Vector2i in [plot.position, Vector2i(plot.end.x - 1, plot.position.y), plot.end - Vector2i.ONE, Vector2i(plot.position.x, plot.end.y - 1)]:
		if String(world.generator.land_at(at.x, at.y)["what"]) != "land":
			return false
		heights.append(world.generator.metres_at(at.x, at.y))
	if heights.max() - heights.min() > 1.0:
		return false
	for y in range(plot.position.y, plot.end.y):
		for x in range(plot.position.x, plot.end.x):
			var spec: Dictionary = plan["cells"].get(Vector2i(x, y), {})
			if not (spec.get("props", {}) as Dictionary).is_empty() or String(spec.get("ground", "")) == String(plan["road"]):
				return false
	return true


func _site_clear(cells: Dictionary) -> bool:
	for at: Vector2i in cells:
		if String(world.generator.land_at(at.x, at.y)["what"]) != "land":
			return false
		var c := world.chunk("surface", at.x >> 5, at.y >> 5)
		var props := c.get_props(at.x & 31, at.y & 31)
		if _owned(props) or props.has("construction") or props.has("building") or props.has("hospitality"):
			return false
		if c.get_cell("structure", at.x & 31, at.y & 31) != "" or c.get_cell("roof", at.x & 31, at.y & 31) != "" or c.get_cell("ceiling", at.x & 31, at.y & 31) != "":
			return false
		if Terrain.is_solid(c, at.x & 31, at.y & 31, world.content) or world._thing_at("surface", at.x >> 5, at.y >> 5, at):
			return false
	return true


func _rows(cells: Dictionary) -> Array:
	var out := []
	for at: Vector2i in cells:
		out.append([at.x, at.y, cells[at]])
	return out


func _cost(cells: Dictionary, upper: Dictionary) -> Dictionary:
	var out := {}
	for level_cells: Dictionary in [cells, upper]:
		for at: Vector2i in level_cells:
			var spec: Dictionary = level_cells[at]
			for layer: String in ["structure", "ceiling", "roof"]:
				for item: String in world.content.structure_cost(String(spec.get(layer, ""))):
					_add_cost(out, item, int(world.content.structure_cost(String(spec[layer]))[item]))
	# Resolve each ground material once per house, keeping the first matching
	# floor definition and charging every cell separately as before.
	var floor_costs := {}
	for at: Vector2i in cells:
		var ground := String(cells[at].get("ground", ""))
		if not floor_costs.has(ground):
			floor_costs[ground] = {}
			for part: String in world.content.defs:
				var def := world.content.get_def(part)
				if def.get("role", "") == "floor" and def.get("ground", "") == ground:
					floor_costs[ground] = world.content.structure_cost(part)
					break
		for item: String in floor_costs[ground]:
			_add_cost(out, item, int(floor_costs[ground][item]))
	return out


## Furniture is made from the same recipe ingredients as a player uses.
func _add_cost(out: Dictionary, item: String, count: int) -> void:
	if world.content.get_def(item).has("places"):
		for recipe: String in world.content.defs:
			var def := world.content.get_def(recipe)
			if def.get("kind", "") == "recipe" and (def.get("outputs", {}) as Dictionary).has(item):
				var batches := ceili(float(count) / int(def["outputs"][item]))
				for material: String in def.get("inputs", {}):
					out[material] = int(out.get(material, 0)) + int(def["inputs"][material]) * batches
				return
	out[item] = int(out.get(item, 0)) + count


func _structure(spec: Dictionary, stage: int) -> String:
	var part := String(spec.get("structure", ""))
	return part if stage >= 2 or (stage == 1 and world.content.get_def(part).get("role", "") in ["wall", "door", "window", "fence"]) else ""


func _owned(props: Dictionary) -> bool:
	if props.has("owner"):
		return true
	for layer: String in ["ground", "cover", "structure", "ceiling", "roof"]:
		if (props.get(layer, {}) is Dictionary) and (props.get(layer, {}) as Dictionary).has("owner"):
			return true
	return false


func _advance(id: String, s: Dictionary) -> bool:
	var project: Dictionary = s["project"]
	if int(project["stage"]) == -1:
		_collect(id, project)
		if (project["remaining"] as Dictionary).is_empty():
			_begin(id, project)
		return false
	var stage := int(project["stage"]) + 1
	for row: Array in project["cells"]:
		var at := Vector2i(int(row[0]), int(row[1]))
		var c := world.chunk("surface", at.x >> 5, at.y >> 5)
		var props := c.get_props(at.x & 31, at.y & 31)
		if props.get("construction", "") != project["building"] or _owned(props):
			return false
		if c.get_cell("ground", at.x & 31, at.y & 31) != String(row[2].get("ground", "")) or c.get_cell("cover", at.x & 31, at.y & 31) != "" or c.get_cell("structure", at.x & 31, at.y & 31) != _structure(row[2], stage - 1):
			return false
		if c.get_cell("roof", at.x & 31, at.y & 31) != "" or c.get_cell("ceiling", at.x & 31, at.y & 31) != "":
			return false
		var part := _structure(row[2], stage)
		if part != "" and world.content.get_def(part).get("solid", true):
			if _occupied(at) or world._thing_at("surface", at.x >> 5, at.y >> 5, at):
				return false
	_apply(project, stage)
	project["stage"] = stage
	if stage == WORK_DAYS - 1:
		(s["homes"] as Array).append(project)
		s["project"] = {}
		world.chronicles.note(id, "В поселении %s достроили новый дом; жильё готово к заселению." % world.chronicles.village_name(id))
		return false
	return true


func _occupied(at: Vector2i) -> bool:
	var origin := at * Movement.UNIT
	for actor: String in world.present:
		var p: Dictionary = world.present[actor]
		if p["location"] == "surface" and BuildRules.stands_on(Vector2i(world.vector(origin, p["pos"])), 0, 0):
			return true
	# Body sizes are bounded to four cells (ADR-0024), so neighbouring
	# chunks cover even a large animal whose feet are outside this plot.
	for cy in range((at.y - 4) >> 5, ((at.y + 4) >> 5) + 1):
		for cx in range((at.x - 4) >> 5, ((at.x + 4) >> 5) + 1):
			for creature_id: String in world.creatures.in_chunk("surface", cx, cy):
				var c := world.creatures.get_creature(creature_id)
				var relative := Vector2i(world.vector(origin, c.pos))
				if BodySize.cells(relative, BodySize.of(world.content.get_def(c.kind))["half"]).has(Vector2i.ZERO):
					return true
	return false


func _apply(project: Dictionary, stage: int) -> void:
	var upper := ""
	if stage == 2 and not (project["upper"] as Array).is_empty():
		upper = world.levels.create_level(String(project["building"]), 1)
	for row: Array in project["cells"]:
		var at := Vector2i(int(row[0]), int(row[1]))
		var c := world.chunk("surface", at.x >> 5, at.y >> 5)
		var spec: Dictionary = row[2]
		c.set_cell("ground", at.x & 31, at.y & 31, String(spec.get("ground", "")))
		c.set_cell("cover", at.x & 31, at.y & 31, "")
		c.set_cell("structure", at.x & 31, at.y & 31, _structure(spec, stage))
		var props: Dictionary = spec["props"].duplicate(true) if stage == 0 else c.get_props(at.x & 31, at.y & 31).duplicate(true)
		props.merge(spec["props"], false)
		if stage < 2:
			props.erase("roof")
			props.erase("ceiling")
		else:
			for layer: String in ["roof", "ceiling"]:
				c.set_cell(layer, at.x & 31, at.y & 31, String(spec.get(layer, "")))
		c.set_props(at.x & 31, at.y & 31, props)
		var buildings: Array = c.meta.get("settlement_buildings", [])
		if not buildings.has(project["building"]):
			buildings.append(project["building"])
		c.meta["settlement_buildings"] = buildings
		world._changed(ServerWorld.chunk_key("surface", at.x >> 5, at.y >> 5))
	if upper != "":
		for row: Array in project["upper"]:
			var at := Vector2i(int(row[0]), int(row[1]))
			var c := world.chunk(upper, at.x >> 5, at.y >> 5)
			c.meta["building_z"] = 1
			for layer: String in ["ground", "cover", "structure", "ceiling", "roof"]:
				c.set_cell(layer, at.x & 31, at.y & 31, String((row[2] as Dictionary).get(layer, "")))
			c.set_props(at.x & 31, at.y & 31, (row[2]["props"] as Dictionary).duplicate(true))
			world._changed(ServerWorld.chunk_key(upper, at.x >> 5, at.y >> 5))


func arrived(location: String, cx: int, cy: int, c: Chunk) -> void:
	if location != "surface":
		return
	for building: String in c.meta.get("settlement_buildings", []):
		var upper := world.levels.level(building, 1)
		if upper != "":
			world.chunk(upper, cx, cy)
