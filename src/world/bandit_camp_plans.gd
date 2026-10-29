class_name BanditCampPlans
extends RefCounted
## One forest camp for a village cluster. Kept separate from villages so
## bandits do not acquire a village treasury, roads or peaceful dwellers.

const FORESTS := ["base:forest", "base:grove", "base:taiga"]
const HALF := 9
var _settlements: WeakRef
var settlements: Settlements:
	get: return _settlements.get_ref()
var _plans := {}


func _init(s: Settlements) -> void:
	_settlements = weakref(s)


func of_cluster(k: int, dx: int, dy: int) -> Dictionary:
	var key := "%d,%d,%d" % [k, dx, dy]
	if not _plans.has(key):
		_plans[key] = _make(k, dx, dy)
	return _plans[key]


func by_id(id: String) -> Dictionary:
	var parts := id.trim_prefix("bandits@").split(",")
	if not id.begins_with("bandits@") or parts.size() != 3:
		return {}
	for part: String in parts:
		if not part.is_valid_int():
			return {}
	var k := int(parts[0])
	return of_cluster(k, int(parts[1]), int(parts[2])) if k >= 0 and k < settlements._kinds.size() else {}


func plans_touching(cx: int, cy: int) -> Array:
	var out := []
	var chunk := Rect2i(cx * Chunk.SIZE, cy * Chunk.SIZE, Chunk.SIZE, Chunk.SIZE)
	for k in settlements._kinds.size():
		var district := settlements._district_of(k, chunk.position)
		# Camps stay wholly inside their district, unlike village roads.
		var p := of_cluster(k, district.x, district.y)
		if not p.is_empty() and (p["bounds"] as Rect2i).intersects(chunk):
			out.append(p)
	return out


func _make(k: int, dx: int, dy: int) -> Dictionary:
	var s := settlements
	var villages := s.villages(k, dx, dy)
	if villages.size() < 2 or not s._biome.is_valid():
		return {}
	var roads := s.roads_of(k, dx, dy)
	if roads.is_empty():
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([s.world_seed, k, dx, dy, "bandit camp"])
	var district := s._district_rect(k, dx, dy).grow(-HALF - 2)
	var best := Settlements.NONE
	var score := -INF
	var raid_road := []
	var raid_at := Vector2i.ZERO
	var water := Settlements.NONE
	for attempt in 64:
		var road: Dictionary = roads[rng.randi() % roads.size()]
		var path: Array = road["path"]
		if path.size() < 24:
			continue
		var i := rng.randi_range(10, path.size() - 11)
		var at: Vector2i = path[i] + Vector2i(Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(28, 65))
		if not district.has_point(at) or not FORESTS.has(String(s._biome.call(at.x, at.y))):
			continue
		var bounds := Rect2i(at - Vector2i(HALF, HALF), Vector2i(HALF * 2 + 1, HALF * 2 + 1))
		if villages.any(func(v: Dictionary) -> bool: return bounds.grow(24).intersects(v["bounds"])):
			continue
		var dry := true
		var low := INF
		var high := -INF
		for y in range(-HALF, HALF + 1, 3):
			for x in range(-HALF, HALF + 1, 3):
				var cell := at + Vector2i(x, y)
				if s._wet.call(cell.x, cell.y):
					dry = false
				if s._land.is_valid():
					var land: Dictionary = s._land.call(cell.x, cell.y)
					low = minf(low, float(land["height"]))
					high = maxf(high, float(land["height"]))
		if not dry or high - low > .06:
			continue
		# A camp must not erase any of the cluster's existing roads.
		if roads.any(func(r: Dictionary) -> bool: return (r["path"] as Array).any(func(c: Vector2i) -> bool: return bounds.grow(2).has_point(c))):
			continue
		var fishing := _fishing_spot(at)
		var value := (20.0 if fishing != Settlements.NONE else 0.0) - at.distance_to(path[i]) * .1
		if value > score:
			best = at
			score = value
			raid_road = road["key"].duplicate()
			raid_at = path[i]
			water = fishing
	if best == Settlements.NONE:
		return {}
	return _layout("bandits@" + "%d,%d,%d" % [k, dx, dy], best, raid_road, raid_at, water, rng)


func _fishing_spot(at: Vector2i) -> Vector2i:
	for radius in [12, 24, 40, 60]:
		for i in 16:
			var cell := at + Vector2i(Vector2.from_angle(i * TAU / 16) * radius)
			if settlements._wet.call(cell.x, cell.y):
				for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
					if not settlements._wet.call(cell.x + d.x, cell.y + d.y):
						return cell + d
	return Settlements.NONE


func _layout(id: String, centre: Vector2i, road: Array, raid_at: Vector2i, water: Vector2i, rng: RandomNumberGenerator) -> Dictionary:
	var cells := {}
	var bounds := Rect2i(centre - Vector2i(HALF, HALF), Vector2i(HALF * 2 + 1, HALF * 2 + 1))
	for y in range(-7, 8):
		for x in range(-7, 8):
			if Vector2(x, y).length() <= 8:
				cells[centre + Vector2i(x, y)] = {"cover": "", "structure": ""}
	var shelters := [centre + Vector2i(-5, -4), centre + Vector2i(4, -5), centre + Vector2i(-5, 4)]
	if rng.randf() < .5:
		shelters.append(centre + Vector2i(4, 4))
	for at: Vector2i in shelters:
		cells[at] = {"structure": "base:bandit_shelter", "cover": "", "props": {"camp": id, "facing": "s"}}
	var chest := centre + Vector2i(2, -1)
	cells[chest] = {"structure": "base:chest", "cover": "", "props": {"camp": id, "store": "camp|" + id}}
	cells[centre] = {"structure": "base:campfire", "cover": "", "props": {"camp": id}}
	return {"id": id, "centre": centre, "bounds": bounds, "cells": cells, "shelters": shelters,
		"chest": chest, "water": water, "road": road, "raid_at": raid_at, "population": rng.randi_range(6, 10)}
