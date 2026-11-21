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


func test_chunk_delta_base_gap_requests_full_snapshot_then_resumes() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	world.present["reader"] = {"location": "surface", "pos": Vector2i.ZERO}
	var chunk := Chunk.new()
	chunk.set_cell("ground", 0, 0, "base:grass")
	world._chunks["surface|0|0"] = chunk
	var net := MemoryTransport.MemoryNetwork.new()
	var wire := net.server()
	var client := GameClient.new(net.client(), null, PackedByteArray(), content)
	var server := CapturingServer.new(world, wire, null)
	var session := GameServer.Session.new()
	session.character_id = "reader"
	session.state = "playing"
	server.view_chunks = 0
	server._stream_chunks(session)
	eq(server.packets[0].type, Protocol.CHUNK)
	_receive_packet(client, server.packets.pop_front())

	chunk.set_cell("cover", 0, 0, "base:oak")
	world._changed("surface|0|0")
	server._stream_chunks(session)
	var lost: Dictionary = server.packets.pop_front()
	eq(lost.type, Protocol.CHUNK_DELTA)
	eq(lost.fields.base, 0)
	chunk.set_cell("cover", 0, 0, "base:stump")
	world._changed("surface|0|0")
	server._stream_chunks(session)
	var next: Dictionary = server.packets.pop_front()
	eq(next.type, Protocol.CHUNK_DELTA)
	eq(next.fields.base, 1)
	_receive_packet(client, next)
	eq(client.cell_at("surface", Vector2i.ZERO, "cover"), "", "gap cannot modify the cached base")
	for event: Transport.Event in wire.poll():
		if event.kind == Transport.Kind.PACKET:
			var msg := Protocol.decode(event.data, true)
			eq(msg.get("t"), Protocol.CHUNK_RESYNC)
			server._on_message(session, msg)
	server._stream_chunks(session)
	eq(server.packets[0].type, Protocol.CHUNK)
	_receive_packet(client, server.packets.pop_front())
	eq(client.cell_at("surface", Vector2i.ZERO, "cover"), "base:stump")
	_receive_packet(client, lost)
	eq(client.cell_at("surface", Vector2i.ZERO, "cover"), "base:stump", "late update is ignored")
	chunk.set_cell("cover", 0, 0, "")
	world._changed("surface|0|0")
	server._stream_chunks(session)
	_receive_packet(client, server.packets.pop_front())
	eq(client.cell_at("surface", Vector2i.ZERO, "cover"), "", "deltas continue from the restored base")


func _receive_packet(client: GameClient, packet: Dictionary) -> void:
	client._on_message(Protocol.decode(Protocol.encode(packet.type, packet.fields), false))


func test_wire_projection_reveals_ore_when_neighbor_arrives_without_loading_it() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	var cave := Levels.depth_id(-1)
	var c := Chunk.new()
	for x in [30, 31]:
		for y in [14, 15, 16]:
			c.set_cell("ground", x, y, "base:cave_floor")
			c.set_cell("structure", x, y, "base:rock")
	c.set_cell("structure", 31, 15, "base:iron_ore_rock")
	world._chunks[ServerWorld.chunk_key(cave, 0, 0)] = c
	var exposed := world.visible_chunk_update(cave, 0, 0, -1)
	var received := ChunkCodec.decode(exposed.data)
	eq(world.missed_chunks, 0, "stream projection must never load a missing edge synchronously")
	eq(received.get_cell("structure", 31, 15), "base:rock", "closed stone hides its ore")
	var edge := Chunk.new()
	edge.set_cell("ground", 0, 15, "base:cave_floor")
	var key := ServerWorld.chunk_key(cave, 1, 0)
	world._chunks[key] = edge
	world._invalidate_wire_neighbors(cave, 1, 0, key)
	var delta := world.visible_chunk_update(cave, 0, 0, exposed.rev)
	eq(delta.base, exposed.rev)
	eq(received.with_cell_values(delta.cells).get_cell("structure", 31, 15), "base:iron_ore_rock")


func test_camera_interest_streams_a_nearby_corner_and_rejects_a_stale_hint() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := TracedWorld.new(null, content, null)
	world.present["reader"] = {"location": "surface", "pos": Vector2i.ZERO}
	var server := CapturingServer.new(world, null, null)
	server.view_chunks = 0
	var session := GameServer.Session.new()
	session.character_id = "reader"
	var c := Chunk.new()
	for x in [0, 3, 5]: world._chunks["surface|%d|0" % x] = c
	server._take_input(session, {"inputs": [[2, 0, 0, 0]], "ack": 0,
		"terrain": PackedInt32Array([3, 0, 3, 1]).to_byte_array()})
	server._take_input(session, {"inputs": [[1, 0, 0, 0]], "ack": 0,
		"terrain": PackedInt32Array([-2, 0, 1, 1]).to_byte_array()})
	eq(server._camera_interest(session, Vector2i.ZERO), Rect2i(3, 0, 2, 1))
	server._stream_chunks(session)
	check((server.packets as Array).any(func(packet: Dictionary) -> bool: return packet.fields.cx == 3),
		"the visible corner outside the usual radius is streamed")
	check(not (server.packets as Array).any(func(packet: Dictionary) -> bool: return packet.fields.cx == 5),
		"the server limits camera requests to the nearby surface")
	eq(world.missed_chunks, 0, "a request cannot force a synchronous load")
	check(not world.explored("reader").get("surface", {}).has(Vector2i(3, 0)), "camera prefetch does not reveal the map")
	world.present.reader.pos = Vector2i(3 * Chunk.SIZE, 0) * Movement.UNIT
	server._stream_chunks(session)
	check(world.explored("reader").get("surface", {}).has(Vector2i(3, 0)), "the normal view reveals already streamed land on arrival")
