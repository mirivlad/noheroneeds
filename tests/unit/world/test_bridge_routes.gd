extends TestCase

func _barrier(x: int, _y: int) -> Dictionary:
	return {"what": "chasm" if x >= 0 and x <= 3 else "land"}

func test_crossing_joins_regions_and_trails_continue_both_sides() -> void:
	var route := BridgeRoutes.plan(Vector2i.ZERO, Vector2i(3, 0), Vector2i.RIGHT, _barrier)
	check(route["accepted"], "a crossing over a long chasm opens two useful regions")
	if not route["accepted"]: return
	for i in 2:
		var path: Array = route["paths"][i]
		check(path.size() >= BridgeRoutes.MIN_TRAIL, "a trail continues well beyond the landing")
		check(path.size() <= BridgeRoutes.MAX_TRAIL + 1, "the local approach has a bounded length")
		check(route["regions"][i] >= BridgeRoutes.MIN_REGION, "the far side is explorable")
		eq(path[0], Vector2i(-1, 0) if i == 0 else Vector2i(4, 0), "trail begins at the true landing")
		for at: Vector2i in path: eq(_barrier(at.x, at.y)["what"], "land", "trail uses actual dry land")
		for n in range(1, path.size()):
			var delta: Vector2i = path[n] - path[n - 1]
			check(absi(delta.x) <= 1 and absi(delta.y) <= 1 and delta != Vector2i.ZERO, "trail has no gaps")

func test_nearby_dry_detour_makes_a_bridge_unnecessary() -> void:
	var land := func(x: int, y: int) -> Dictionary: return {"what": "chasm" if x >= 0 and x <= 3 and absi(y) <= 2 else "land"}
	var route := BridgeRoutes.plan(Vector2i.ZERO, Vector2i(3, 0), Vector2i.RIGHT, land)
	check(not route["accepted"], "walking round a short cut is more natural")
	eq(route["reason"], "nearby-land", "the rejected bridge has a concrete reason")
	check(route["detour_steps"] <= 18, "the ordinary route is genuinely nearby")

func test_three_dry_cells_leading_into_a_pocket_are_not_a_route() -> void:
	var land := func(x: int, y: int) -> Dictionary:
		return {"what": "land" if x >= 4 or (x >= -3 and x <= -1 and absi(y) <= 1) else "rock"}
	var route := BridgeRoutes.plan(Vector2i.ZERO, Vector2i(3, 0), Vector2i.RIGHT, land)
	check(not route["accepted"], "a landing and three dry cells do not justify a bridge")
	eq(route["reason"], "no-connected-region")

func test_diagonally_touching_pockets_cannot_fake_a_connected_region() -> void:
	var land := func(x: int, y: int) -> Dictionary:
		return {"what": "land" if x >= 4 or (x < 0 and posmod(x + y, 2) == 1) else "rock"}
	var route := BridgeRoutes.plan(Vector2i.ZERO, Vector2i(3, 0), Vector2i.RIGHT, land)
	check(not route["accepted"], "a trail cannot squeeze diagonally between rock cells")
	eq(route["reason"], "no-connected-region")

func test_work_is_bounded_and_unrelated_queries_do_not_change_the_plan() -> void:
	var calls := [0]
	var land := func(x: int, y: int) -> Dictionary:
		calls[0] += 1
		return _barrier(x, y)
	var first := BridgeRoutes.plan(Vector2i.ZERO, Vector2i(3, 0), Vector2i.RIGHT, land)
	check(calls[0] < 4000, "route work is bounded, including rejected detours")
	BridgeRoutes.plan(Vector2i(10000, -9000), Vector2i(10003, -9000), Vector2i.RIGHT, _barrier)
	eq(BridgeRoutes.plan(Vector2i.ZERO, Vector2i(3, 0), Vector2i.RIGHT, _barrier), first, "the same land gives the same trails in any order")

func test_an_unbounded_span_is_refused_before_searching() -> void:
	var calls := [0]
	var land := func(_x: int, _y: int) -> Dictionary:
		calls[0] += 1
		return {"what": "land"}
	var result := BridgeRoutes.plan(Vector2i.ZERO, Vector2i(10000, 0), Vector2i.RIGHT, land)
	check(not result["accepted"] and result["reason"] == "span", "only bounded crossings enter the search")
	check(calls[0] <= 2, "an invalid span does not scan the map")
