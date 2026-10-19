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
var _running := false
var _placed := false
var _last_walk_frame := -1
var _order_dir := -1
var _column := 0
var _hand_bob := 0
## What it holds (ADR-0021), drawn at the hand; null: nothing.
var _held: Sprite2D = null
var _grip := GRIP
## Where the hand is, by direction (s, se, e, ne, n), from the feet; and
## whether the thing is behind the body (seen from behind).
const HAND := [Vector2(6, -12), Vector2(6, -12), Vector2(4, -12), Vector2(3, -13), Vector2(-5, -13)]
const HAND_BEHIND := [false, false, false, true, true]
## A blow (ADR-0019, ADR-0021), drawn by moving what is held and the whole
## body, with no frames of its own on the sheets: the body leans back and
## rises as the blow is raised, then leans into it, crouching, its feet in a
## stride (a walk frame), and comes back. "chop" (an axe, a pick, a club:
## raised and brought down), "thrust" (a spear: pushed out, no wind-up),
## "draw" (a bow: pulled back and let go), "lunge" (empty hands, beasts).
const SWING_S := 0.3
## Fallback grip from the picture's centre for old item visuals.
const GRIP := Vector2(0, 5)
var _swing_t := -1.0
var _swing_kind := ""
var _swing_dir := Vector2.RIGHT


## layers: [[slot, Texture2D], ...] drawn over the body.
func _init(body: Texture2D, visual: Dictionary, layers: Array = [], looks: Dictionary = {}) -> void:
	_visual = visual
	look = looks
	_add_layer("body", body, visual)
	for l: Array in layers:
		_add_layer(String(l[0]), l[1], l[2] if l.size() > 2 else {})
	_order()
	_frame(_anim("idle"), 0)


## sheet: where an LPC layer's frames are (LpcSprite); unused here.
func _add_layer(slot: String, tex: Texture2D, sheet := {}) -> void:
	var s := Sprite2D.new()
	s.texture = tex
	s.region_enabled = true
	s.centered = false
	s.scale = Vector2.ONE * float(_visual.get("pixel_scale", 1.0))
	add_child(s)
	_layers.append([slot, s, sheet])


## Changing clothes never replaces the moving/attacking character node.
func dress(body: Texture2D, visual: Dictionary, layers: Array, looks: Dictionary) -> void:
	for layer: Array in _layers:
		remove_child(layer[1])
		layer[1].queue_free()
	_layers.clear()
	_visual = visual
	look = looks.duplicate(true)
	_add_layer("body", body, visual)
	for layer: Array in layers:
		_add_layer(String(layer[0]), layer[1], layer[2] if layer.size() > 2 else {})
	_order_dir = -1
	_order()
	var bob := _hand_bob
	_frame({"from": _column}, 0)
	_hand_bob = bob
	if not swinging():
		_place_held()


## exact: the own, already interpolated position; others are eased toward the target.
func show_at(target: Vector2, delta: float, exact: bool) -> void:
	if not _placed:
		_shown = target
		_placed = true
	var before := _shown
	_shown = target if exact else _shown.lerp(target, minf(1.0, delta * 12.0))
	var step := _shown - before
	if step.length() > 0.05:
		if _swing_t < 0.0:
			_face(step)  # a blow keeps one turned to it
		# The walk plays as fast as the feet go: running steps come quicker.
		var pace := clampf(step.length() / maxf(delta, 0.001) / WALK_PX_PER_SEC, 0.6, 1.8) if delta > 0.0 else 1.0
		_running = pace > 1.25
		_walk += delta * pace
		_idle = 0.0
	else:
		_walk = 0.0
		_idle += delta
		_running = false
	position = (_shown + _swing_step(delta)).round()
	var a := _anim(("run" if _running else "walk") if _walk > 0.0 else "idle")
	var t := _walk if _walk > 0.0 else _idle
	var f := int(t * float(a["fps"])) % int(a["frames"])
	if _swing_t >= 0.25 and _swing_t < 0.7 and _walk <= 0.0:
		a = _anim("walk")  # the stride of the blow
		f = mini(1, int(a["frames"]) - 1)
	if _walk > 0.0 and f != _last_walk_frame and (f == 0 or f * 2 == int(a["frames"])):
		stepped.emit()  # the two contact frames of a walk cycle
	_last_walk_frame = f if _walk > 0.0 else -1
	_frame(a, f)


## Strikes toward `dir` (any length) in a manner (SWING kinds above).
func swing(dir: Vector2, kind: String) -> void:
	if dir.length() > 0.01:
		_swing_dir = dir.normalized()
		_face(dir)
		_frame(_anim("idle"), 0)
	_swing_kind = kind
	_swing_t = 0.0


func swinging() -> bool:
	return _swing_t >= 0.0


