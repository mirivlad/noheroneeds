class_name WorldPreview
extends Control
## The same stored fields used by geography, shown as a flat map or a sphere.

const BIOME_COLORS := {
	"base:meadow": "81a96b", "base:forest": "427b50", "base:taiga": "557d6b",
	"base:grove": "74a865", "base:swamp": "738864", "base:steppe": "b0aa6b",
	"base:tundra": "dbe5d9", "base:rocky": "92927b", "base:desert": "d4b877",
	"base:mountains": "92998d", "base:peaks": "edf1e9",
}

var plan: WorldPlan
var picture: TextureRect
var viewport: SubViewport
var globe: MeshInstance3D
var camera: Camera3D
var dragging := false
var distance := 3.2


## What kind of world this is, in words for the new-world form: the continents
## and isles the preset is made of and how much of the surface is land. The
## presets differ in what they are, not only in size, and the caption says so
## before one plays: a small planet is a few continents, a huge one larger
## continents and oceans, not a scatter of isles.
static func describe(source: WorldPlan) -> String:
	if source.preset == "single_continent":
		return "Один материк в бесконечном океане"
	var rules: Dictionary = WorldPlan.LANDS.get(source.preset, {})
	var land := 0
	for y in source.size.y:
		for x in source.size.x:
			land += 1 if source.value(0, Vector2i(x, y)) > 0.0 else 0
	var share := 100.0 * float(land) / float(source.size.x * source.size.y)
	return "Континентальных областей: %d, островных дуг: до %d · суша — %d%% поверхности" % [
		int(rules.get("continents", 0)), int(rules.get("isles", 0)), roundi(share)]


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


## Each coarse point becomes this many pixels across in the preview: a biome
## edge is then finer than a chunk, not a square on the coarse grid.
const MAP_DETAIL := 2

static func map_image(source: WorldPlan) -> Image:
	var detail := MAP_DETAIL if not source.biome_rules.is_empty() else 1
	var image := Image.create(source.size.x * detail, source.size.y * detail, false, Image.FORMAT_RGB8)
	for py in image.get_height():
		for px in image.get_width():
			var at := Vector2((float(px) + 0.5) / detail, (float(py) + 0.5) / detail)
			var point := Vector2i(mini(floori(at.x), source.size.x - 1), mini(floori(at.y), source.size.y - 1))
			var k := point.y * source.size.x + point.x
			var cell := Vector2i(roundi((at.x - source.spawn.x) * WorldPlan.STEP),
				roundi((at.y - source.spawn.y) * WorldPlan.STEP))
			var color := Color("195474")
			var h := source.sample(0, cell)
			if h >= 0.0:
				if h < source.lake_level_at(cell) or source.river[k] > 0.0:
					color = Color("4b9ab1")
				else:
					var index := source.biome_index_at(cell)
					var biome: String = source.biome_ids[maxi(index, 0)] if index >= 0 \
						else source.biome_ids[source.biomes[k]]
					color = Color(String(BIOME_COLORS.get(biome, "7f9e69")))
			image.set_pixel(px, py, color)
	return image
