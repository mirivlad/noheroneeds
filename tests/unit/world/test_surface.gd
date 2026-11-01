extends TestCase
## Surface generation: determinism, generate-once persistence, biomes as
## data, and walking across chunks with the ground arriving ahead (GDD sc. 4).

static var _keys := {}


func _base() -> ContentRegistry:
	return ContentRegistry.load_packs(["res://content/base"])


## A plain world without water or obstacles: only grass, from data alone.
func _plain() -> ContentRegistry:
	return ContentRegistry.from_defs([
		{"id": "test:grass", "kind": "ground"}, {"id": "test:pond", "kind": "ground", "solid": true},
		{"id": "test:flower", "kind": "plant"},
		{"id": "test:lawn", "kind": "biome", "ground": {"test:grass": 1}, "cover": {"test:flower": 1}, "cover_density": 0.1},
		{"id": "test:body", "kind": "body_plan", "directions": 8, "slots": ["body"], "appearance_slots": ["hair"], "colors": ["skin"]},
		{"id": "test:hair", "kind": "style", "slot": "hair", "body_plans": ["test:body"]},
	])


func _same(a: Chunk, b: Chunk) -> bool:
	return ChunkCodec.encode(a) == ChunkCodec.encode(b)


func test_same_seed_same_world() -> void:
	var c := _base()
	var a := SurfaceGenerator.new(42, c)
	var b := SurfaceGenerator.new(42, c)
	var other := SurfaceGenerator.new(43, c)
	check(_same(a.generate(3, -2), b.generate(3, -2)), "deterministic")
	check(not _same(a.generate(3, -2), other.generate(3, -2)), "another seed, another world")
	eq(a.generate(0, 0).meta, {"gen": SurfaceGenerator.ID, "gen_version": SurfaceGenerator.VERSION})


func test_spawn_clearing_and_solid_terrain() -> void:
	var c := _base()
	var g := SurfaceGenerator.new(7, c)
	var chunks := {}
	for cy in [-1, 0]:
		for cx in [-1, 0]:
			chunks[Vector2i(cx, cy)] = g.generate(cx, cy)
	for y in range(-8, 9):
		for x in range(-8, 9):
			var k := Vector2i(floori(x / 32.0), floori(y / 32.0))
			check(not Terrain.is_solid(chunks[k], x - k.x * 32, y - k.y * 32, c), "spawn clearing free at %d,%d" % [x, y])
	# Somewhere in a wider area there is water and there are trees, and both block.
	var water := 0
	var trees := 0
	for cy in range(-3, 3):
		for cx in range(-3, 3):
			var ch := g.generate(cx, cy)
			water += ch.layer_ids("ground").count("base:water")
			for id in ch.layer_ids("cover"):
				if c.get_def(id).get("solid", false):
					trees += 1
	check(water > 0 and trees > 0, "water %d, solid plants %d" % [water, trees])


func _solids(c: Chunk, content: ContentRegistry) -> int:
	var count := 0
	for id in c.layer_ids("cover"):
		if content.get_def(id).get("solid", false):
			count += 1
	return count


func _solid_at(c: Chunk, x: int, y: int, content: ContentRegistry) -> bool:
	return bool(content.get_def(c.get_cell("cover", x, y)).get("solid", false))


func test_woods_have_glades_and_a_way_through() -> void:
	# A wood must stay a wood, but not a wall: glades, trails, and a way the
	# mouse's auto path finds without a search limit.
	var content := _base()
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	var surface := SurfaceGenerator.new(plan.seed_value, content, plan)
	var chunks := {}
	var densest := Vector2i.ZERO
	var most := -1
	for cy in range(-5, 6):
		for cx in range(-5, 6):
			var c := surface.generate(cx, cy)
			chunks[Vector2i(cx, cy)] = c
			var trees := _solids(c, content)
			if trees > most:
				most = trees
				densest = Vector2i(cx, cy)
	check(most > 20, "there is a wood near the spawn: %d solid plants" % most)
	check(most < 130, "no chunk is a solid wall of wood: %d solid plants" % most)
	var wood: Chunk = chunks[densest]
	var open := 0
	for y in range(0, Chunk.SIZE, 8):
		for x in range(0, Chunk.SIZE, 8):
			var count := 0
			for ly in 8:
				for lx in 8:
					count += 1 if _solid_at(wood, x + lx, y + ly, content) else 0
			open += 1 if count <= 2 else 0
	check(open >= 4, "the wood has open glades: %d of 16 windows" % open)
	# The way is searched only inside the wood, so it cannot simply go round.
	var at := densest * Chunk.SIZE
	var row := -1
	for r in Chunk.SIZE:
		if not _solid_at(wood, 0, r, content) and not _solid_at(wood, Chunk.SIZE - 1, r, content):
			row = r
			break
	check(row >= 0, "the wood has an open row")
	if row < 0:
		return
	var solid := func(x: int, y: int) -> bool:
		if x < at.x or y < at.y or x >= at.x + Chunk.SIZE or y >= at.y + Chunk.SIZE:
			return true
		return _solid_at(wood, x - at.x, y - at.y, content)
	var from := Vector2i(at.x, at.y + row)
	var to := Vector2i(at.x + Chunk.SIZE - 1, at.y + row)
	var way := ClickOrders.find(from, func(c: Vector2i) -> bool: return c == to, to, solid)
	check(not way.is_empty(), "the auto path crosses the wood: %d cells" % way.size())


