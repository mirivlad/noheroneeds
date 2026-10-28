class_name CharacterPreview
extends Control
## Animated preview shared by the offline editor and the in-world paper doll.
## The editor chooses what it does (`action`: stand, walk, run, a blow with
## what is in its hands now and then, sit, lie) and what it holds; it turns
## round every 1.2 s.

var doll: CharacterSprite
## What it does: "idle", "walk", "run", "blow", "sit", "lie".
var action := "walk"
## Kept for the windows that only stand it still or walk it.
var walking := true:
	set(v):
		walking = v
		action = "walk" if v else "idle"
var _time := 0.0
var _turn := 0.0
var _visual := {}
var _content: ContentRegistry
var _held := ""
var _pos := Vector2.ZERO
var _blow := 0.0
var _shown_action := ""
const BLOW_EVERY := 1.5


func _init() -> void:
	custom_minimum_size = Vector2(120, 132)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_look(content: ContentRegistry, looks: Dictionary) -> void:
	_content = content
	_visual = content.visual_of(String(looks.get("body_plan", "base:human_m")))
	if doll and Art.same_kind(doll, _visual):
		Art.dress(doll, content, _visual, looks)
	else:
		if doll:
			doll.queue_free()
		doll = Art.character_sprite(content, _visual, looks)
		add_child(doll)
		_shown_action = ""
	# Two raster pixels an LPC texel, whatever the sheet's own scale; finer ones (RO) as in the world.
	doll.scale = Vector2.ONE * 2.0 / maxf(0.5, float(_visual.get("pixel_scale", 1.0)))
	doll.position = _feet()
	hold_item(_held)


func _feet() -> Vector2:
	return Vector2(custom_minimum_size.x / 2, 122)


## A thing in its hands to try (its picture and grip as in the world), "" — none.
func hold_item(id: String) -> void:
	_held = id
	if doll == null or _content == null:
		return
	var v := _content.visual_of(id) if id != "" else {}
	var at: AtlasTexture = null
	if not v.is_empty():
		at = AtlasTexture.new()
		at.atlas = Art.texture(String(v["atlas_path"]))
		at.region = Rect2(v["rect"][0], v["rect"][1], v["rect"][2], v["rect"][3])
	var grip := CharacterSprite.GRIP
	var g: Array = v.get("grip", [])
	if not g.is_empty():
		grip = Vector2(float(g[0]) - float(v["rect"][2]) / 2.0, float(g[1]) - float(v["rect"][3]) / 2.0)
	doll.hold(at, grip, id)


func _process(delta: float) -> void:
	if doll == null or not is_visible_in_tree():
		return
	_time += delta
	_turn += delta
	var dir := Vector2.DOWN.rotated(-floorf(_turn / 1.2) * PI / 4)
	if action != _shown_action:  # sitting or lying till another is chosen
		_shown_action = action
		if action == "sit":
			doll.react("sit", 1e6)
		elif action == "lie":
			doll.react("dead", 1e6)
		else:
			doll.react("")
		_blow = 0.3
	match action:
		"walk":
			_pos += dir * CharacterSprite.WALK_PX_PER_SEC * delta
		"run":
			_pos += dir * CharacterSprite.WALK_PX_PER_SEC * 1.6 * delta
		"blow":
			_blow -= delta
			if _blow <= 0.0:
				_blow = BLOW_EVERY
				doll.swing(dir, WorldView.swing_of(_content, _held) if _content else "lunge")
	if action in ["idle", "blow", "sit", "lie"] and not doll.swinging():
		doll.turn_to(dir)
	doll.show_at(_pos, delta, true)
	doll.position = _feet()
