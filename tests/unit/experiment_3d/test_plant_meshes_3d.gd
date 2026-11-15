extends TestCase

func test_species_and_variants_have_distinct_bounded_geometry() -> void:
	var library := ModelLibrary3D.new()
	var species_shapes := {}
	for species: String in PlantMeshes3D.SPECIES:
		var shapes := {}
		for variant in PlantMeshes3D.VARIANTS:
			var mesh := library.mesh_for("base:" + species, {"kind": "plant"}, variant)
			var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			shapes[hash(vertices)] = true
			check(vertices.size() < 2000, "bounded geometry: " + species)
			check(is_zero_approx(mesh.get_aabb().position.y), "rooted at ground: " + species)
			check(mesh.get_aabb().size.x < 1.0 and mesh.get_aabb().size.z < 1.0, "fits its resource cell: " + species)
			var fresh := ModelLibrary3D.new().mesh_for("base:" + species, {"kind": "plant"}, variant)
			eq(fresh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], vertices, "rebuilding the library preserves every vertex")
		eq(shapes.size(), 6, "six real silhouettes for " + species)
		species_shapes.merge(shapes)
	eq(species_shapes.size(), 36, "the six species share no stand-in geometry")

func test_berry_harvest_preserves_the_same_bush() -> void:
	var library := ModelLibrary3D.new()
	var silhouettes := {}
	for variant in PlantMeshes3D.SHRUB_VARIANTS:
		var bare := library.mesh_for("base:bush", {"kind": "plant"}, variant)
		var fruitful := library.mesh_for("base:berry_bush", {"kind": "plant"}, variant)
		var a: PackedVector3Array = bare.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var b: PackedVector3Array = fruitful.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		eq(b.slice(0, a.size()), a, "gathering removes fruit, retaining every branch and leaf")
		check(b.size() > a.size(), "fruit is visible geometry")
		silhouettes[hash(a)] = true
		var colors: PackedColorArray = bare.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		check(Array(colors).any(func(c: Color) -> bool: return c.g > c.r * 1.1), "ordinary foliage is green")
		var dry := library.mesh_for("base:dry_bush", {"kind": "plant"}, variant)
		var dry_colors: PackedColorArray = dry.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		check(not Array(dry_colors).any(func(c: Color) -> bool: return c.g > c.r * 1.1), "dead shrub is brown")
	eq(silhouettes.size(), 4, "four shrub silhouettes")
	for cell: Vector2i in [Vector2i.ZERO, Vector2i(31, 32), Vector2i(-32, -1), Vector2i(-1, -33)]:
		eq(PlantMeshes3D.variant_at("base:bush", cell), PlantMeshes3D.variant_at("base:berry_bush", cell), "harvest and regrowth keep the coordinate's variant")

func test_wind_setting_reaches_cached_and_future_materials() -> void:
	var library := ModelLibrary3D.new()
	var grass := library.mesh_for("base:tall_grass", {"kind": "plant"})
	library.set_wind(0)
	eq((grass.surface_get_material(0) as ShaderMaterial).get_shader_parameter("wind_strength"), 0.0)
	var later := library.decorative_grass(1)
	eq((later.surface_get_material(0) as ShaderMaterial).get_shader_parameter("wind_strength"), 0.0)
	library.set_wind(8)
	eq((later.surface_get_material(0) as ShaderMaterial).get_shader_parameter("wind_strength"), 1.0, "wind intensity is bounded")
