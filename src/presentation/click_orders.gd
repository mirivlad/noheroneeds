class_name ClickOrders
extends RefCounted
## Playing by the mouse, as in Ragnarok Online (the author, 28.10.2026): the
## left button walks to the ground clicked, round what is in the way; on a
## being or a thing it walks up to it and does there what the left button
## does — strikes again and again till it falls (RO with /noctrl), works a
## tree or a rock till it is done, talks, opens, picks up. Another click, a
## walking key, or the target gone ends the order. The client only steers
## (the move it sends each tick); the server moves and judges as ever.

## Cells the way is searched over at most, and how far from a cell's middle
## one counts as there (simulation units).
const SEARCH_LIMIT := 3000
const NEAR := Movement.UNIT * 3 / 10
## How often a way to a moving target is found again (seconds).
const RETHINK_S := 0.4

## The cells still to walk through, the first next.
var path: Array[Vector2i] = []
## What is done at the end ({} — only walking there); its target, how near
## (cells, from one's middle to the target's) it is done from, and whether
## again and again.
var action := {}
var target := {}
var reach := 1.5
var repeat := false
var _goal := Vector2i.ZERO
var _rethink := 0.0
var _active := false


func active() -> bool:
	return _active


func acting() -> bool:
	return _active and not action.is_empty()


func clear() -> void:
	_active = false
	path.clear()
	action = {}
	target = {}


## Walk to a cell (the nearest open one there if it is shut).
func walk_to(cell: Vector2i, from: Vector2i, solid: Callable) -> void:
	clear()
	_goal = cell
	path = find(from, func(c: Vector2i) -> bool: return c == cell or (solid.call(cell.x, cell.y) and Vector2(c - cell).length() < 1.5),
		cell, solid)
	_active = not path.is_empty() or from == cell


## Walk up to a target and do `act` there (again and again when `again`).
func act_on(t: Dictionary, act: Dictionary, near: float, again: bool, from: Vector2i, solid: Callable, at: Vector2) -> void:
	clear()
	target = t
	action = act
	reach = near
	repeat = again
	_active = true
	_route(from, solid, at)


## The target's point now (simulation units).
func _route(from: Vector2i, solid: Callable, at: Vector2) -> void:
	var aim := Vector2i((at / Movement.UNIT).floor())
	var near := reach
	path = find(from, func(c: Vector2i) -> bool:
		return (Vector2(c) + Vector2(0.5, 0.5)).distance_to(at / Movement.UNIT) <= near and not solid.call(c.x, c.y), aim, solid)
	_rethink = RETHINK_S


## The move for this tick toward the next cell of the way (world axes, each
## -1..1); zero when there or when there is no way. `at`: the target's point
## (units) when acting on one that may move.
func step(position: Vector2i, solid: Callable, delta: float, at := Vector2.INF) -> Vector2i:
	if not _active:
		return Vector2i.ZERO
	if acting() and at != Vector2.INF:
		_rethink -= delta
		if _rethink <= 0.0:
			_route(Movement.cell_of(position), solid, at)
		if in_reach(position, at):
			return Vector2i.ZERO
	while not path.is_empty():
		var middle := path[0] * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
		var off := middle - position
		if absi(off.x) <= NEAR and absi(off.y) <= NEAR:
			path.remove_at(0)
			continue
		return Vector2i(_sign(off.x), _sign(off.y))
	if not acting():
		_active = false  # walked there
	elif at != Vector2.INF:  # the way done, the target a step on: straight to it
		var off := Vector2i(at) - position
		return Vector2i(_sign(off.x), _sign(off.y))
	return Vector2i.ZERO


## Whether the target is near enough to do the action from here.
func in_reach(position: Vector2i, at: Vector2) -> bool:
	return Vector2(position).distance_to(at) <= reach * Movement.UNIT


static func _sign(v: int) -> int:
	return 0 if absi(v) <= NEAR / 2 else signi(v)


## A way from `from` to the first cell where `done(cell)`: the cells to walk
## through (without `from`), or [] when there is none within SEARCH_LIMIT
## cells. Eight ways, no corner cut past a shut cell (A*, toward `aim`).
static func find(from: Vector2i, done: Callable, aim: Vector2i, solid: Callable) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if done.call(from):
		return out
	var came := {from: from}
	var cost := {from: 0.0}
	var heap: Array = [[_guess(from, aim), from]]
	var seen := 0
	while not heap.is_empty() and seen < SEARCH_LIMIT:
		var c: Vector2i = _pop(heap)[1]
		seen += 1
		if done.call(c):
			while c != from:
				out.push_front(c)
				c = came[c]
			return out
		for d: Vector2i in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP, Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
			var n := c + d
			if solid.call(n.x, n.y):
				continue
			if d.x != 0 and d.y != 0 and (solid.call(c.x + d.x, c.y) or solid.call(c.x, c.y + d.y)):
				continue  # no corner cut
			var g := float(cost[c]) + (1.414 if d.x != 0 and d.y != 0 else 1.0)
			if not cost.has(n) or g < float(cost[n]):
				cost[n] = g
				came[n] = c
				_push(heap, [g + _guess(n, aim), n])
	return out


static func _guess(c: Vector2i, aim: Vector2i) -> float:
	var d := (c - aim).abs()
	return maxf(d.x, d.y) + 0.414 * minf(d.x, d.y)


static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var up := (i - 1) / 2
		if float(heap[up][0]) <= float(item[0]):
			break
		heap[i] = heap[up]
		i = up
	heap[i] = item


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	var i := 0
	var n := heap.size()
	while true:
		var l := i * 2 + 1
		if l >= n:
			break
		var r := l + 1
		var m := r if r < n and float(heap[r][0]) < float(heap[l][0]) else l
		if float(heap[m][0]) >= float(last[0]):
			break
		heap[i] = heap[m]
		i = m
	heap[i] = last
	return top
