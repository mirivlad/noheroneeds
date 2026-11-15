extends TestCase

class TracedWorld extends ServerWorld:
	var missed_chunks := 0
	func chunk(location: String, cx: int, cy: int) -> Chunk:
		var key := storage_key(location, cx, cy)
		if not _chunks.has(key):
			missed_chunks += 1
			return Chunk.new()
		return _chunks[key]

class Shore extends SurfaceGenerator:
	var samples := {}
	func land_at(_x: int, y: int, _bridges := true) -> Dictionary:
		var at := Vector2i(_x, y)
		samples[at] = int(samples.get(at, 0)) + 1
		return {"what": "water" if y == 0 else "land", "height": .1, "biome": 0}

func test_fishers_and_door_searches_never_load_missing_chunks() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	world.generator = Shore.new(4, content)
	var sim := CreatureSim.new(world)
	check(not sim._by_water(Vector2i(1, 1)), "an unloaded bank is not a usable fishing spot")
	check(not sim._door("surface", Vector2i(1, 1)), "an unloaded cell is not an openable door")
	eq(world.missed_chunks, 0, "neither query may start chunk generation")
	var c := Chunk.new()
	c.set_cell("ground", 1, 1, "base:grass")
	c.set_cell("structure", 3, 3, "base:wood_door")
	world._chunks["surface|0|0"] = c
	check(sim._by_water(Vector2i(1, 1)), "the loaded shore can be used normally")
	check(sim._door("surface", Vector2i(3, 3)), "real loaded doors remain openable")
	var dweller := Creature.new()
	dweller.location = "surface"
	dweller.pos = Vector2i(16, 16) * Movement.UNIT
	eq(sim._route(dweller, Vector2i(40, 16)), [], "a path cannot extend through missing terrain")
	eq(world.missed_chunks, 0, "route searches must not load missing door cells either")
	sim.detach()


func _reference_shore(sim: CreatureSim, from: Vector2i, nth: int) -> Vector2i:
	var found: Array[Vector2i] = []
	for r in range(1, 70):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r: continue
				var at := from + Vector2i(dx, dy)
				if sim._by_water(at): found.append(at)
		if found.size() > nth * 3: return found[(nth * 3) % found.size()]
	return found[0] if not found.is_empty() else Creature.NO_TARGET

func test_fishing_spot_order_is_preserved_and_geometry_is_sampled_once() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	var shore := Shore.new(4, content)
	world.generator = shore
	for cy in range(-1, 2):
		for cx in range(-1, 2): world._chunks[ServerWorld.chunk_key("surface", cx, cy)] = Chunk.new()
	var sim := CreatureSim.new(world)
	for nth in [0, 1, 4]:
		var expected := _reference_shore(sim, Vector2i(16, 16), nth)
		shore.samples.clear()
		eq(sim._water_spot(Vector2i(16, 16), nth), expected, "same nearest bank and per-fisher ordering")
		check(shore.samples.values().all(func(n: int) -> bool: return n == 1), "one geometry lookup per cell in a search")
	eq(world.missed_chunks, 0, "searching for fishing spots never loads additional chunks")
	sim.detach()

class CountedDetours extends CreatureSim:
	var searches := 0
	func _find_caravan_route(c: Creature, goal: Vector2i, margin: int) -> Array[Vector2i]:
		searches += 1
		return super._find_caravan_route(c, goal, margin)

func test_failed_caravan_detours_retry_only_after_their_inputs_change() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	var sim := CountedDetours.new(world)
	var trader := Creature.new()
	trader.id = "blocked-cart"
	trader.kind = "base:villager"
	trader.location = "surface"
	trader.pos = Vector2i(16, 16) * Movement.UNIT + Vector2i(128, 128)
	var goal := Vector2i(20, 16)
	eq(sim._caravan_route(trader, goal), [], "missing terrain has no route")
	eq(sim._caravan_route(trader, goal), [], "same blocked detour stays blocked")
	eq(sim.searches, 1, "an unchanged failed search is reused")
	sim._caravan_route(trader, goal, 16)
	eq(sim.searches, 2, "a wider search is distinct")
	var chunk := Chunk.new()
	world._chunks["surface|0|0"] = chunk
	world.chunks_epoch += 1
	check(not sim._caravan_route(trader, goal).is_empty(), "newly loaded land makes a path available")
	eq(sim.searches, 3, "loading invalidates the failed result")
	for y in 32: chunk.set_cell("structure", 18, y, "base:wood_wall")
	world._changed("surface|0|0")
	eq(sim._caravan_route(trader, goal), [], "a new full barrier blocks the path")
	sim._caravan_route(trader, goal)
	eq(sim.searches, 4, "new blocked terrain is searched once")
	world._chunks["surface|20|20"] = Chunk.new()
	world.chunks_epoch += 1
	world._changed("surface|20|20")
	sim._caravan_route(trader, goal)
	eq(sim.searches, 4, "loading or changing distant terrain does not repeat the local search")
	world._chunks.erase("surface|20|20")
	world.chunks_epoch += 1
	sim._caravan_route(trader, goal)
	eq(sim.searches, 4, "unloading distant terrain does not repeat the local search")
	chunk.set_cell("structure", 18, 16, "")
	world._changed("surface|0|0")
	check(not sim._caravan_route(trader, goal).is_empty(), "opening the wall invalidates the failure")
	eq(sim.searches, 5, "building and demolition retry immediately")
	eq(world.missed_chunks, 0, "detours never generate surrounding terrain")
	sim.detach()
