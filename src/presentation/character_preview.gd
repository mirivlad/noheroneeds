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
	_visual = content.visual_of(String(looks.get("body_plan", "base:humanoid_adult")))
	var body := Art.character_texture(_visual, looks.get("colors", {}))
	var layers := Art.character_layers(content, _visual, looks)
	if doll:
		doll.dress(body, _visual, layers, looks)
	else:
		doll = CharacterSprite.new(body, _visual, layers, looks.duplicate(true))
		doll.scale = Vector2(3, 3)
		add_child(doll)
	doll.position = Vector2(custom_minimum_size.x / 2, 122)


func _process(delta: float) -> void:
	if doll == null or not is_visible_in_tree():
		return
	_time += delta
	_turn += delta
	doll.turn_to(Vector2.DOWN.rotated(-floorf(_turn / 1.2) * PI / 4))
	var anim := doll._anim("walk" if walking else "idle")
	doll._frame(anim, int(_time * float(anim["fps"])) % int(anim["frames"]))
