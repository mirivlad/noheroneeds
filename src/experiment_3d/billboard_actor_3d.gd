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
var ground_shadow := ActorShadow3D.new()
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
var harness: CaravanHarness3D
var _paper: ShaderMaterial
var _volume_sprite: Sprite2D
var _volume_rect := Rect2()
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
			harness = CaravanHarness3D.new()
			cart.add_child(harness)
			harness.setup(cart)
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
	add_child(ground_shadow)
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
	_paper = paper
	paper.shader = preload("res://src/experiment_3d/paper_doll.gdshader")
	paper.set_shader_parameter("paper", viewport.get_texture())
	picture.material_override = paper
	add_child(picture)
	configure_volume(visual)
	var box := BoxShape3D.new()
	box.size = Vector3(.7, 1.6, .7)
	shape.shape = box
	shape.position.y = .8
	body.add_child(shape)
	body.set_meta("target", target)
	add_child(body)

## Animal frames retain their real near/far body surface for the 3D harness.
## Humans and older sheets keep the existing upright-card depth.
func configure_volume(visual: Dictionary) -> void:
	var data: Dictionary = visual.get("volume", {})
	_volume_sprite = null
	_paper.set_shader_parameter("has_volume",not data.is_empty())
	if data.is_empty():
		return
	var path := String(visual["atlas_path"]).get_base_dir().path_join(String(data["atlas"]))
	var texture := Art.texture(path)
	_volume_sprite = doll.get_child(0) as Sprite2D
	_volume_rect = Rect2()
	_paper.set_shader_parameter("volume_atlas",texture)
	_paper.set_shader_parameter("volume_size",Vector2(texture.get_size()))
	_paper.set_shader_parameter("volume_origin",Vector2(visual["origin"][0],visual["origin"][1]))
	_paper.set_shader_parameter("volume_pixel_scale",DOLL_SCALE*float(visual.get("pixel_scale",.25)))
	_paper.set_shader_parameter("volume_span",float(data["span"]))
	_paper.set_shader_parameter("volume_elevation",deg_to_rad(float(data["elevation"])))
	_paper.set_shader_parameter("volume_world_scale",float(data["px_per_m"])*float(visual.get("pixel_scale",.25))/WorldView.CELL)
	_process(0)

func _process(_delta: float) -> void:
	if _volume_sprite == null or _volume_sprite.region_rect == _volume_rect:
		return
	_volume_rect = _volume_sprite.region_rect
	_paper.set_shader_parameter("volume_frame",Vector4(_volume_rect.position.x,_volume_rect.position.y,_volume_rect.size.x,_volume_rect.size.y))

func harness_anchor(index: int, camera: Camera3D) -> Vector3:
	var anchors: Array = doll._visual.get("harness", [])
	if anchors.is_empty() or _volume_sprite == null:
		return Vector3.INF
	var frame: Array = doll._visual["frame"]
	var rect := _volume_sprite.region_rect
	var band := int(rect.position.y/frame[1]) / 8
	var column := band*int(doll._visual["columns"])+int(rect.position.x/frame[0])
	var row := int(rect.position.y/frame[1]) % 8
	if column>=anchors.size():
		return Vector3.INF
	var point: Array = anchors[column][row][index]
	var unit := float(doll._visual.get("pixel_scale",.25))/WorldView.CELL * global_basis.x.length()
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var toward := camera.global_basis.z
	var above := float(point[1])*unit
	var volume: Dictionary = doll._visual["volume"]
	var body_y := float(point[2])*float(volume["px_per_m"])*unit
	# Match the shader's guard while a new camera still has its default basis.
	var up_height := maxf(up.y,.05)
	var toward_height := maxf(toward.y,.05)
	var shift := .025 + above*toward_height/up_height + body_y*sin(deg_to_rad(float(volume["elevation"])))/(toward_height*up_height)
	return picture.global_position + right*float(point[0])*unit + up*above + toward*shift

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
