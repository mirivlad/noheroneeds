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
## A heading the server tells (a cart, a horse in harness). The delta of the
## smoothed position then no longer sets the facing: the server is the
## authority, and the client only eases the last small step.
var head_told := false
var told_heading := Vector2.DOWN
## How fast the told facing may be eased on the client (radians a second).
const HEAD_EASE := 8.0
var placed := false
var animation_at := Vector2.ZERO
var looks := {}
var target := {}
var cart: Node3D
var cart_tried := false
var packs: Node3D
var packs_tried := false
var wheel_angle := 0.0

## The wagon is made in Blender; its front points along local -Z.
func show_cart(on: bool) -> void:
	if on and cart == null and not cart_tried:
		cart_tried = true
		var scene := load("res://assets/experiment_3d/caravan/cart.glb") as PackedScene
		if scene:
			cart = scene.instantiate() as Node3D
			add_child(cart)
	if cart:
		cart.visible = on
		if on:
			cart.rotation.y = atan2(-facing.x, -facing.y)
			for wheel: Node in cart.find_children("Wheel*", "Node3D", true, false):
				(wheel as Node3D).rotation.x = wheel_angle

func show_packs(on: bool) -> void:
	if on and packs == null and not packs_tried:
		packs_tried = true
		var scene := load("res://assets/experiment_3d/caravan/packs.glb") as PackedScene
		if scene:
			packs = scene.instantiate() as Node3D
			add_child(packs)
	if packs:
		packs.visible = on
		if on:
			packs.rotation.y = atan2(-facing.x, -facing.y)


func setup(registry: ContentRegistry, visual: Dictionary, appearance: Dictionary, hit: Dictionary,
		made: CharacterSprite = null) -> void:
	looks = appearance.duplicate(true)
	target = hit
	viewport.size = Vector2i(384, 384)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(viewport)
	doll = made if made else Art.character_sprite(registry, visual, appearance)
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

## Strikes toward `dir` (on the ground, world axes) and keeps facing it: the
## facing is turned to the screen every frame, so it must be the world's.
func swing(dir: Vector2, kind: String, yaw: float) -> void:
	if dir.length() > 0.01:
		facing = dir.normalized()
	doll.swing(dir.rotated(-yaw), kind)

func show_actor(at: Vector3, yaw: float, delta: float, exact: bool) -> void:
	position = at if exact else position.lerp(at, minf(1, delta * 12))
	var horizontal := Vector2(position.x, position.z)
	var was_placed := placed
	if placed and horizontal.distance_squared_to(previous) > .00001:
		if not head_told:
			facing = (horizontal - previous).normalized()
		wheel_angle += horizontal.distance_to(previous) / .39
		animation_at += (horizontal - previous).rotated(-yaw) * WorldView.CELL
	previous = horizontal
	placed = true
	if head_told:
		if not was_placed:
			facing = told_heading
		else:
			var most := maxf(0.0, delta) * HEAD_EASE
			var turn := wrapf(told_heading.angle() - facing.angle(), -PI, PI)
			facing = facing.rotated(clampf(turn, -most, most)).normalized()
	# Rotate the animation's apparent movement, not the authoritative position.
	doll._face(facing.rotated(-yaw))
	doll.show_at(animation_at, delta, true)
	doll.position = DOLL_FEET


## The server gives this one's heading (a cart or a harnessed horse).
func tell_heading(dir: Vector2) -> void:
	if dir.length_squared() > .000001:
		told_heading = dir.normalized()
		head_told = true


## No told heading any more (the horse is unharnessed): go by the movement.
func forget_heading() -> void:
	head_told = false

## The lying frames already contain perspective, just like the standing
## ones. Keep the camera-facing card and lift only a sleeper on a mattress;
## projecting the image onto a horizontal plane flattens it a second time.
func lie(on: bool, height := 0.0) -> void:
	picture.position = Vector3(0, height if on else 0.0, 0)
