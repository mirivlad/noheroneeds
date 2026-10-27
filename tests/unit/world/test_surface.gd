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
	var found := 0
	for ky in range(-30, 31):
		for kx in range(-30, 31):
			for d: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE, Vector2i(1, -1)]:
				if found >= 6:
					break
				var a := g._chasm_site(Vector2i(kx, ky))
				var b := g._chasm_site(Vector2i(kx, ky) + d)
				var mid := Vector2i(((a + b) * 0.5).floor())
				if g.land_at(mid.x, mid.y)["what"] != "bridge":
					continue
				found += 1
				var way := Vector2i.RIGHT if absf(b.x - a.x) >= absf(b.y - a.y) else Vector2i.DOWN
				var side := Vector2i(way.y, way.x)
				var start := mid
				while g.land_at(start.x - way.x, start.y - way.y)["what"] == "bridge":
					start -= way
				var span := 0
				var at := start
				while g.land_at(at.x, at.y)["what"] == "bridge":
					span += 1
					at += way
				check(span >= 2 and span <= 8, "a bridge %s spans the chasm: %d cells" % [mid, span])
				eq(g.land_at(at.x, at.y)["what"], "land", "land at its far end %s" % at)
				eq(g.land_at(start.x - way.x, start.y - way.y)["what"], "land", "and at its near end")
				var beside := [String(g.land_at(mid.x + side.x, mid.y + side.y)["what"]), String(g.land_at(mid.x - side.x, mid.y - side.y)["what"])]
				check("chasm" in beside, "the chasm beside it at %s: %s" % [mid, beside])
				check(g.bridge_sag(mid.x, mid.y) > 0.0, "it sags in its middle")
	check(found > 0, "there are hanging bridges in the rugged land")
	var chunk := Chunk.new()
	chunk.set_cell("ground", 0, 0, "base:chasm")
	chunk.set_cell("ground", 1, 0, "base:hanging_bridge")
	check(Terrain.is_solid(chunk, 0, 0, c) and not Terrain.is_solid(chunk, 1, 0, c), "a chasm stops one, its bridge does not")
