extends TestCase

func test_resource_variants_are_bounded_deterministic_and_rooted() -> void:
	var library := ModelLibrary3D.new()
	for id: String in MineralMeshes3D.IDS:
		var shapes := {}
		for variant in MineralMeshes3D.VARIANTS:
			var mesh := library.mesh_for(id, {"kind": "plant"}, variant)
			var bounds := mesh.get_aabb()
			check(is_zero_approx(bounds.position.y), "stone foot and vein meet ground at zero")
			check(bounds.size.x < 1 and bounds.size.z < 1 and bounds.end.y <= .81, "stays in its resource cell")
			var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			check(vertices.size() <= 600, "bounded resource geometry")
			shapes[hash(vertices)] = true
			eq(MineralMeshes3D.new().build(id, variant).surface_get_arrays(0)[Mesh.ARRAY_VERTEX], vertices, "fresh library keeps the shape")
			eq(library.mesh_for(id, {"kind": "plant"}, variant), mesh, "cached by kind and variant")
		eq(shapes.size(), 6, "six silhouettes for " + id)

func test_ore_is_a_vein_on_a_stone_matrix_without_emission() -> void:
	var library := ModelLibrary3D.new()
	var colors := {}
	for ore: String in MineralMeshes3D.ORE_COLORS:
		var mesh := library.mesh_for("base:" + ore + "_outcrop", {"kind": "plant"}, 0)
		eq(mesh.get_surface_count(), 2, "matrix and vein")
		var matrix: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var vein: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
		check(vein.size() > 0 and vein.size() < matrix.size(), "ore occupies only parts of the stone")
		var material := mesh.surface_get_material(1) as StandardMaterial3D
		check(material.vertex_color_use_as_albedo and not material.emission_enabled, "readable natural colour, no artificial glow")
		colors[hash(mesh.surface_get_arrays(1)[Mesh.ARRAY_COLOR])] = true
		for surface in mesh.get_surface_count():
			var a := mesh.surface_get_arrays(surface)
			var points: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			for i in range(0, points.size(), 3):
				check((points[i + 2] - points[i]).cross(points[i + 1] - points[i]).normalized().dot(normals[i]) > .99, "clockwise face agrees with its outward normal")
		eq(matrix, library.mesh_for("base:boulder", {"kind": "plant"}, 0).surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "ore shares the stone silhouette, not a coloured nugget")
	eq(colors.size(), 4, "iron, copper, silver and gold have distinct vein palettes")
