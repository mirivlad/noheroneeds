class_name Boats
extends RefCounted
## Boats (ADR-0052): a boat is a thing of its own (ADR-0048) with a "vessel"
## in its definition. Out of the bag it lies on the water as any thing on the
## ground does — seen by all, kept with the world, picked up again from the
## shore. One gets in: the first is at the helm and rows it over water
## (shallows too), faster than swimming and without tiring; the others sit
## and are carried. Out of it one steps onto dry land next to it. It wears by
## the way it goes and is mended at a workbench like any thing.
##
## Who is aboard is not kept: a crew is of this run of the server (one who
## leaves the game steps out; the boat stays where it is).

## How near (movement units) a boat must be to get in.
const REACH := 2 * Movement.UNIT
## Cells rowed for one use of a boat's durability.
const CELLS_A_USE := 32
## Farther than this (cells) from one's boat, one is no longer in it (moved
## off it some other way: died, was carried off).
const LOST := 3

var world: ServerWorld
## Boat (item entity id) -> its crew, the one at the helm first.
var crews := {}
## Character id -> the boat it is in.
var _aboard := {}
## Boat -> movement units rowed since its last use counted.
var _rowed := {}


func _init(w: ServerWorld) -> void:
	world = w


## The boat a character is in ("" — none).
func aboard(id: String) -> String:
	return String(_aboard.get(id, ""))


func at_helm(id: String) -> bool:
	var b := aboard(id)
	return b != "" and (crews[b] as Array)[0] == id


## What a thing is as a vessel (its "vessel": seats, speed), {} — none.
func vessel(item: String) -> Dictionary:
	return world.content.get_def(item).get("vessel", {})


## Movement units a tick the boat one is in goes.
func speed_of(actor: String) -> int:
	var it: Dictionary = world.items.get(aboard(actor), {})
	return int(vessel(String(it.get("item", ""))).get("speed", Movement.WALK)) if not it.is_empty() else Movement.WALK


## Whether a cell keeps a boat out: all but water and shallows, and what
## stands on the water (a wall, a bridge's pier).
func blocks_boat(location: String, x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return not Terrain.floats(world.chunk(location, cx, cy), x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, world.content)


## The boat out of the bag onto the water next to one: {item, copy}, and
## the cell (x, y) one points at, if any.
func launch(actor: String, r: Dictionary) -> Dictionary:
	var item := ServerWorld.rs(r, "item")
	if vessel(item).is_empty():
		return {"ok": false, "reason": "bad_request"}
	if aboard(actor) != "":
		return {"ok": false, "reason": "aboard"}
	var inv := world.inventory(actor)
	var copy := ServerWorld.ri(r, "copy", 0)
	if inv.count(item) <= 0:
		return {"ok": false, "reason": "not_enough"}
	if Wear.broken(world.content, item, inv.state_of(item, copy)):
		return {"ok": false, "reason": "broken"}
	var p: Dictionary = world.present[actor]
	var loc := String(p["location"])
	var me := Movement.cell_of(p["pos"])
	var toward := Vector2i(ServerWorld.ri(r, "x", me.x), ServerWorld.ri(r, "y", me.y))
	var best := Vector2i(1 << 30, 0)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := me + Vector2i(dx, dy)
			if not blocks_boat(loc, c.x, c.y) and (best.x == 1 << 30 or Vector2(c - toward).length() < Vector2(best - toward).length()):
				best = c
	if best.x == 1 << 30:
		return {"ok": false, "reason": "no_water"}
	var gone := inv.take(item, 1, copy)
	var at := best * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
	var id := world.place_item(loc, at, item, 1, "", 0, gone)
	world.touch_inventory(actor)
	return {"ok": true, "entity": id}


## Getting into a boat lying on the water near one.
func board(actor: String, r: Dictionary) -> Dictionary:
	var id := ServerWorld.rs(r, "entity")
	var it: Dictionary = world.items.get(id, {})
	if it.is_empty() or vessel(String(it["item"])).is_empty():
		return {"ok": false, "reason": "gone"}
	if aboard(actor) != "":
		return {"ok": false, "reason": "aboard"}
	var p: Dictionary = world.present[actor]
	var at := Vector2i(int(it["x"]), int(it["y"]))
	if p["location"] != it["location"] or world.distance(p["pos"], at) > REACH:
		return {"ok": false, "reason": "too_far"}
	var cell := Movement.cell_of(at)
	if blocks_boat(String(it["location"]), cell.x, cell.y):
		return {"ok": false, "reason": "aground"}
	var state: Dictionary = (it.get("states", []) as Array)[0] if not (it.get("states", []) as Array).is_empty() else {}
	if Wear.broken(world.content, String(it["item"]), state):
		return {"ok": false, "reason": "broken"}
	var crew: Array = crews.get(id, [])
	if crew.size() >= int(vessel(String(it["item"])).get("seats", 1)):
		return {"ok": false, "reason": "no_seat"}
	crew.append(actor)
	crews[id] = crew
	_aboard[actor] = id
	world.move_character(actor, at)
	world.wake(actor)
	return {"ok": true, "helm": crew.size() == 1}


## Out of the boat onto dry land next to it (the cell pointed at, if it is
## one), or into the water if one must.
func land(actor: String, r: Dictionary) -> Dictionary:
	var b := aboard(actor)
	if b == "":
		return {"ok": false, "reason": "not_aboard"}
	var p: Dictionary = world.present[actor]
	var loc := String(p["location"])
	var me := Movement.cell_of(p["pos"])
	var toward := Vector2i(ServerWorld.ri(r, "x", me.x), ServerWorld.ri(r, "y", me.y))
	var best := Vector2i(1 << 30, 0)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := me + Vector2i(dx, dy)
			if world.blocks_walker(loc, c.x, c.y) or not blocks_boat(loc, c.x, c.y):
				continue  # neither solid nor water: dry ground one stands on
			if best.x == 1 << 30 or Vector2(c - toward).length() < Vector2(best - toward).length():
				best = c
	if best.x == 1 << 30:
		return {"ok": false, "reason": "no_shore"}
	leave(actor)
	world.move_character(actor, best * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2))
	return {"ok": true}