func test_biomes_are_data() -> void:
	var g := SurfaceGenerator.new(1, _plain())
	var ids := {}
	for cy in range(-2, 2):
		for cx in range(-2, 2):
			var ch := g.generate(cx, cy)
			for layer in ["ground", "cover"]:
				for id in ch.layer_ids(layer):
					ids[id] = true
	var seen: Array = ids.keys()
	seen.sort()
	eq(seen, ["", "test:flower", "test:grass"], "only what the content describes")


func test_generated_once_then_kept_through_generator_changes() -> void:
	var db := tmp_dir().path_join("world.db")
	var w := ServerWorld.open(db, _base(), {"seed": 99})
	var first := ChunkCodec.encode(w.chunk("surface", 3, 3))
	w.handle("nobody", {"request_id": "x", "type": "noop"})
	w.close()
	# A later build changes the generator: here, the same world with another seed.
	var w2 := ServerWorld.open(db, _base())
	eq(w2.world_seed, 99, "the seed belongs to the world")
	w2.generator = SurfaceGenerator.new(12345, _base())
	eq(ChunkCodec.encode(w2.chunk("surface", 3, 3)), first, "a visited chunk is not regenerated")
	check(not _same(w2.chunk("surface", 9, 9), SurfaceGenerator.new(99, _base()).generate(9, 9)), "new places come from the new generator")
	w2.close()


func test_loader_thread_brings_and_persists_chunks() -> void:
	var db := tmp_dir().path_join("world.db")
	var w := ServerWorld.open(db, _base(), {"seed": 5})
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			w.prefetch("surface", cx, cy)
	var deadline := Time.get_ticks_msec() + 10000
	while w.loader.waiting() > 0 and Time.get_ticks_msec() < deadline:
		OS.delay_msec(5)
	OS.delay_msec(20)
	w.poll_loaded()
	eq(w.sync_loads, 0, "nothing loaded on the simulation thread")
	check(w.has_chunk("surface", 3, -3) and w.has_chunk("surface", -3, 3), "all 49 arrived")
	var made := SurfaceGenerator.new(5, _base()).generate(2, 2)
	made.meta["fauna"] = CreatureSim.FAUNA_VERSION  # the ground as generated; its animals came once (ADR-0018)
	var expected := ChunkCodec.encode(made)
	w.close()
	var s := WorldStore.new()
	s.open(db)
	eq(s.count_chunks(), 49, "generated chunks are stored")
	eq(s.get_chunk("surface", 2, 2), expected)
	s.close()


## GDD scenario 4: crossing chunk borders without a loading screen. The
## client always has the ground under it and ahead, the server never stalls
## on a chunk, and the walk never stops.
func test_walk_across_chunks_seamlessly() -> void:
	var content := _plain()
	var net := MemoryTransport.MemoryNetwork.new()
	var world := ServerWorld.open(tmp_dir().path_join("world.db"), content, {"seed": 3})
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var server := GameServer.new(world, net.server(), PlayerIdentity.load_or_create(keys + "server"))
	server.wait_for_disk = true
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var c := PortableCharacter.create("Аня", "test:body")
	c.styles = {"hair": "test:hair"}
	var file := CharacterFile.export_signed(c, owner, content)
	var client := GameClient.new(net.client(), owner, file, content)
	for i in 40:
		server.step()
		client.step()
	if not check(client.state == "playing", client.reject_reason):
		world.close()
		return
	var loads_before := world.sync_loads
	client.move = Vector2i(1, 0)
	var last_x := client.position.x
	var stalls := 0
	var missing := 0
	for i in 500:  # about 100 cells: three chunk borders
		server.step()
		client.step()
		var cell := Movement.cell_of(client.position)
		for ahead in [0, 8]:
			var k := ServerWorld.chunk_key("surface", floori((cell.x + ahead) / 32.0), floori(cell.y / 32.0))
			if not client.chunks.has(k):
				missing += 1
		if client.position.x <= last_x:
			stalls += 1
		last_x = client.position.x
	check(client.position.x > 96 * Movement.UNIT, "walked past three borders: %d" % (client.position.x / Movement.UNIT))
	eq(stalls, 0, "never stopped")
	eq(missing, 0, "ground always there before the player")
	eq(world.sync_loads - loads_before, 0, "the server never waited for a chunk")
	world.close()


