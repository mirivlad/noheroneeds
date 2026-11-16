class_name BridgeRoutes
extends RefCounted
## A bridge earns its place by joining explorable dry ground, with a trail
## continuing beyond each end, and no short walk round it. Only the raw land
## sampler is called: never settlements or another bridge's route planner.
const REACH := 18
const MIN_REGION := 40
const MIN_TRAIL := 8
const MAX_TRAIL := 24
const MAX_SPAN := 8
const MAX_REGION := 768
const STEPS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const DIAGONALS := [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1)]

static func plan(low: Vector2i, high: Vector2i, axis: Vector2i, land: Callable) -> Dictionary:
	if axis not in STEPS: return {"accepted": false, "reason": "axis"}
	var near := low - axis
	var far := high + axis
	var field := {}
	if not _dry(near, land, field) or not _dry(far, land, field):
		return {"accepted": false, "reason": "landing"}
	var span := maxi(absi(high.x - low.x), absi(high.y - low.y)) + 1
	if span < 2 or span > MAX_SPAN: return {"accepted": false, "reason": "span"}
	var detour := _detour(near, far, span * 2 + 10, land, field)
	if detour >= 0: return {"accepted": false, "reason": "nearby-land", "detour_steps": detour}
	var a := _region(near, -axis, low, land, field)
	var b := _region(far, axis, high, land, field)
	if a["count"] < MIN_REGION or b["count"] < MIN_REGION or a["path"].size() < MIN_TRAIL or b["path"].size() < MIN_TRAIL:
		return {"accepted": false, "reason": "no-connected-region", "regions": [a["count"], b["count"]]}
	return {"accepted": true, "paths": [a["path"], b["path"]], "regions": [a["count"], b["count"]], "detour_steps": -1}

static func _kind(at: Vector2i, land: Callable, field: Dictionary) -> String:
	if not field.has(at): field[at] = String((land.call(at.x, at.y) as Dictionary).get("what", "rock"))
	return field[at]

static func _dry(at: Vector2i, land: Callable, field: Dictionary) -> bool:
	return _kind(at, land, field) == "land"

## Roads already join useful places, but should still prefer a nearby walk
## round a ravine's tip to a short artificial hanging deck.
static func land_detour(from: Vector2i, to: Vector2i, limit: int, land: Callable) -> int:
	return _detour(from, to, mini(limit, MAX_SPAN * 2 + 10), land, {})

static func _detour(from: Vector2i, to: Vector2i, limit: int, land: Callable, field: Dictionary) -> int:
	var distance := {from: 0}
	var queue: Array[Vector2i] = [from]
	var cursor := 0
	while cursor < queue.size():
		var at := queue[cursor]
		cursor += 1
		var steps: int = distance[at]
		if at == to: return steps
		if steps >= limit: continue
		for d: Vector2i in STEPS:
			var next := at + d
			if not distance.has(next) and _kind(next, land, field) in ["land", "shore", "shallows"]:
				distance[next] = steps + 1
				queue.append(next)
	return -1

static func _region(start: Vector2i, outward: Vector2i, bridge: Vector2i, land: Callable, field: Dictionary) -> Dictionary:
	var box := Rect2i(start - Vector2i.ONE * REACH, Vector2i.ONE * (REACH * 2 + 1))
	var side := Vector2i(outward.y, -outward.x)
	var bend := 1 if posmod(hash([bridge.x, bridge.y, 1709]), 2) == 0 else -1
	var goal := start + outward * 10 + side * bend * 4
	var parents := {start: start}
	var depth := {start: 0}
	var queue: Array[Vector2i] = [start]
	var cursor := 0
	var best := start
	var score := INF
	var directions: Array = [outward, side, -side, -outward] + DIAGONALS
	while cursor < queue.size() and queue.size() < MAX_REGION:
		var at := queue[cursor]
		cursor += 1
		if depth[at] <= MAX_TRAIL and Vector2(at - start).dot(Vector2(outward)) >= 6:
			var value := Vector2(at - goal).length_squared()
			if value < score:
				score = value
				best = at
			if is_zero_approx(score) and queue.size() >= MIN_REGION: break
		for d: Vector2i in directions:
			if parents.size() >= MAX_REGION: break
			var next := at + d
			if parents.has(next) or not box.has_point(next) or not _dry(next, land, field): continue
			# A diagonal never slips between two blocked orthogonal cells.
			if d.x != 0 and d.y != 0 and (not _dry(at + Vector2i(d.x, 0), land, field) or not _dry(at + Vector2i(0, d.y), land, field)): continue
			parents[next] = at
			depth[next] = int(depth[at]) + 1
			queue.append(next)
	var path: Array[Vector2i] = []
	if best != start:
		var at := best
		while at != start:
			path.push_front(at)
			at = parents[at]
		path.push_front(start)
	return {"count": parents.size(), "path": path}
