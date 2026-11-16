extends TestCase
## Snapshots were captured from unchanged main 829a3cb, recipe 18, before
## implementing the version selector. They cover three planned worlds.
const LEGACY := {
	2: ["ee00df9798c73167b71056d9f201ee6bc28d2576ed156a4ece3c89f2043fdd8d", "37a919ba0009832ead8856d6259f1275b9c6e3b64141f1da11d6b11027234d7e", "70783b886a9ca50fcdb8d3f0f1f08c322dcb1d0f2bb18a0414cf3cf2a4509024"],
	431: ["50ee6aad1aed1073f7f0cf30a7c2164486a6ac28f844835f06a3120d828500fd", "8748f9e993046fb626c24c4055083552d3cf084ccbd0e9adb5781083df45a2e0", "cd054f92fcceed031bee65c6d70b0c84f95989e0ca32cdeee0a17fa17b920201"],
	991: ["c58b6fb80c788bcbd9540589b54885b7db47ba88ce68d01614560b27265d825a", "4baa9b3b9cacf7b333744d44b7d9fdf313272aa6a92c6033536344c0deb98170", "864190caf55bd5d7cbc53af3ecc0b8c2011221fad333ea31ce0e395e80c28e18"]}

func test_old_recipe_matches_main_chunk_bytes_on_three_planets() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for seed_value: int in LEGACY:
		var plan := WorldPlan.generate(seed_value, "small", "temperate", content)
		var generator := SurfaceGenerator.new(seed_value, content, plan, 18)
		var cells := [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-2, 1)]
		for i in cells.size():
			var at: Vector2i = cells[i]
			eq(Hash.sha256(ChunkCodec.encode(generator.generate(at.x, at.y))).hex_encode(), LEGACY[seed_value][i], "recipe 18 unchanged: seed %d, %s" % [seed_value, at])

func test_old_world_keeps_recipe_for_loader_and_new_chunks() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("recipe18.db")
	var store := WorldStore.new()
	check(store.open(path), "create a store with the old world's metadata")
	var values := {"seed": "2", "world_id": "legacy-recipe18", "world_format": str(ServerWorld.WORLD_FORMAT), "surface_generator_version": "18", "settlement_generator_version": str(Settlements.VERSION)}
	for key: String in values:
		check(store.write_meta(key, values[key]), "write " + key)
	store.close()
	var world := ServerWorld.open(path, content)
	if not check(world != null, "recipe 18 is supported without migration"): return
	eq(world.generator.generation_version, 18, "simulation uses the saved recipe")
	eq(world.loader._generator.generation_version, 18, "loader uses the saved recipe")
	var generated := world.chunk("surface", 2, -1)
	var baseline := SurfaceGenerator.new(2, content, null, 18)
	baseline.underground = world.underground
	var expected := baseline.generate(2, -1)
	# Server arrival legitimately adds fauna metadata and growth clocks.
	# Compare the actual terrain/resource layers, including cave mouths.
	for layer: String in ["ground", "cover", "structure", "roof", "ceiling"]:
		eq(generated.layer_ids(layer), expected.layer_ids(layer), "unexplored " + layer + " keeps recipe 18")
	eq(generated.meta["gen_version"], 18, "generated chunk records recipe 18")
	generated.set_cell("cover", 3, 4, "base:berry_bush")
	world.mark_chunk_dirty("surface", 2, -1)
	world.close()
	world = ServerWorld.open(path, content)
	if not check(world != null, "old world reopens after a change"): return
	eq(world.store.read_meta("surface_generator_version"), "18", "opening did not upgrade metadata")
	eq(world.chunk("surface", 2, -1).get_cell("cover", 3, 4), "base:berry_bush", "saved server state wins")
	world.close()

func test_unknown_surface_recipe_is_refused_without_writing() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("future.db")
	var world := ServerWorld.open(path, content, {"seed": 2})
	if not check(world != null, "new world opens"): return
	world.close()
	var store := WorldStore.new()
	check(store.open(path) and store.write_meta("surface_generator_version", "999"), "write future version")
	store.close()
	var before := FileAccess.get_sha256(path)
	check(ServerWorld.open(path, content) == null, "future generator is refused")
	eq(FileAccess.get_sha256(path), before, "future save remains untouched")

func test_geological_groups_repeat_across_longitude_and_query_order() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var generator := SurfaceGenerator.new(431, content, plan)
	var width := plan.size.x * Chunk.SIZE
	for at: Vector2i in [Vector2i(31, 8), Vector2i(32, 8), Vector2i(-1, -19), Vector2i(0, -19)]:
		var first := generator._mineral_group(at.x, at.y)
		var wrapped := generator._mineral_group(at.x + width, at.y)
		eq(first["site"], wrapped["site"], "same province centre after a world turn")
		check(is_equal_approx(first["weight"], wrapped["weight"]), "group weight is periodic")
		generator._mineral_group(at.y * 79, at.x * 53)
		eq(generator._mineral_group(at.x, at.y), first, "unrelated queries cannot change a group")
