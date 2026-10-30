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
