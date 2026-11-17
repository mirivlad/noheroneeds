extends TestCase

func test_connected_faces_share_world_vertices_across_chunk_and_height_origins() -> void:
	var left := Vector2i(31, -1)
	var right := left + Vector2i.RIGHT
	var solid := func(at: Vector2i) -> bool: return at in [left, right]
	var none := func(_at: Vector2i) -> bool: return false
	var sets := []
	for data: Array in [[left, 1.0], [right, 2.0]]:
		var cell: Vector2i = data[0]
		var origin := float(data[1])
		var top := func(corner: Vector2i) -> float: return 5 + RockCells3D.top(corner) - origin
		var mesh := RockCells3D.mesh(cell, 0, func(_c: Vector2i) -> float: return -1 - origin,
			solid, none, null, func(_n: Vector2i, c: Vector2i) -> float: return top.call(c), none,
			top, 0, origin)
		var vertices := {}
		for p: Vector3 in mesh.get_faces():
			var world := p + Vector3(cell.x + .5, origin, cell.y + .5)
			if absf(world.x - 32) < .00001:
				vertices[world.snapped(Vector3.ONE * .0001)] = true
		sets.append(vertices)
	check(sets[0].size() >= 11, "shared cap and all wall bands are represented")
	eq(sets[0], sets[1], "both chunk meshes meet at identical world vertices despite different local height origins")

func test_internal_rock_faces_only_close_real_height_steps() -> void:
	var solid := func(_at: Vector2i) -> bool: return true
	var none := func(_at: Vector2i) -> bool: return false
	var cap := func(c: Vector2i) -> float: return 5 + RockCells3D.top(c)
	var level := func(_n: Vector2i, c: Vector2i) -> float: return cap.call(c)
	var step := func(n: Vector2i, c: Vector2i) -> float: return cap.call(c) - (1 if n == Vector2i.RIGHT else 0)
	var low := func(_c: Vector2i) -> float: return 0
	var flat := RockCells3D.mesh(Vector2i.ZERO, 5, low, solid, none, null, level, none, cap)
	var stepped := RockCells3D.mesh(Vector2i.ZERO, 5, low, solid, none, null, step, none, cap)
	eq(flat.get_faces().size(), 24, "interior cells have a cap without hidden side walls")
	check(stepped.get_faces().size() > flat.get_faces().size(), "a lower neighbor is joined by actual closing geometry")

func test_exposed_mass_is_faceted_but_stays_inside_its_blocked_footprint() -> void:
	var none := func(_c: Vector2i) -> bool: return false
	var mesh := RockCells3D.mesh(Vector2i.ZERO, 0, func(_c: Vector2i) -> float: return 0, none, none, null)
	var normals := {}
	var coordinates := {}
	for p: Vector3 in mesh.get_faces():
		check(p.x >= -.50001 and p.x <= .50001 and p.z >= -.50001 and p.z <= .50001, "no rock extends into a walkable neighbor")
		check(p.y >= 0 and p.y < 3, "bounded crag height")
		coordinates[Vector2(p.x, p.z).snapped(Vector2.ONE * .0001)] = true
	for normal: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]: normals[normal.snapped(Vector3.ONE * .001)] = true
	check(normals.size() > 12 and coordinates.size() > 16, "the geometry has chipped rims and shaped faces rather than a textured box")
	eq(mesh.get_aabb().size.x, 1.0, "foot meets ground at the server cell boundary")

func test_four_surface_payloads_keep_the_same_geometry() -> void:
	var none := func(_c: Vector2i) -> bool: return false
	var original := PackedVector3Array()
	for style in 4:
		var mesh := RockCells3D.mesh(Vector2i(11, -32), 0, func(_c: Vector2i) -> float: return 0, none, none, null, Callable(), none, Callable(), style)
		var arrays := mesh.surface_get_arrays(0)
		if style == 0: original = arrays[Mesh.ARRAY_VERTEX]
		eq(arrays[Mesh.ARRAY_VERTEX], original, "lithology changes material, never simulation geometry")
		for color: Color in arrays[Mesh.ARRAY_COLOR]:
			check(is_equal_approx(color.r, style / 3.0), "surface data reaches every rock vertex")

func test_scree_is_small_and_its_mesh_cache_is_bounded() -> void:
	for variant in 3:
		var mesh := RockCells3D.scree(variant)
		check(mesh.get_aabb().end.y < .1 and mesh.get_aabb().size.x < .5 and mesh.get_aabb().size.z < .5, "foot debris cannot resemble an impassable boulder")
		check(mesh.get_faces().size() <= 60, "bounded decorative geometry")
		eq(RockCells3D.scree(variant), mesh, "all cells reuse one of three meshes")

func test_chunk_emission_preserves_pre_optimization_geometry_and_picking() -> void:
	var reference: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/experiment_3d/rock_cells_geometry.json"))
	for data: Dictionary in reference.cases:
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
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var faces := RockCells3D.append_to(surface, cell, 0, low, blocked, flush, top_of, shelf, cap, int(data.style), origin,
			Vector3(cell.x + .5, origin, cell.y + .5))
		var arrays := surface.commit().surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		eq(vertices.size(), int(data.vertex_count), "same triangles: " + data.id)
		eq(Hash.sha256(vertices.to_byte_array()).hex_encode(), data.vertices_sha256, "exact original world vertices: " + data.id)
		eq(Hash.sha256(faces.to_byte_array()).hex_encode(), data.vertices_sha256, "picking uses those same original vertices: " + data.id)
		eq(Hash.sha256((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).to_byte_array()).hex_encode(), data.uv_sha256, "same material coordinates: " + data.id)
		eq(Hash.sha256((arrays[Mesh.ARRAY_COLOR] as PackedColorArray).to_byte_array()).hex_encode(), data.colors_sha256, "same geological payload: " + data.id)
		var expected := Marshalls.base64_to_raw(data.normals_f32).to_float32_array()
		var normals := (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).to_byte_array().to_float32_array()
		eq(normals.size(), expected.size(), "same normal count")
		var error := 0.0
		for i in mini(normals.size(), expected.size()): error = maxf(error, absf(normals[i] - expected[i]))
		# The old path packed/unpacked normals in an intermediate ArrayMesh.
		check(error < .0001, "one packing pass keeps the original normal within quantization: " + data.id)
