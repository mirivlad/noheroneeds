class_name BillboardActor3D
extends Node3D
## The original LPC/animal paper doll renders into a transparent viewport.
## Animation, equipment layers and palette shaders are reused unchanged.
## The doll is drawn this many viewport pixels to a world pixel: an LPC texel (half a world
## pixel) is two, an RO texel (a quarter) one.
const DOLL_SCALE := 4
const DOLL_FEET := Vector2(192, 304)
var viewport := SubViewport.new()
var picture := Sprite3D.new()
var doll: CharacterSprite
var body := StaticBody3D.new()
var shape := CollisionShape3D.new()
var previous := Vector2.ZERO
var facing := Vector2.DOWN
var placed := false
var animation_at := Vector2.ZERO
var looks := {}
var target := {}

func setup(registry: ContentRegistry, visual: Dictionary, appearance: Dictionary, hit: Dictionary) -> void:
	looks = appearance.duplicate(true)
	target = hit
	viewport.size = Vector2i(384, 384)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(viewport)
	doll = Art.character_sprite(registry, visual, appearance)
	viewport.add_child(doll)
	doll.scale = Vector2.ONE * DOLL_SCALE
	doll.position = DOLL_FEET
	picture.texture = viewport.get_texture()
	picture.pixel_size = 1.0 / (WorldView.CELL * DOLL_SCALE)
	picture.offset = Vector2(0, 112)
	picture.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	picture.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	picture.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	picture.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var paper := ShaderMaterial.new()
	paper.shader = preload("res://src/experiment_3d/paper_doll.gdshader")
	paper.set_shader_parameter("paper", viewport.get_texture())
	picture.material_override = paper
	add_child(picture)
	var box := BoxShape3D.new()
	box.size = Vector3(.7, 1.6, .7)
	shape.shape = box
	shape.position.y = .8
	body.add_child(shape)
	body.set_meta("target", target)
	add_child(body)

func show_actor(at: Vector3, yaw: float, delta: float, exact: bool) -> void:
	position = at if exact else position.lerp(at, minf(1, delta * 12))
	var horizontal := Vector2(position.x, position.z)
	if placed and horizontal.distance_squared_to(previous) > .00001:
		facing = (horizontal - previous).normalized()
		animation_at += (horizontal - previous).rotated(-yaw) * WorldView.CELL
	previous = horizontal
	placed = true
	# Rotate the animation's apparent movement, not the authoritative position.
	doll._face(facing.rotated(-yaw))
	doll.show_at(animation_at, delta, true)
	doll.position = DOLL_FEET
