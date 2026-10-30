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
