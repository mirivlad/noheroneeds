class_name PlannedGeography
extends Geography
## Geography backed only by a saved global plan, with no GeoRegion creation.

var plan: WorldPlan


func _init(source: WorldPlan) -> void:
	plan = source
	world_seed = plan.seed_value
	origin = plan.spawn * STEP


func point_value(field: int, gi: int, gj: int) -> float:
	return plan.value(field, Vector2i(gi, gj))


func sample(field: int, x: int, y: int) -> float:
	return plan.sample(field, Vector2i(x, y))


func climate_at(x: int, y: int) -> Vector2:
	return Vector2(sample(WARMTH, x, y), sample(RAIN, x, y))


func lake_level_at(x: int, y: int) -> float:
	return plan.lake_level_at(Vector2i(x, y))


func rivers_near(cx: int, cy: int) -> Array:
	var result: Array = []
	var center := Vector2i(cx, cy) + plan.spawn
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var p := center + Vector2i(dx, dy)
			var k := WorldHydrology.index_at(plan, p)
			if k < 0 or plan.river[k] <= 0.0 or plan.downstream[k] < 0:
				continue
			var delta := Vector2i.ZERO
			for direction: Vector2i in WorldHydrology.DIRECTIONS:
				if WorldHydrology.index_at(plan, p + direction) == plan.downstream[k]:
					delta = direction
					break
			if delta == Vector2i.ZERO:
				continue
			var a := Vector2((p - plan.spawn) * STEP)
			var b := a + Vector2(delta * STEP)
			var other := plan.river[plan.downstream[k]]
			var width := plan.river[k]
			var ford := width <= GeoRegion.FORD_WIDEST and absi(hash([world_seed, k, "ford"])) % 100 < GeoRegion.FORD_SHARE
			result.append([a, b, width, other if other > 0.0 else width, ford])
	return result
