extends TestCase


func test_plan_round_trip_and_validation() -> void:
	var original := WorldPlan.generate(431, "small", "temperate")
	var restored := WorldPlan.from_dict(original.to_dict())
	check(restored != null, "the saved map is readable")
	eq(restored.to_dict(), original.to_dict(), "all generated data survives storage")
	eq(WorldPlan.generate(431, "small", "temperate").fields, original.fields, "generation is deterministic")
	var broken := original.to_dict()
	broken["fields"] = ""
	check(WorldPlan.from_dict(broken) == null, "truncated maps are rejected")
	broken = original.to_dict()
	var invalid := original.downstream.duplicate()
	invalid[0] = invalid.size()
	broken["downstream"] = Marshalls.raw_to_base64(invalid.to_byte_array())
	check(WorldPlan.from_dict(broken) == null, "out-of-range drainage is rejected")
	original.seed_value = 9007199254740993
	var decoded: Variant = JSON.parse_string(JSON.stringify(original.to_dict()))
	eq(WorldPlan.from_dict(decoded).seed_value, original.seed_value, "64-bit seed survives JSON without precision loss")


func test_presets_climate_and_boundaries() -> void:
	var flat := WorldPlan.generate(19, "single_continent", "temperate")
	check(flat.value(0, Vector2i(-1, 0)) < 0.0, "outside the continent map is ocean")
	var cold := WorldPlan.generate(19, "small", "cold")
	var hot := WorldPlan.generate(19, "small", "hot")
	check(cold.size != WorldPlan.PRESETS["large"], "planet sizes differ")
	var at := Vector2i(30, 30)
	eq(cold.value(0, at), cold.value(0, at + Vector2i(cold.size.x, 0)), "longitude wraps")
	eq(cold.value(0, Vector2i(10, -1)), cold.value(0, Vector2i(10 + cold.size.x / 2, 0)), "north pole reverses latitude and longitude")
	eq(cold.value(0, Vector2i(10, cold.size.y)), cold.value(0, Vector2i(10 + cold.size.x / 2, cold.size.y - 1)), "south pole reverses latitude and longitude")
	eq(cold.sample(0, Vector2i.ZERO), cold.value(0, cold.spawn), "world origin samples the stored spawn point")
	check(hot.value(1, at) > cold.value(1, at), "climate changes warmth")
	eq(hot.value(0, at), cold.value(0, at), "climate does not move the coast")


func test_continent_is_one_landmass_surrounded_by_sea() -> void:
	for seed_number in [0, 1, 19, 431, 10000]:
		var plan := WorldPlan.generate(seed_number, "single_continent", "temperate")
		var land := {}
		for y in plan.size.y:
			for x in plan.size.x:
				var p := Vector2i(x, y)
				if plan.value(0, p) > 0.0:
					land[p] = true
		check(land.has(plan.spawn), "spawn is on land")
		var queue: Array[Vector2i] = [plan.spawn]
		land.erase(plan.spawn)
		var i := 0
		while i < queue.size():
			var p := queue[i]
			i += 1
			for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var neighbor := p + d
				if land.erase(neighbor):
					queue.append(neighbor)
		eq(land.size(), 0, "all land joins the continent for seed %d" % seed_number)
		for x in plan.size.x:
			check(plan.value(0, Vector2i(x, 0)) < 0.0 and plan.value(0, Vector2i(x, plan.size.y - 1)) < 0.0, "north and south are sea")
		for y in plan.size.y:
			check(plan.value(0, Vector2i(0, y)) < 0.0 and plan.value(0, Vector2i(plan.size.x - 1, y)) < 0.0, "east and west are sea")


func test_global_drainage_joins_oceans_and_survives_serialization() -> void:
	for preset_id in ["single_continent", "small"]:
		var plan := WorldPlan.generate(431, preset_id, "temperate")
		var restored := WorldPlan.from_dict(plan.to_dict())
		var count := plan.size.x * plan.size.y
		var state := PackedByteArray()
		state.resize(count)
		var river_count := 0
		var lake_count := 0
		for k in count:
			if plan.fields[k * 3] < 128:
				state[k] = 2
			river_count += 1 if plan.river[k] > 0.0 else 0
			lake_count += 1 if plan.lake[k] > 0.0 else 0
		for k in count:
			if state[k] == 2:
				continue
			var path := PackedInt32Array()
			var current := k
			while current >= 0 and state[current] == 0:
				state[current] = 1
				path.append(current)
				current = plan.downstream[current]
			check(current >= 0 and state[current] == 2, "each drainage path reaches an ocean without a cycle")
			for seen in path:
				state[seen] = 2
		check(river_count > 0 and lake_count > 0, "%s includes rivers and lakes" % preset_id)
		eq(restored.downstream, plan.downstream, "drainage is saved")
		eq(restored.river, plan.river, "rivers are saved")
		eq(restored.lake, plan.lake, "lakes are saved")


