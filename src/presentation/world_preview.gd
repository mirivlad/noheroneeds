class_name WorldPreview
extends Control
## The same stored fields used by geography, shown as a flat map or a sphere.

var plan: WorldPlan
var picture: TextureRect
var viewport: SubViewport
var globe: MeshInstance3D
var camera: Camera3D
var dragging := false
var distance := 3.2


func _init() -> void:
	custom_minimum_size = Vector2(360, 240)
	mouse_filter = Control.MOUSE_FILTER_STOP


func show_plan(source: WorldPlan) -> void:
	plan = source
	for child in get_children():
		remove_child(child)
		child.queue_free()
	picture = null
	viewport = null
	globe = null
	camera = null
	var texture := ImageTexture.create_from_image(map_image(plan))
	if plan.preset == "single_continent":
		picture = TextureRect.new()
		picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		picture.texture = texture
		picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(picture)
	else:
		var holder := SubViewportContainer.new()
		holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		holder.stretch = true
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(holder)
		viewport = SubViewport.new()
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		holder.add_child(viewport)
		var root := Node3D.new()
		viewport.add_child(root)
		globe = MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 1.0
		mesh.height = 2.0
		mesh.radial_segments = 96
		mesh.rings = 48
		globe.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = texture
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		globe.material_override = mat
		root.add_child(globe)
		camera = Camera3D.new()
		camera.fov = 50.0
		camera.position = Vector3(0, 0, distance)
		root.add_child(camera)
		camera.current = true


func _gui_input(event: InputEvent) -> void:
	if not globe:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			dragging = button.pressed
		elif button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			distance = clampf(distance + (-0.3 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 0.3), 2.8, 6.0)
			camera.position.z = distance
		accept_event()
	elif event is InputEventMouseMotion and dragging:
		var motion := event as InputEventMouseMotion
		globe.rotation.y += motion.relative.x * 0.01
		globe.rotation.x = clampf(globe.rotation.x + motion.relative.y * 0.01, -PI / 2.0, PI / 2.0)
		accept_event()


static func map_image(source: WorldPlan) -> Image:
	var image := Image.create(source.size.x, source.size.y, false, Image.FORMAT_RGB8)
	for y in source.size.y:
		for x in source.size.x:
			var k := y * source.size.x + x
			var h := source.value(0, Vector2i(x, y))
			var warmth := source.value(1, Vector2i(x, y))
			var rain := source.value(2, Vector2i(x, y))
			var color := Color("195474")
			if h >= 0.0:
				if source.lake[k] > 0.0 or source.river[k] > 0.0:
					color = Color("4b9ab1")
				elif warmth < -0.52:
					color = Color("e4e9df")
				elif warmth < -0.25:
					color = Color("a6b8a0")
				elif h > 0.45:
					color = Color("a5a59a") if warmth > -0.2 else Color("e5e9e2")
				elif h > 0.2:
					color = Color("6c8063")
				elif warmth > 0.32 and rain < -0.16:
					color = Color("d4b877")
				elif rain < -0.15:
					color = Color("9ba867")
				else:
					color = Color("5f9864")
			image.set_pixel(x, y, color)
	return image
