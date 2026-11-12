class_name ActorShadow3D
extends MeshInstance3D
## A soft footprint on the actual supporting surface, never a camera-facing card.
const SEGMENTS := 24
var radii := Vector2(.26, .38)
var _last_at := Vector3.INF
var _last_heading := Vector2.ZERO
var _last_scale := 0.0

func _init() -> void:
	var material := ShaderMaterial.new()
	material.shader = preload("res://src/experiment_3d/actor_shadow.gdshader")
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func fit(body: Dictionary) -> void:
	var half: Vector2i = body["half"]
	radii = Vector2(maxf(.18, half.y / float(Movement.UNIT) * 1.25),
		maxf(.28, half.x / float(Movement.UNIT) * 1.25))
	mesh = null

func follow(at: Vector3, heading: Vector2, scale_of_body: float, height_at: Callable) -> void:
	var forward := heading.normalized() if heading.length_squared() > .001 else Vector2.DOWN
	if mesh != null and at.is_equal_approx(_last_at) and forward.is_equal_approx(_last_heading) and is_equal_approx(scale_of_body, _last_scale):
		return
	_last_at = at
	_last_heading = forward
	_last_scale = scale_of_body
	var side := Vector2(forward.y, -forward.x)
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	for segment in SEGMENTS:
		for corner in 3:
			var circle := Vector2.ZERO if corner == 0 else Vector2.from_angle((segment + corner - 1) * TAU / SEGMENTS)
			var offset := (side * circle.x * radii.x + forward * circle.y * radii.y) * scale_of_body
			var point := Vector2(at.x, at.z) + offset
			# Parent scaling is applied later; sample in world space first.
			vertices.append(Vector3(offset.x, float(height_at.call(point)) - at.y + .055, offset.y) / scale_of_body)
			uv.append(circle * .5 + Vector2.ONE * .5)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var surface := ArrayMesh.new()
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = surface
