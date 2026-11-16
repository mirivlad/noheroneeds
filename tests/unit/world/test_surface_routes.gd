extends TestCase

func test_planet_aliases_do_not_receive_phantom_settlements_or_roads() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(991, "small", "temperate", content)
	var current := SurfaceGenerator.new(991, content, plan)
	var at := Vector2i(-506, -483)
	check(PlanetTopology.new(plan).canonical_cell(at) != at, "fixture lies outside the stored longitude interval")
	check(current.is_unfit(at.x, at.y), "an unfolded copy cannot host its own settlement")
	eq(current.settlements._what(at), "deep", "road search stays inside the stored planet")
	check(current.land_at(at.x, at.y)["what"] != "deep", "the physical covering-space sampler was not turned into an artificial ocean")

func test_real_crossings_have_natural_landings_and_reserved_continuations() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for row: Array in [[2, Vector2i(-75, -453), Vector2i.RIGHT], [431, Vector2i(21, -43), Vector2i.DOWN], [991, Vector2i(-269, -128), Vector2i.DOWN]]:
		var plan := WorldPlan.generate(row[0], "small", "temperate", content)
		var generator := SurfaceGenerator.new(row[0], content, plan)
		var at: Vector2i = row[1]
		var route := generator._bridge_data(at.x, at.y, row[2])
		if not check(route["accepted"], "a useful crossing remains on seed %d" % row[0]): continue
		for path: Array in route["paths"]:
			for cell: Vector2i in path:
				eq(generator.land_at(cell.x, cell.y, false)["what"], "land", "trail uses natural land, not an approach cut for another bridge")
				check(generator.is_unfit(cell.x, cell.y), "generated buildings leave this route open")
				check(generator._trail_cells(Vector2i(cell.x >> 5, cell.y >> 5)).has(cell), "the continuation is discoverable from its own chunk")

func test_old_forced_approach_does_not_turn_into_a_cut_without_a_bridge() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var old := SurfaceGenerator.new(431, content, plan, 19)
	var current := SurfaceGenerator.new(431, content, plan)
	var found := false
	# A former bridge into a small rock pocket near the spawn.
	for y in range(-48, -34):
		for x in range(-58, -52):
			if old._chasm_kind(x, y) != SurfaceGenerator.APPROACH: continue
			var h := old.height_at(x, y)
			if not old.is_cliff(x, y, h): continue
			if old.land_at(x, y)["what"] != "land": continue
			found = true
			eq(current.land_at(x, y)["what"], "rock", "the natural cliff remains instead of a three-cell slit")
	check(found, "the fixed fixture includes a former forced approach")

func test_route_data_does_not_depend_on_neighbour_chunk_query_order() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var a := SurfaceGenerator.new(431, content, plan)
	var b := SurfaceGenerator.new(431, content, plan)
	var chunks := [Vector2i(0, -2), Vector2i(0, -1), Vector2i(1, -2)]
	var first := {}
	for at: Vector2i in chunks: first[at] = a._trail_cells(at).duplicate()
	chunks.reverse()
	for at: Vector2i in chunks: eq(b._trail_cells(at), first[at], "trail data is present even when the landing chunk is queried first")
	var descriptions := a.bridge_routes_touching(0, -2)
	if not check(not descriptions.is_empty(), "this chunk has a useful bridge"): return
	descriptions[0]["accepted"] = false
	check(a.bridge_routes_touching(0, -2)[0]["accepted"], "callers cannot corrupt cached route data")

func test_generated_approaches_stay_walkable_and_do_not_depend_on_chunk_order() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var first := SurfaceGenerator.new(431, content, plan)
	var route := first._bridge_data(21, -43, Vector2i.DOWN)
	if not check(route["accepted"], "the known useful crossing remains"): return
	var required := {}
	var chunks := {}
	for path: Array in route["paths"]:
		for at: Vector2i in path:
			required[at] = true
			chunks[Vector2i(at.x >> 5, at.y >> 5)] = true
	var made := {}
	for at: Vector2i in chunks: made[at] = first.generate(at.x, at.y)
	var marked := 0
	for at: Vector2i in required:
		var chunk: Chunk = made[Vector2i(at.x >> 5, at.y >> 5)]
		check(not Terrain.is_solid(chunk, at.x & 31, at.y & 31, content), "actual stamped approach stays walkable at " + str(at))
		eq(chunk.get_cell("cover", at.x & 31, at.y & 31), "", "the path has no resource blocking it")
		if chunk.get_cell("ground", at.x & 31, at.y & 31) == "base:dirt": marked += 1
	check(marked >= BridgeRoutes.MIN_TRAIL * 2, "both trails are visible on generated ground")
	var reverse := chunks.keys()
	reverse.reverse()
	var other := SurfaceGenerator.new(431, content, plan)
	for at: Vector2i in reverse:
		eq(Hash.sha256(ChunkCodec.encode(other.generate(at.x, at.y))), Hash.sha256(ChunkCodec.encode(made[at])), "full chunk bytes agree in the reverse order")
