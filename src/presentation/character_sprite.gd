class_name CharacterSprite
extends Node2D
## A character drawn from a sheet: rows are directions (s, se, e, ne, n; the
## west side is mirrored), columns are frames (idle, step, step).
## Placed at the feet, so it sorts with trees and walls by where it stands.

const DIRS := ["s", "se", "e", "ne", "n"]
const FRAME_TIME := 0.15

var _sprite := Sprite2D.new()
var _visual: Dictionary
var _shown := Vector2.ZERO
var _dir := 0
var _mirror := false
var _walk := 0.0
var _placed := false


func _init(sheet: Texture2D, visual: Dictionary) -> void:
	_visual = visual
	_sprite.texture = sheet
	_sprite.region_enabled = true
	_sprite.centered = false
	_sprite.offset = -Vector2(visual["origin"][0], visual["origin"][1])
	add_child(_sprite)
	_frame(0)


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
		_walk += delta
	else:
		_walk = 0.0
	position = _shown.round()
	_frame(0 if _walk == 0.0 else 1 + int(_walk / FRAME_TIME) % 2)


func _face(v: Vector2) -> void:
	var a := fposmod(atan2(v.y, v.x), TAU)  # 0 = east, PI/2 = south
	var octant := int(round(a / (PI / 4))) % 8  # 0 e, 1 se, 2 s, 3 sw, 4 w, 5 nw, 6 n, 7 ne
	var table := [[2, false], [1, false], [0, false], [1, true], [2, true], [3, true], [4, false], [3, false]]
	_dir = table[octant][0]
	_mirror = table[octant][1]


func _frame(i: int) -> void:
	var w: int = _visual["rect"][2]
	var h: int = _visual["rect"][3]
	_sprite.region_rect = Rect2(_visual["rect"][0] + i * w, _visual["rect"][1] + _dir * h, w, h)
	_sprite.flip_h = _mirror
	_sprite.offset = -Vector2(w - _visual["origin"][0] if _mirror else _visual["origin"][0], _visual["origin"][1])