## Moves the swing on: where the body leans (pixels), and the held thing.
func _swing_step(delta: float) -> Vector2:
	if _swing_t < 0.0:
		return Vector2.ZERO
	_swing_t += delta / SWING_S
	if _swing_t >= 1.0:
		_swing_t = -1.0
		_place_held()
		skew = 0.0
		scale = Vector2.ONE
		return Vector2.ZERO
	var t := _swing_t
	var lean := sin(PI * t)
	_lean_body(t)
	if _held == null:
		return _swing_dir * lean * (3.0 if _swing_kind == "lunge" or _swing_kind == "chop" else 1.0)
	_place_held()
	var rest := _held.position
	match _swing_kind:
		"chop":
			# Raised (a quarter of the time), brought down past the rest
			# (another quarter), back.
			var a := -1.9 * (t / 0.25) if t < 0.25 else (lerpf(-1.9, 0.7, (t - 0.25) / 0.25) if t < 0.5 \
				else lerpf(0.7, 0.0, (t - 0.5) / 0.5))
			a *= -1.0 if _mirror else 1.0
			var rest_angle := _held.rotation
			var grip := rest + _scaled_grip().rotated(rest_angle)
			_held.rotation = rest_angle + a
			_held.position = grip - _scaled_grip().rotated(_held.rotation)
			return _swing_dir * (2.0 * lean if t > 0.25 else 0.0)
		"thrust":
			_held.position = rest + _swing_dir * 6.0 * lean
			return _swing_dir * lean
		"draw":
			_held.position = rest - _swing_dir * 2.0 * (lean if t < 0.6 else 0.0)
			return Vector2.ZERO
	return _swing_dir * 3.0 * lean


## The body's part of a blow: how far it leans (skew, round its feet:
## toward the blow's side) and stretches or crouches (scale), by the moment
## of the blow: raised (back, up), struck (forward, down), back to rest.
const LEAN := 0.22
func _lean_body(t: float) -> void:
	var back := 0.0 if _swing_kind == "thrust" else (-0.6 if _swing_kind != "draw" else -0.4)
	var into := 0.0 if _swing_kind == "draw" else 1.0
	var k: float
	if t < 0.25:
		k = back * t / 0.25
	elif t < 0.45:
		k = lerpf(back, into, (t - 0.25) / 0.2)
	else:
		k = lerpf(into, 0.0, (t - 0.45) / 0.55)
	skew = LEAN * k * _swing_dir.x
	# Raised: a little taller; struck: lower and wider (into the blow); a
	# blow straight up or down the screen shows mostly as this.
	var up := -k if k < 0.0 else 0.0
	var down := k if k > 0.0 else 0.0
	scale = Vector2(1.0 + 0.05 * down, 1.0 + 0.06 * up - 0.08 * down)


## Turns to look along v without walking (menus, previews).
func turn_to(v: Vector2) -> void:
	_face(v)
	_frame(_anim("idle"), 0)


func _anim(name: String) -> Dictionary:
	var animations: Dictionary = _visual.get("animations", PLAIN)
	if name == "run" and not animations.has("run"):
		name = "walk"
	return animations.get(name, PLAIN.get(name, PLAIN["walk"]))


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


## Something in the hand (its picture), or null for empty hands; item: what
## it is (bodies that draw some things with frames of their own, LpcSprite).
func hold(picture: Texture2D, grip := GRIP, _item := "") -> void:
	if picture == null:
		if _held:
			_held.queue_free()
			_held = null
		return
	if _held == null:
		_held = Sprite2D.new()
		_held.scale = Vector2(0.75, 0.75)
		add_child(_held)
	elif _held.texture == picture and _grip == grip:
		return  # the same thing (asked every frame): a swing goes on undisturbed
	_grip = grip
	_held.texture = picture
	_place_held()


func _scaled_grip() -> Vector2:
	return Vector2(-_grip.x if _mirror else _grip.x, _grip.y) * _held.scale


func _place_held() -> void:
	if _held == null:
		return
	var at: Vector2 = HAND[_dir] + Vector2(0, _hand_bob)
	var angle := 0.0
	var row: Array = _visual.get("hands", {}).get(DIRS[_dir], [])
	if _column < row.size():
		var hand: Array = row[_column]
		at = Vector2(float(hand[0]) + 0.5 - _visual["origin"][0], float(hand[1]) + 0.5 - _visual["origin"][1])
		at *= float(_visual.get("pixel_scale", 1.0))
		angle = deg_to_rad(float(hand[2]))
	if _mirror:
		at.x = -at.x
		angle = -angle
	_held.rotation = angle
	# The scaled grip, rather than the picture's centre, touches the wrist.
	_held.position = at - _scaled_grip().rotated(angle)
	_held.flip_h = _mirror
	_held.show_behind_parent = false
	var behind: bool = _visual.get("hand_behind", {}).get(DIRS[_dir], HAND_BEHIND[_dir])
	_held.z_index = -1 if behind else 1
	_held.z_as_relative = true


func _frame(anim: Dictionary, i: int) -> void:
	var w: int = _visual["rect"][2]
	var h: int = _visual["rect"][3]
	var col := int(anim["from"]) + i
	_column = col
	_hand_bob = -1 if anim == _anim("walk") and (i == 1 or i == 4) else 0
	for l: Array in _layers:
		var s: Sprite2D = l[1]
		s.region_rect = Rect2(_visual["rect"][0] + col * w, _visual["rect"][1] + _dir * h, w, h)
		s.flip_h = _mirror
		s.offset = -Vector2(w - _visual["origin"][0] if _mirror else _visual["origin"][0], _visual["origin"][1])
	if not swinging():
		_place_held()
