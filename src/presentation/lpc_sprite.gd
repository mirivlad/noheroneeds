class_name LpcSprite
extends CharacterSprite
## A human from LPC layers (tools/art/import_lpc.py): every layer has its
## own frames for each animation, four directions are drawn (n, w, s, e: no
## mirroring), and swings are real animations — a chop, a thrust, a shot.
## Tools and weapons with frames of their own are layers too, before and
## behind the body; anything else in the hands is its picture at the hand.
## Colours come from palette ramps (Art.lpc_material), not from the sheets.

## Where the hand holding a picture is, from the feet, by row (n, w, s, e).
## (The right hand: nearer the viewer facing east, farther facing west.)
const HAND_AT := [Vector2(6, -7), Vector2(-4, -7), Vector2(-7, -7), Vector2(4, -7)]
const HAND_BEHIND_AT := [true, true, false, false]

## Layers of what is in the hands: [slot, Sprite2D, sheet]; and which item.
var _held_layers: Array = []
var _held_item := ""
var _anim_name := "idle"
var _index := 0


func _init(body: Texture2D, visual: Dictionary, layers: Array = [], looks: Dictionary = {}) -> void:
	super(body, visual, layers, looks)
	turn_to(Vector2.DOWN)  # facing the viewer until it moves


func _add_layer(slot: String, tex: Texture2D, sheet := {}) -> void:
	super(slot, tex, sheet)
	_layers[-1][1].material = Art.lpc_material(_visual, sheet, look.get("colors", {}))


func dress(body: Texture2D, visual: Dictionary, layers: Array, looks: Dictionary) -> void:
	var item := _held_item
	_drop_held_layers()
	super(body, visual, layers, looks)
	_hold_layers(item)


## The animation, as the base class asks for it: frames are steps of a timeline.
func _anim(anim_name: String) -> Dictionary:
	var animations: Dictionary = _visual.get("animations", {})
	if not animations.has(anim_name):
		anim_name = "walk" if animations.has("walk") else "idle"
	var a: Dictionary = animations[anim_name]
	return {"name": anim_name, "frames": (a["frames"] as Array).size(), "fps": float(a["fps"])}


func _face(v: Vector2) -> void:
	# Diagonals are seen from the side, as walking along a wall is.
	if absf(v.x) >= absf(v.y):
		_dir = 3 if v.x > 0.0 else 1
	else:
		_dir = 2 if v.y > 0.0 else 0
	_mirror = false
	_order()
	_place_held()


## Back to front by the layers' own depth; the same in every direction.
func _order() -> void:
	if _order_dir == 0:
		return
	_order_dir = 0
	var all := _layers + _held_layers
	all.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2].get("z", 0)) < int(b[2].get("z", 0)))
	for i in all.size():
		move_child(all[i][1], i)


func _frame(anim: Dictionary, i: int) -> void:
	if anim.has("name"):
		_anim_name = String(anim["name"])
		_index = i
	var anim_name := _anim_name
	var index := _index
	if swinging():
		anim_name = _swing_anim()
		index = mini(int(_swing_t * _frame_count(anim_name)), _frame_count(anim_name) - 1)
	# A thing in the hands without frames for this: the body does what it can hold it in.
	var fallback: Dictionary = _visual.get("fallback", {})
	if fallback.has(anim_name) and _held_layers.any(func(l: Array) -> bool:
			return not (l[2]["anims"] as Dictionary).has(anim_name)):
		var alt: Array = fallback[anim_name]
		anim_name = String(alt[0])
		index = index if int(alt[1]) < 0 else int(alt[1])
	var timeline: Array = _visual["animations"][anim_name]["frames"]
	var column := int(timeline[index % timeline.size()])
	for l: Array in _layers + _held_layers:
		_place_frame(l[1], l[2], anim_name, column)
	_column = column
	if not swinging():
		_place_held()


func _place_frame(s: Sprite2D, sheet: Dictionary, anim_name: String, column: int) -> void:
	var r: Array = sheet.get("anims", {}).get(anim_name, [])
	if r.is_empty() or column >= int(r[3]):
		s.visible = false
		return
	var size := int(r[2])
	s.visible = true
	s.region_rect = Rect2(r[0] + column * size, r[1] + _dir * size, size, size)
	s.flip_h = false
	# The visual's origin is the feet in its own frames; larger frames (a
	# tool's swing) are centred on them.
	s.offset = -Vector2(size / 2.0, float(_visual["origin"][1]) + (size - int(_visual["rect"][3])) / 2.0)


func _frame_count(anim_name: String) -> int:
	return (_visual["animations"][anim_name]["frames"] as Array).size()


func _swing_anim() -> String:
	var anim_name := String(_visual.get("swings", {}).get(_swing_kind, "slash"))
	return anim_name if _visual["animations"].has(anim_name) else "idle"


## A swing is its animation, played once at its own pace; the body stays put.
func _swing_step(delta: float) -> Vector2:
	if _swing_t < 0.0:
		return Vector2.ZERO
	var a: Dictionary = _visual["animations"][_swing_anim()]
	_swing_t += delta * float(a["fps"]) / float((a["frames"] as Array).size())
	if _swing_t >= 1.0:
		_swing_t = -1.0
		_place_held()
	if _held:
		_held.visible = _swing_t < 0.0
	return Vector2.ZERO


## In the hands: a tool or weapon with frames of its own (the body visual's
## held_overrides, by `item`), else its picture at the hand.
func hold(picture: Texture2D, grip := GRIP, item := "") -> void:
	if item != _held_item:
		_drop_held_layers()
		_hold_layers(item)
		_frame({}, 0)
	super(null if _held_item != "" else picture, grip, item)


func _hold_layers(item: String) -> void:
	_held_item = ""
	var held: Dictionary = _visual.get("held_overrides", {}).get(item, {})
	if held.get("sheets", []).is_empty():
		return
	_held_item = item
	for sheet: Dictionary in held["sheets"]:
		var s := Sprite2D.new()
		s.texture = Art.texture(sheet["atlas_path"])
		s.region_enabled = true
		s.centered = false
		s.scale = Vector2.ONE * float(_visual.get("pixel_scale", 1.0))
		s.material = Art.lpc_material(_visual, sheet, look.get("colors", {}))
		add_child(s)
		_held_layers.append([String(held["layer"]), s, sheet])
	_order_dir = -1
	_order()


func _drop_held_layers() -> void:
	for l: Array in _held_layers:
		remove_child(l[1])
		l[1].queue_free()
	_held_layers.clear()
	_held_item = ""


func _place_held() -> void:
	if _held == null:
		return
	_held.rotation = 0.0
	_held.position = HAND_AT[_dir] - _scaled_grip()
	_held.flip_h = _dir == 1
	_held.z_index = -1 if HAND_BEHIND_AT[_dir] else 1
	_held.z_as_relative = true
