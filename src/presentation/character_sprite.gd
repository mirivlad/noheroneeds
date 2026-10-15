class_name CharacterSprite
extends Node2D
## A character drawn as a paper doll (ADR-0001): the body and then a layer
## per worn thing and chosen style (hair, shirt, boots), all sheets on the
## same grid of frames. Rows are directions (s, se, e, ne, n; the west side
## is mirrored), columns are frames of the animations the body's visual
## lists. The order of the layers depends on the direction.
## Placed at the feet, so it sorts with trees and walls by where it stands.

const DIRS := ["s", "se", "e", "ne", "n"]
## Walking speed on screen (Movement.WALK units a tick), for the walk's pace.
const WALK_PX_PER_SEC := float(Movement.WALK) / Movement.UNIT * 16.0 * Movement.TICK_RATE
## Old sheets without "animations": idle, step, step.
const PLAIN := {"idle": {"from": 0, "frames": 1, "fps": 1}, "walk": {"from": 1, "frames": 2, "fps": 6.67}}

## A foot came down (a walk frame where it touches the ground).
signal stepped

## What it was built from, so a change of looks rebuilds it.
var look := {}
var _visual: Dictionary
## [slot, Sprite2D], the body first.
var _layers: Array = []
var _shown := Vector2.ZERO
var _dir := 0
var _mirror := false
var _walk := 0.0
var _idle := 0.0
var _placed := false
var _last_walk_frame := -1
var _order_dir := -1
## What it holds (ADR-0021), drawn at the hand; null: nothing.
var _held: Sprite2D = null
## Where the hand is, by direction (s, se, e, ne, n), from the feet; and
## whether the thing is behind the body (seen from behind).
const HAND := [Vector2(6, -12), Vector2(6, -12), Vector2(4, -12), Vector2(3, -13), Vector2(-5, -13)]
const HAND_BEHIND := [false, false, false, true, true]


## layers: [[slot, Texture2D], ...] drawn over the body.
func _init(body: Texture2D, visual: Dictionary, layers: Array = [], looks: Dictionary = {}) -> void:
	_visual = visual
	look = looks
	_add_layer("body", body)
	for l: Array in layers:
		_add_layer(String(l[0]), l[1])
	_order()
	_frame(_anim("idle"), 0)


func _add_layer(slot: String, tex: Texture2D) -> void:
	var s := Sprite2D.new()
	s.texture = tex
	s.region_enabled = true
	s.centered = false
	add_child(s)
	_layers.append([slot, s])


## exact: the own, already interpolated position; others are eased toward the target.
func show_at(target: Vector2, delta: float, exact: bool) -> void:
	if not _placed:
		_shown = target
		_placed = true
	var before := _shown
	_shown = target if exact else _shown.lerp(target, minf(1.0, delta * 12.0))
	var step := _shown - before
	if step.length() > 0.05:
		_face(step)
		# The walk plays as fast as the feet go: running steps come quicker.
		var pace := clampf(step.length() / maxf(delta, 0.001) / WALK_PX_PER_SEC, 0.6, 1.8) if delta > 0.0 else 1.0
		_walk += delta * pace
		_idle = 0.0
	else:
		_walk = 0.0
		_idle += delta
	position = _shown.round()
	var a := _anim("walk" if _walk > 0.0 else "idle")
	var t := _walk if _walk > 0.0 else _idle
	var f := int(t * float(a["fps"])) % int(a["frames"])
	if _walk > 0.0 and f != _last_walk_frame and (f == 0 or f * 2 == int(a["frames"])):
		stepped.emit()  # the two contact frames of a walk cycle
	_last_walk_frame = f if _walk > 0.0 else -1
	_frame(a, f)


## Turns to look along v without walking (menus, previews).
func turn_to(v: Vector2) -> void:
	_face(v)
	_frame(_anim("idle"), 0)


func _anim(name: String) -> Dictionary:
	return _visual.get("animations", PLAIN).get(name, PLAIN[name])


func _face(v: Vector2) -> void:
	var a := fposmod(atan2(v.y, v.x), TAU)  # 0 = east, PI/2 = south
	var octant := int(round(a / (PI / 4))) % 8  # 0 e, 1 se, 2 s, 3 sw, 4 w, 5 nw, 6 n, 7 ne
	var table := [[2, false], [1, false], [0, false], [1, true], [2, true], [3, true], [4, false], [3, false]]
	_dir = table[octant][0]
	_mirror = table[octant][1]
	_order()
	_place_held()


## Layers in the order the body plan's visual gives for this direction;
## slots it does not name keep their place after the named ones.
func _order() -> void:
	if _dir == _order_dir:
		return
	_order_dir = _dir
	var order: Array = _visual.get("layer_order", {}).get(DIRS[_dir], [])
	var sorted := _layers.duplicate()
	sorted.sort_custom(func(a: Array, b: Array) -> bool:
		var ia := order.find(a[0])
		var ib := order.find(b[0])
		ia = order.size() if ia < 0 else ia
		ib = order.size() if ib < 0 else ib
		return ia < ib)
	for i in sorted.size():
		move_child(sorted[i][1], i)


## Something in the hand (its picture), or null for empty hands.
func hold(picture: Texture2D) -> void:
	if picture == null:
		if _held:
			_held.queue_free()
			_held = null
		return
	if _held == null:
		_held = Sprite2D.new()
		_held.scale = Vector2(0.75, 0.75)
		add_child(_held)
	_held.texture = picture
	_place_held()


func _place_held() -> void:
	if _held == null:
		return
	var at: Vector2 = HAND[_dir]
	_held.position = Vector2(-at.x if _mirror else at.x, at.y)
	_held.flip_h = _mirror
	_held.show_behind_parent = false
	_held.z_index = -1 if HAND_BEHIND[_dir] else 1
	_held.z_as_relative = true


func _frame(anim: Dictionary, i: int) -> void:
	var w: int = _visual["rect"][2]
	var h: int = _visual["rect"][3]
	var col := int(anim["from"]) + i
	for l: Array in _layers:
		var s: Sprite2D = l[1]
		s.region_rect = Rect2(_visual["rect"][0] + col * w, _visual["rect"][1] + _dir * h, w, h)
		s.flip_h = _mirror
		s.offset = -Vector2(w - _visual["origin"][0] if _mirror else _visual["origin"][0], _visual["origin"][1])
