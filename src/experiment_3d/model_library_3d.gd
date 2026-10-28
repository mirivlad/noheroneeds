class_name ModelLibrary3D
extends RefCounted
## Only visual mappings; content and server rules remain authoritative.
var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/experiment_3d/catalog.json"))
var _meshes := {}
var _materials := {}

func material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.95
		_materials[color] = m
	return _materials[color]

func mesh_for(id: String, definition: Dictionary) -> Mesh:
	var entry: Dictionary = catalog.get(id, {})
	var key := id if not entry.is_empty() else "fallback:" + String(definition.get("role", "resource"))
	if _meshes.has(key):
		return _meshes[key]
	var mesh: Mesh
	if not entry.is_empty():
		var scene := load("res://assets/experiment_3d/" + String(entry["path"])) as PackedScene
		var root := scene.instantiate() as Node3D
		var parts: Array = []
		_collect(root, Transform3D.IDENTITY, parts)
		var bounds := AABB()
		var first := true
		for part: Array in parts:
			var box: AABB = part[1] * (part[0] as Mesh).get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
		var size: Array = entry["size"]
		var scale_by := Vector3(float(size[0]), float(size[1]), float(size[2])) / bounds.size.max(Vector3.ONE * 0.001)
		if bool(entry.get("keep_aspect", false)):
			scale_by = Vector3.ONE * scale_by.y
		var normalize := Transform3D(Basis.from_scale(scale_by), -Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z) * scale_by)
		var joined := ArrayMesh.new()
		for part: Array in parts:
			var source := part[0] as Mesh
			for surface in source.get_surface_count():
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.append_from(source, surface, normalize * (part[1] as Transform3D))
				var own := source.surface_get_material(surface)
				st.set_material(_foliage(own, float(size[1])) if definition.get("kind") == "plant" else own)
				st.commit(joined)
		root.free()
		mesh = joined
	else:
		var box := BoxMesh.new()
		var role := String(definition.get("role", ""))
		box.size = Vector3(0.9, 2.0, 0.9) if role in ["wall", "window", "column"] else Vector3(0.7, 0.6, 0.7)
		if role in ["ceiling", "roof", "floor"]:
			box.size = Vector3(1, 0.12, 1)
		box.material = material(Color("ad7755"))
		mesh = box
	_meshes[key] = mesh
	return mesh

## A plant's material: its model's colour (and picture) shaded by height,
## speckled, a shade of its own per plant (foliage.gdshader).
const FOLIAGE := preload("res://src/experiment_3d/foliage.gdshader")
func _foliage(own: Material, height: float) -> Material:
	var key := [own, height]
	if _materials.has(key):
		return _materials[key]
	var m := ShaderMaterial.new()
	m.shader = FOLIAGE
	m.set_shader_parameter("height", height)
	if own is BaseMaterial3D:
		var b := own as BaseMaterial3D
		m.set_shader_parameter("albedo", b.albedo_color)
		if b.albedo_texture:
			m.set_shader_parameter("albedo_tex", b.albedo_texture)
			m.set_shader_parameter("has_tex", true)
	_materials[key] = m
	return m

func _collect(node: Node3D, parent: Transform3D, parts: Array) -> void:
	var transform := parent * node.transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		parts.append([(node as MeshInstance3D).mesh, transform])
	for child: Node in node.get_children():
		if child is Node3D:
			_collect(child, transform, parts)