func test_huge_world_is_global_and_bounded() -> void:
	var plan := WorldPlan.generate(22, "huge", "cold")
	eq(plan.fields.size(), plan.size.x * plan.size.y * 3, "one finite coarse map")
	eq(plan.downstream.size(), plan.size.x * plan.size.y, "drainage covers the whole map")
	eq(WorldHydrology.index_at(plan, Vector2i(-1, 10)), WorldHydrology.index_at(plan, Vector2i(plan.size.x - 1, 10)), "drainage crosses the longitude seam")
	eq(WorldHydrology.index_at(plan, Vector2i(10, -1)), WorldHydrology.index_at(plan, Vector2i(10 + plan.size.x / 2, 0)), "drainage crosses the pole")


func test_surface_and_geology_use_saved_plan() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate")
	var saved := WorldPlan.from_dict(plan.to_dict())
	var surface := SurfaceGenerator.new(plan.seed_value, content, saved)
	check(surface.geography is PlannedGeography, "surface uses the global plan")
	var point := Vector2i(100, -200)
	eq(surface.geography.sample(Geography.HEIGHT, point.x, point.y), saved.sample(0, point), "height comes from the stored map")
	eq(surface.geography.climate_at(point.x, point.y), Vector2(saved.sample(1, point), saved.sample(2, point)), "biome climate comes from the stored map")
	var underground := UndergroundGenerator.new(plan.seed_value, content)
	underground.geography = surface.geography
	eq(underground.geography.sample(Geography.HEIGHT, point.x, point.y), saved.sample(0, point), "geology sees the same relief")
	var again := SurfaceGenerator.new(plan.seed_value, content, plan)
	eq(ChunkCodec.encode(surface.generate(2, 3)), ChunkCodec.encode(again.generate(2, 3)), "saved and original plans generate the same detail")


func test_server_persists_the_exact_plan_and_modified_chunk() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var plan := WorldPlan.generate(431, "small", "cold")
	var world := ServerWorld.open(path, content, {"world_plan": plan.to_dict()})
	check(world != null, "planned world opens")
	var chunk := world.chunk("surface", 2, 3)
	chunk.set_cell("ground", 1, 1, "base:stone")
	world.mark_chunk_dirty("surface", 2, 3)
	world.close()
	var other := WorldPlan.generate(999, "small", "hot")
	world = ServerWorld.open(path, content, {"world_plan": other.to_dict()})
	check(world != null, "planned world reopens")
	var restored := (world.generator.geography as PlannedGeography).plan
	eq(restored.to_dict(), plan.to_dict(), "opening ignores a new plan and loads the saved one")
	eq(world.chunk("surface", 2, 3).get_cell("ground", 1, 1), "base:stone", "materialized modifications survive")
	world.close()


func test_corrupt_plan_is_refused_without_overwriting_world() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var plan := WorldPlan.generate(55, "small", "temperate")
	var world := ServerWorld.open(path, content, {"world_plan": plan.to_dict()})
	world.close()
	var store := WorldStore.new()
	store.open(path)
	store.write_meta("world_plan", "broken")
	store.close()
	check(ServerWorld.open(path, content) == null, "a damaged map is refused")
	check(ServerWorld.open_error.contains("повреждён"), "the error explains the damaged plan")
	store = WorldStore.new()
	store.open(path)
	eq(store.read_meta("world_plan"), "broken", "opening does not regenerate or overwrite a damaged plan")
	store.close()


func test_canonical_world_coordinates_close_the_seam_and_poles() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	for scale: int in [1, Chunk.SIZE, Chunk.SIZE * Movement.UNIT]:
		var first := -plan.spawn * scale
		var width := plan.size.x * scale
		var height := plan.size.y * scale
		var inside := first + Vector2i(5, 7)
		eq(plan.canonical_point(inside + Vector2i(width, 0), scale), inside, "east and west identify the same coordinate")
		eq(plan.canonical_point(first + Vector2i(5, -1), scale), first + Vector2i(5 + width / 2, 0), "crossing the north pole reverses y and turns longitude")
		eq(plan.canonical_point(first + Vector2i(5, height), scale), first + Vector2i(5 + width / 2, height - 1), "crossing the south pole reverses y and turns longitude")
		var far := inside + Vector2i(width * 5, height * 4)
		eq(plan.canonical_point(far, scale), inside, "multiple circuits canonicalize")
		eq(plan.canonical_point(plan.canonical_point(far, scale), scale), inside, "canonicalization is idempotent")
	var flat := WorldPlan.generate(431, "single_continent", "cold")
	eq(flat.canonical_point(Vector2i(-99999, 99999), Chunk.SIZE), Vector2i(-99999, 99999), "the continental ocean is not wrapped")


