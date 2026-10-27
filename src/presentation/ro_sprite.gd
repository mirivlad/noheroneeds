class_name RoSprite
extends CharacterSprite
## A human from the Ragnarok-Online-style sprite pipeline (tools/art/ro_sprites,
## export_game.py): the body with its drawn face, a hairstyle, every worn
## thing and every tool with frames of its own are atlases of the same clips
## in eight real directions (no mirroring). Each layer was filmed over the
## invisible body, so a frame of a layer holds only what shows of it; the
## visual gives the order the layers are drawn in, frame by frame, from their
## depth. Swings are real clips (a chop, a thrust, a shot, a cast). Skin and
## hair are grey, painted the character's colours (ro_skin.gdshader,
## ro_hair.gdshader); hair is cut under headwear where it is inside the
## headwear's keep-out.

## Rows of the atlases: directions on the screen.
const ROWS := ["s", "se", "e", "ne", "n", "nw", "w", "sw"]
## Row for each octant of a move (0 east, then clockwise on the screen: se, s, sw...).
const ROW_OF_OCTANT := [2, 1, 0, 7, 6, 5, 4, 3]
## A turn to the next direction waits until the move is this many degrees past the middle.
const TURN_SLACK := 8.0
## Where the right hand is in each row (frame pixels from the feet), for a
## thing in the hands with no frames of its own; and whether it is behind.
const HAND_PX := [Vector2(-16, -48), Vector2(-8, -48), Vector2(3, -48), Vector2(11, -49),
	Vector2(16, -49), Vector2(8, -49), Vector2(-3, -48), Vector2(-12, -48)]
const HAND_BEHIND_ROW := [false, false, false, true, true, true, true, false]
## How deep a swimmer sits: frame pixels below the water line.
const RO_SINK_PX := 45
const HAIR_SHADER := preload("res://src/presentation/ro_hair.gdshader")
const SKIN_SHADER := preload("res://src/presentation/ro_skin.gdshader")
## Hair and skin with no colour chosen.
const HAIR_COLOUR := "#7d4513"
const SKIN_COLOUR := "#dc9b7e"

## Layers of what is in the hands: [slot, Sprite2D, sheet]; and which item.
var _held_layers: Array = []
var _held_item := ""
var _row := 0
var _clip := "idle"
var _index := 0
var _faced := false
var _drawn_order := []
## Dev (DevRuns --poses): [clip, row, frame] shown whatever the character does; [] lets it be.
var pinned: Array = []
## The keep-out sheet of the headwear worn ({} for none): hair inside it is not drawn.
var _keep_out := {}


func _init(body: Texture2D, visual: Dictionary, layers: Array = [], looks: Dictionary = {}) -> void:
	super(body, visual, layers, looks)
	turn_to(Vector2.DOWN)  # facing the viewer until it moves


## The body gets its skin colour; hair its colour and the cut of the headwear worn.
func _add_layer(slot: String, tex: Texture2D, sheet := {}) -> void:
	super(slot, tex, sheet)
	if slot == "body":
		var skin := ShaderMaterial.new()
		skin.shader = SKIN_SHADER
		skin.set_shader_parameter("skin_colour", _colour("skin", SKIN_COLOUR))
		(_layers[-1][1] as Sprite2D).material = skin
	if slot != "hair":
		return
	var m := ShaderMaterial.new()
	m.shader = HAIR_SHADER
	m.set_shader_parameter("hair_colour", _colour("hair", HAIR_COLOUR))
	var hat := String(look.get("worn", {}).get("headwear", ""))
	_keep_out = _visual.get("worn_overrides", {}).get(hat, {}).get("keep_out", {})
	if not _keep_out.is_empty():
		m.set_shader_parameter("keep_out", Art.texture(_keep_out["atlas_path"]))
	(_layers[-1][1] as Sprite2D).material = m


func dress(body: Texture2D, visual: Dictionary, layers: Array, looks: Dictionary) -> void:
	var item := _held_item
	_drop_held_layers()
	super(body, visual, layers, looks)
	_hold_layers(item)
	_frame({}, 0)


func _anim(anim_name: String) -> Dictionary:
	var clips: Dictionary = _visual.get("clips", {})
	if not clips.has(anim_name):
		anim_name = "walk" if anim_name == "run" and clips.has("walk") else "idle"
	var c: Dictionary = clips[anim_name]
	return {"name": anim_name, "frames": int(c["frames"]), "fps": float(c["fps"])}


func _face(v: Vector2) -> void:
	if not pinned.is_empty():
		return
	var angle := rad_to_deg(fposmod(atan2(v.y, v.x), TAU))  # 0 east, 90 south
	if _faced:
		# Keep the direction near a boundary between two: no flicker on a diagonal.
		var centre := 45.0 * ROW_OF_OCTANT.find(_row)
		if absf(angle_difference(deg_to_rad(angle), deg_to_rad(centre))) <= deg_to_rad(22.5 + TURN_SLACK):
			return
	_faced = true
	_row = ROW_OF_OCTANT[int(round(angle / 45.0)) % 8]
	_mirror = false
	_frame({}, 0)


## The order is the frame's (_frame); nothing depends on the direction alone.
func _order() -> void:
	pass


