class_name GroundMaterial3D
extends RefCounted
## Reuse original LPC terrain fills, never modify source artwork.
const IDS := ["base:grass", "base:dirt", "base:forest_floor", "base:sand", "base:snow", "base:cave_floor", "base:stone_floor", "base:grass_dry", "base:mud", "base:gravel", "base:farmland", "base:moss", "base:water", "base:shallows", "base:deep_water"]
var atlas: ImageTexture
var shader := preload("res://src/experiment_3d/ground.gdshader")

func _init() -> void:
	var image := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	var source := (load("res://content/base/art/lpc_env/terrain.png") as Texture2D).get_image()
	var rows := [320, 32, 192, 128, 352, 0, 96, 224, 64, 96, 160, 192, 128, 128, 128, 320]
	for i in 16:
		# Two fill variants per cell, padded by repeating through the shader.
		for y in 2:
			for x in 2:
				image.blit_rect(source, Rect2i(480 + (x + y) * 32, rows[i], 32, 32), Vector2i(i % 4 * 64 + x * 32, i / 4 * 64 + y * 32))
	image.generate_mipmaps()
	atlas = ImageTexture.create_from_image(image)

func make(origin: Vector2i, ground_at: Callable) -> ShaderMaterial:
	var control := Image.create(34, 34, false, Image.FORMAT_RGBA8)
	for y in 34:
		for x in 34:
			var id: String = ground_at.call(origin + Vector2i(x - 1, y - 1))
			var index := IDS.find(id)
			control.set_pixel(x, y, Color(maxi(index, 0) / 255.0, 0, 0, 1))
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("atlas", atlas)
	mat.set_shader_parameter("control_map", ImageTexture.create_from_image(control))
	mat.set_shader_parameter("chunk_origin", Vector2(origin))
	return mat