## Hanging bridges (ADR-0064): each found goes from land over a chasm to land,
## with the chasm beside it; a chasm cell is not walked, a bridge's is.
func test_chasms_have_hanging_bridges() -> void:
	var c := _base()
	var g := SurfaceGenerator.new(431, c)
	var spans := 0
	var seen := {}
	for ky in range(-30, 31):
		for kx in range(-30, 31):
			for d: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE, Vector2i(1, -1)]:
				if spans >= 10:
					break
				var a := g._chasm_site(Vector2i(kx, ky))
				var b := g._chasm_site(Vector2i(kx, ky) + d)
				var mid := Vector2i(((a + b) * 0.5).floor())
				if seen.has(mid) or g.land_at(mid.x, mid.y)["what"] != "bridge":
					continue
				var way := Vector2i.RIGHT if absf(b.x - a.x) >= absf(b.y - a.y) else Vector2i.DOWN
				var side := Vector2i(way.y, way.x)
				var start := mid
				var guard := 0
				while g.land_at(start.x - way.x, start.y - way.y)["what"] == "bridge" and guard < 32:
					start -= way
					guard += 1
				var span := 0
				var at := start
				while g.land_at(at.x, at.y)["what"] == "bridge" and guard < 32:
					seen[at] = true
					span += 1
					at += way
					guard += 1
				if span < 2:
					continue
				spans += 1
				check(span >= 2 and span <= 8, "a bridge %s spans the chasm: %d cells" % [mid, span])
				# A bridge is a crossing, never a deck in the middle of nowhere:
				# both ends stand on walkable land and the chasm runs beside it.
				eq(g.land_at(at.x, at.y)["what"], "land", "land at its far end %s" % at)
				eq(g.land_at(start.x - way.x, start.y - way.y)["what"], "land", "and at its near end")
				eq(g.land_at(start.x - way.x, start.y - way.y, false)["what"], "land", "the near end is land, not another deck")
				var beside := false
				var on := start
				while true:
					beside = beside or g.land_at(on.x + side.x, on.y + side.y)["what"] == "chasm" \
						or g.land_at(on.x - side.x, on.y - side.y)["what"] == "chasm"
					if on == at - way:
						break
					on += way
				check(beside, "the chasm runs beside the bridge at %s" % mid)
				check(g.bridge_sag(mid.x, mid.y) > 0.0, "it sags in its middle")
	check(spans > 0, "there are hanging bridges in the rugged land")
	# A bridge whose row leaves the chasm at a shore, over open air, or with no
	# land beyond is no crossing, and none is made (it stays a chasm).
	var bridges := 0
	var crossings := 0
	for y in range(-300, 300, 3):
		for x in range(-300, 300, 3):
			if g.land_at(x, y)["what"] != "bridge":
				continue
			bridges += 1
			var axis: Vector2i = g._chasm_cut(x, y)[2]
			var low := Vector2i(x, y)
			var high := Vector2i(x, y)
			for i in 32:
				if g.land_at(low.x - axis.x, low.y - axis.y)["what"] != "bridge":
					break
				low -= axis
			for i in 32:
				if g.land_at(high.x + axis.x, high.y + axis.y)["what"] != "bridge":
					break
				high += axis
			var near := low - axis
			var far := high + axis
			if g.land_at(near.x, near.y)["what"] == "land" and g.land_at(far.x, far.y)["what"] == "land":
				crossings += 1
	check(bridges == 0 or crossings == bridges, "every deck joins land at both ends: %d of %d" % [crossings, bridges])
	var chunk := Chunk.new()
	chunk.set_cell("ground", 0, 0, "base:chasm")
	chunk.set_cell("ground", 1, 0, "base:hanging_bridge")
	check(Terrain.is_solid(chunk, 0, 0, c) and not Terrain.is_solid(chunk, 1, 0, c), "a chasm stops one, its bridge does not")