func _frame(anim: Dictionary, i: int) -> void:
	if anim.has("name"):
		_clip = String(anim["name"])
		_index = i
	var clip := _clip
	var index := _index
	if swinging():
		clip = _swing_clip()
		index = mini(int(_swing_t * _frame_count(clip)), _frame_count(clip) - 1)
	if not pinned.is_empty():
		clip = String(pinned[0])
		_row = int(pinned[1])
		index = int(pinned[2])
	for l: Array in _layers + _held_layers:
		_place_frame(l[1], l[2], clip, index)
	_draw_in_order(clip, index)
	if not swinging():
		_place_held()
	# A thing whose frames do not cover this is its picture at the hand.
	if _held:
		_held.visible = not swinging() and not _held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible)


func _place_frame(s: Sprite2D, sheet: Dictionary, clip: String, index: int) -> void:
	var at := _frame_rect(sheet, clip, index)
	if at.size == Vector2.ZERO:
		s.visible = false
		return
	s.visible = true
	s.flip_h = false
	s.region_rect = at
	s.offset = -Vector2(float(sheet["origin"][0]), float(sheet["origin"][1]))
	if submerged:  # swimming (ADR-0050): sunk, only what is above the water line drawn
		s.region_rect.size.y = maxf(1.0, float(sheet["origin"][1]) - RO_SINK_PX)
		s.offset.y += RO_SINK_PX
	if s.material is ShaderMaterial and (s.material as ShaderMaterial).shader == HAIR_SHADER:
		_place_cut(s.material, at.position + Vector2(sheet["origin"][0], sheet["origin"][1]), clip, index)


## A colour of the look ("#rrggbb") as the shaders take it.
func _colour(key: String, default: String) -> Vector3:
	var c := Color.from_string(String(look.get("colors", {}).get(key, default)), Color(default))
	return Vector3(c.r, c.g, c.b)


## Where a frame of a sheet is in its atlas, in this row; empty when the sheet has no such frame.
func _frame_rect(sheet: Dictionary, clip: String, index: int) -> Rect2:
	var r: Array = sheet.get("anims", {}).get(clip, [])
	if r.is_empty() or index >= int(r[1]):
		return Rect2()
	var column := int(r[0]) + index
	var columns := int(sheet["columns"])
	var w := int(sheet["frame"][0])
	var h := int(sheet["frame"][1])
	return Rect2((column % columns) * w, ((column / columns) * ROWS.size() + _row) * h, w, h)


## The hair frame's feet are at `feet` in its atlas: the same frame of the keep-out, lined up by the feet.
func _place_cut(m: ShaderMaterial, feet: Vector2, clip: String, index: int) -> void:
	var at := _frame_rect(_keep_out, clip, index)
	m.set_shader_parameter("cut", at.size != Vector2.ZERO)
	if at.size == Vector2.ZERO:
		return
	m.set_shader_parameter("offset", at.position + Vector2(_keep_out["origin"][0], _keep_out["origin"][1]) - feet)
	m.set_shader_parameter("keep_rect", Vector4(at.position.x, at.position.y, at.size.x, at.size.y))


## Back to front as the visual orders this frame's layers.
func _draw_in_order(clip: String, index: int) -> void:
	var keys: Array = _visual.get("layers", [])
	var rows: Array = _visual.get("order", {}).get(clip, [])
	var listed: Array = rows[_row][index] if _row < rows.size() and index < (rows[_row] as Array).size() else []
	var rank := {}
	for k in listed.size():
		rank[String(keys[int(listed[k])])] = k
	var all := _layers + _held_layers
	all.sort_custom(func(a: Array, b: Array) -> bool:
		return int(rank.get(String(a[2].get("key", "")), keys.size())) < int(rank.get(String(b[2].get("key", "")), keys.size())))
	var drawn := all.map(func(l: Array) -> Node: return l[1])
	if drawn == _drawn_order:
		return
	_drawn_order = drawn
	for i in drawn.size():
		move_child(drawn[i], i)


func _frame_count(clip: String) -> int:
	return int(_visual["clips"][clip]["frames"])


func _swing_clip() -> String:
	var clip := String(_visual.get("swings", {}).get(_swing_kind, "slash"))
	return clip if _visual["clips"].has(clip) else "idle"


## A swing is its clip, played once at its own pace; the body stays put.
func _swing_step(delta: float) -> Vector2:
	if _swing_t < 0.0:
		return Vector2.ZERO
	var c: Dictionary = _visual["clips"][_swing_clip()]
	_swing_t += delta * float(c["fps"]) / float(c["frames"])
	if _swing_t >= 1.0:
		_swing_t = -1.0
		_place_held()
	if _held and _swing_t >= 0.0:
		_held.visible = false
	return Vector2.ZERO


## In the hands: a tool or weapon with frames of its own (the visual's
## held_overrides, by `item`), else its picture at the hand.
func hold(picture: Texture2D, grip := GRIP, item := "") -> void:
	if item != _held_item:
		_drop_held_layers()
		_hold_layers(item)
		_frame({}, 0)
	super(picture, grip, item)
	if _held:
		_held.visible = not swinging() and not _held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible)


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
		add_child(s)
		_held_layers.append([String(held["layer"]), s, sheet])
	_drawn_order = []


func _drop_held_layers() -> void:
	for l: Array in _held_layers:
		remove_child(l[1])
		l[1].queue_free()
	_held_layers.clear()
	_held_item = ""
	_drawn_order = []


func _place_held() -> void:
	if _held == null:
		return
	_held.rotation = 0.0
	_held.position = HAND_PX[_row] * float(_visual.get("pixel_scale", 1.0)) - _scaled_grip()
	_held.flip_h = false
	_held.z_index = -1 if HAND_BEHIND_ROW[_row] else 1
	_held.z_as_relative = true