func test_old_world_is_refused_before_any_migration() -> void:
	var path := tmp_dir().path_join("old.db")
	var store := WorldStore.new()
	check(store.open(path, {"migrations": WorldStore.MIGRATIONS.slice(0, 1)}), "an old schema")
	store.write_meta("seed", "12")
	store.write_meta("world_format", "6")
	store.close()
	var before := FileAccess.get_sha256(path)
	var content := ContentRegistry.load_packs(["res://content/base"])
	check(ServerWorld.open(path, content, {"require_planned": true}) == null, "old generation is refused")
	check(ServerWorld.open_error.contains("старый тип генерации"), "reason identifies the old generation")
	eq(FileAccess.get_sha256(path), before, "refusal does not change the old database")
	store = WorldStore.new()
	check(store.open(path, {"migrations": WorldStore.MIGRATIONS.slice(0, 1)}), "the old schema is still readable")
	eq(store.schema_version(), 1, "no migration happened")
	store.close()


func test_spawn_is_chosen_after_water_and_climate() -> void:
	for preset in ["single_continent", "small", "medium"]:
		for seed_number in [0, 19, 431, 10000]:
			var plan := WorldPlan.generate(seed_number, preset, "cold")
			var k := plan.spawn.y * plan.size.x + plan.spawn.x
			check(plan.value(0, plan.spawn) > 0.05, "spawn is inland")
			eq(plan.lake[k], 0.0, "spawn is not in a lake")
			eq(plan.river[k], 0.0, "spawn is not in a river")


func test_climate_changes_generated_biomes_and_vegetation() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var cold := WorldPlan.generate(431, "small", "cold")
	var hot := WorldPlan.generate(431, "small", "hot")
	var cold_surface := SurfaceGenerator.new(431, content, cold)
	var hot_surface := SurfaceGenerator.new(431, content, hot)
	var cold_snow := 0
	var hot_snow := 0
	var cold_desert := 0
	var hot_desert := 0
	for y in range(0, cold.size.y, 3):
		for x in range(0, cold.size.x, 3):
			var p := Vector2i(x, y)
			var h := cold.value(0, p)
			if h < 0.04 or h > 0.38:
				continue
			var a := (p - cold.spawn) * Chunk.SIZE
			var b := (p - hot.spawn) * Chunk.SIZE
			var cold_biome: String = cold_surface.biome_ids[cold_surface._biome_at(a.x, a.y, h, false)]
			var hot_biome: String = hot_surface.biome_ids[hot_surface._biome_at(b.x, b.y, h, false)]
			cold_snow += 1 if cold_biome == "base:tundra" else 0
			hot_snow += 1 if hot_biome == "base:tundra" else 0
			cold_desert += 1 if cold_biome in ["base:desert", "base:steppe"] else 0
			hot_desert += 1 if hot_biome in ["base:desert", "base:steppe"] else 0
	check(cold_snow > hot_snow, "cold climate increases snowy tundra")
	check(hot_desert > cold_desert, "hot climate increases dry biomes")
	check(content.get_def("base:tundra")["cover_density"] != content.get_def("base:steppe")["cover_density"], "these biomes carry different vegetation")


func test_preview_colors_are_the_stored_biomes_and_water() -> void:
	var plan := WorldPlan.generate(19, "small", "cold")
	var image := WorldPreview.map_image(plan)
	var land_seen := false
	var water_seen := false
	for k in plan.size.x * plan.size.y:
		var p := Vector2i(k % plan.size.x, k / plan.size.x)
		if plan.value(0, p) < 0.0:
			eq(image.get_pixel(p.x, p.y), Color("195474"), "sea color represents sea")
			water_seen = true
		elif plan.lake[k] <= 0.0 and plan.river[k] <= 0.0:
			var biome: String = plan.biome_ids[plan.biomes[k]]
			var color := Color(String(WorldPreview.BIOME_COLORS.get(biome, "7f9e69")))
			eq(image.get_pixel(p.x, p.y), color, "land color represents its stored biome")
			land_seen = true
		if land_seen and water_seen:
			break
	check(land_seen and water_seen, "preview includes land and sea")