## Out of one's boat, wherever one is (left the game, died, landed).
func leave(actor: String) -> void:
	var b := aboard(actor)
	if b == "":
		return
	_aboard.erase(actor)
	var crew: Array = crews.get(b, [])
	crew.erase(actor)
	if crew.is_empty():
		crews.erase(b)
		_rowed.erase(b)


## The one at the helm rows to `pos`: the boat and all in it go there; the
## boat wears by the way.
func row(actor: String, pos: Vector2i) -> void:
	if not at_helm(actor):
		return
	var b := aboard(actor)
	var it: Dictionary = world.items.get(b, {})
	if it.is_empty():
		leave(actor)
		return
	var from := Vector2i(int(it["x"]), int(it["y"]))
	if pos == from:
		return
	world.move_item(b, pos)
	for id: String in crews[b]:
		world.move_character(id, pos)
	_rowed[b] = int(_rowed.get(b, 0)) + int(Vector2(pos - from).length())
	if int(_rowed[b]) >= CELLS_A_USE * Movement.UNIT:
		_rowed[b] = int(_rowed[b]) - CELLS_A_USE * Movement.UNIT
		var states: Array = it.get("states", [{}])
		states = states.duplicate() if not states.is_empty() else [{}]
		states[0] = Wear.used(states[0])
		it["states"] = states
		world.note_item_changed(b)
		if Wear.broken(world.content, String(it["item"]), states[0]):
			for id: String in (crews[b] as Array).duplicate():
				leave(id)  # it leaks and stops: all are in the water


## Each tick: who is no longer by its boat (moved off some other way) is out.
func check() -> void:
	for id: String in _aboard.keys():
		var b := aboard(id)
		var it: Dictionary = world.items.get(b, {})
		if not world.present.has(id) or it.is_empty() or world.present[id]["location"] != it["location"] \
				or world.distance(world.present[id]["pos"], Vector2i(int(it["x"]), int(it["y"]))) > LOST * Movement.UNIT:
			leave(id)
