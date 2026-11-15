extends TestCase

class TracedWorld extends ServerWorld:
	var missed_chunks := 0
	func chunk(location: String, cx: int, cy: int) -> Chunk:
		var key := storage_key(location, cx, cy)
		if not _chunks.has(key):
			missed_chunks += 1
			return Chunk.new()
		return _chunks[key]
	func explored(character: String) -> Dictionary:
		return _explored.get_or_add(character, {})

class CapturingServer extends GameServer:
	var packets := []
	func _send(_session: Session, _channel: Transport.Channel, type: String, fields: Dictionary) -> void:
		packets.append({"type": type, "fields": fields})

func test_streaming_waits_for_ready_chunks_and_resumes_without_exploring_missing_land() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	world.present["reader"] = {"location": "surface", "pos": Vector2i.ZERO}
	var server := CapturingServer.new(world, null, null)
	server.view_chunks = 1
	var session := GameServer.Session.new()
	session.character_id = "reader"
	server._prefetch(session)
	server._stream_chunks(session)
	eq(world.missed_chunks, 0, "streaming must not synchronously load or generate absent chunks")
	check(session.streaming_unfinished, "the stream stays pending while the loader works")
	eq(server.packets, [], "no placeholder chunks are advertised")
	eq(world.explored("reader"), {}, "pending terrain is not explored")
	check(world.loader.waiting() > 0, "the loader was asked for the missing terrain")
	eq(world.loader._queue[0], ["surface", 0, 0], "the player's own chunk is prefetched first")
	var c := Chunk.new()
	c.set_cell("ground", 0, 0, "base:grass")
	world._chunks["surface|0|0"] = c
	server._stream_chunks(session)
	eq(world.missed_chunks, 0, "resuming the stream still avoids missing chunks")
	eq(server.packets.size(), 1, "the completed chunk is sent on the next tick")
	if not server.packets.is_empty():
		var packet: Dictionary = server.packets[0]
		eq(packet.type, Protocol.CHUNK)
		check(ChunkCodec.decode(packet.fields.data).same_as(c), "the actual completed chunk is sent")
	check(world.explored("reader").get("surface", {}).has(Vector2i.ZERO), "only a delivered chunk becomes explored")

	for cy in range(-1, 2):
		for cx in range(-1, 2): world._chunks[ServerWorld.chunk_key("surface", cx, cy)] = c
	for i in 4: server._stream_chunks(session)
	check(not session.streaming_unfinished, "the stream finishes after all requested chunks arrive")
	eq(server.packets.size(), 9, "completed chunks are sent once each")
	eq(world.missed_chunks, 0, "finishing the stream performs no fallback loads")

func test_movement_waits_for_missing_footprint_without_loading_it() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	world.present["reader"] = {"location": "surface", "pos": Vector2i(16, 16) * Movement.UNIT}
	var server := CapturingServer.new(world, null, null)
	var session := GameServer.Session.new()
	session.character_id = "reader"
	session.inputs.append([1, 1, 0, 0])
	var original: Vector2i = world.present.reader.pos
	server._apply_input(session)
	eq(world.present.reader.pos, original, "early input cannot move into unreceived terrain")
	eq(world.missed_chunks, 0, "waiting input must not force a synchronous chunk load")
	check(world.loader.waiting() > 0, "missing movement ground is requested in the background")
	world._chunks["surface|0|0"] = Chunk.new()
	check(server._movement_ready("surface", original), "normal movement can resume once the footprint is ready")
	check(server._movement_ready("surface", Vector2i(128, 128), 1, 0), "unrelated empty chunks beside a small floor do not block a valid step")

func test_environmental_needs_wait_for_ready_terrain() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	world.present["reader"] = {"location": "surface", "pos": Vector2i.ZERO}
	var needs := Needs.new(world)
	needs._last_time = 0
	world.world_time = Daylight.HOUR_MS
	var before := needs.shown("reader")
	needs.step()
	eq(world.missed_chunks, 0, "a needs tick cannot force the first terrain load")
	eq(needs.shown("reader"), before, "waiting for terrain does not charge environmental needs")
	check(world.loader.waiting() > 0, "environmental terrain is requested from the loader")
	needs.world = null

class PreparedWorld extends ServerWorld:
	func sync() -> bool:
		return true

func test_initial_prepared_view_survives_the_prejoin_unload_tick() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := PreparedWorld.new(null, content, null)
	world.creatures = CreatureSim.new(world)
	world._chunks["surface|0|0"] = Chunk.new()
	world.prepare_spawn_view(0)
	eq(world.unload_idle(GameServer.TICK_RATE * 60), 0, "preparing the view grants its ordinary idle grace before a session exists")
	check(world.has_chunk("surface", 0, 0), "tick zero does not discard prepared terrain and force loading it again")
	world.creatures.detach()
