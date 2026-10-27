class_name CharacterPreview
extends Control
## Animated preview shared by the offline editor and the in-world paper doll.

var doll: CharacterSprite
var walking := true
var _time := 0.0
var _turn := 0.0
var _visual := {}


func _init() -> void:
	custom_minimum_size = Vector2(120, 132)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_look(content: ContentRegistry, looks: Dictionary) -> void:
	_visual = content.visual_of(String(looks.get("body_plan", "base:human_m")))
	if doll and Art.same_kind(doll, _visual):
		Art.dress(doll, content, _visual, looks)
	else:
		if doll:
			doll.queue_free()
		doll = Art.character_sprite(content, _visual, looks)
		add_child(doll)
	# Two raster pixels an LPC texel, whatever the sheet's own scale; finer ones (RO) as in the world.
	doll.scale = Vector2.ONE * 2.0 / maxf(0.5, float(_visual.get("pixel_scale", 1.0)))
	doll.position = Vector2(custom_minimum_size.x / 2, 122)


func _process(delta: float) -> void:
	if doll == null or not is_visible_in_tree():
		return
	_time += delta
	_turn += delta
	doll.turn_to(Vector2.DOWN.rotated(-floorf(_turn / 1.2) * PI / 4))
	var anim := doll._anim("walk" if walking else "idle")
	doll._frame(anim, int(_time * float(anim["fps"])) % int(anim["frames"]))
