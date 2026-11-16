extends SceneTree
## Run only on the pre-optimization geometry to capture the saved contract.
const ORIGINAL := "5aa713124048038b8ef40e84dabf01b9c0e909f676302aa734ac5a069dba5e96"
func _initialize() -> void:
	if FileAccess.get_sha256("res://src/experiment_3d/rock_cells_3d.gd") != ORIGINAL:
		printerr("The reference must come from the original rock geometry")
		quit(1)
		return
	var cases := [
		{"id": "exposed_negative", "cell": [-33, 31], "origin_y": 2.0, "level": 5.0, "style": 1, "mode": "isolated"},
		{"id": "chunk_boundary_left", "cell": [31, -1], "origin_y": 1.0, "level": 5.0, "style": 2, "mode": "pair"},
		{"id": "chunk_boundary_right", "cell": [32, -1], "origin_y": 2.0, "level": 5.0, "style": 3, "mode": "pair"},
		{"id": "cliff_height_step", "cell": [7, -65], "origin_y": 7.0, "level": 8.0, "style": 0, "mode": "cliff"}]
	for data: Dictionary in cases:
		var cell := Vector2i(int(data.cell[0]), int(data.cell[1]))
		var origin := float(data.origin_y)
		var level := float(data.level)
		var mode := String(data.mode)
		var cap := func(c: Vector2i) -> float:
			return level + (.09 + .055 * sin(c.x * .74 + c.y * .43) + .035 * sin(c.y * .91) if mode == "cliff" else RockCells3D.top(c)) - origin
		var low := func(_c: Vector2i) -> float: return level - 4 - origin
		var blocked := func(c: Vector2i) -> bool:
			return c in [Vector2i(31, -1), Vector2i(32, -1)] if mode == "pair" else (c.y <= cell.y if mode == "cliff" else c == cell)
		var flush := func(_c: Vector2i) -> bool: return false
		var shelf := func(_c: Vector2i) -> bool: return mode == "cliff"
		var top_of := func(n: Vector2i, c: Vector2i) -> float: return cap.call(c) - (.75 if mode == "cliff" and n.x > cell.x else 0.0)
		var mesh := RockCells3D.mesh(cell, 0, low, blocked, flush, null, top_of, shelf, cap, int(data.style), origin)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append_from(mesh, 0, Transform3D(Basis.IDENTITY, Vector3(cell.x + .5, origin, cell.y + .5)))
		var final := st.commit()
		var arrays := final.surface_get_arrays(0)
		data["vertices_sha256"] = Hash.sha256((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array()).hex_encode()
		data["uv_sha256"] = Hash.sha256((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).to_byte_array()).hex_encode()
		data["colors_sha256"] = Hash.sha256((arrays[Mesh.ARRAY_COLOR] as PackedColorArray).to_byte_array()).hex_encode()
		data["normals_f32"] = Marshalls.raw_to_base64((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).to_byte_array())
		data["vertex_count"] = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var report := {"source_sha256": ORIGINAL, "engine": Engine.get_version_info().string, "cases": cases}
	FileAccess.open("res://build/nature-final/rock-contract-original.json", FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("ROCK_REFERENCE captured ", cases.size(), " original geometry cases")
	quit()
