extends TestCase


func test_round_trip_and_type_checks() -> void:
	var m := Protocol.decode(Protocol.encode(Protocol.REQUEST, {"request": {"type": "build"}}), true)
	eq(m.get("t"), Protocol.REQUEST)
	eq(Protocol.decode(Protocol.encode(Protocol.REQUEST, {"request": "build"}), true), {}, "wrong field type")
	eq(Protocol.decode(Protocol.encode(Protocol.SNAPSHOT, {"id": 1, "base": 0, "tick": 0, "entities": {}, "removed": [], "input_ack": 0}), true),
		{}, "a server message is not accepted from a client")
	eq(Protocol.decode(PackedByteArray([0xff, 0x00]), true), {}, "garbage")
	var big := PackedByteArray()
	big.resize(Protocol.MAX_CLIENT_MESSAGE + 1)
	eq(Protocol.decode(big, true), {}, "oversized")


func test_inputs_are_cleaned() -> void:
	var raw: Array = [[1, 0, 1, 0], [2, 5, 0, 0], ["x", 0, 0, 0], [3, -1, -1, 1], [4, 1], [5, 1, 0, 2], [6, 0, 0, 0]]
	# The last INPUT_REDUNDANCY entries are [3..6]; [4, 1] is malformed, run 2 is not a flag.
	eq(Protocol.clean_inputs(raw), [[3, -1, -1, 1], [6, 0, 0, 0]], "only the last few, only valid ones")


func test_welcome_preserves_saved_surface_recipe_and_rejects_unknown_one() -> void:
	var net := MemoryTransport.MemoryNetwork.new()
	var client := GameClient.new(net.client(), null, PackedByteArray(), null)
	var welcome := {"character_id": "a", "location": "surface", "tick": 0, "max_levels": 3, "weather_seed": 1, "surface_version": 18}
	var decoded := Protocol.decode(Protocol.encode(Protocol.WELCOME, welcome), false)
	client._on_message(decoded)
	eq(client.state, "playing", "supported legacy world is accepted")
	eq(client.surface_generation_version, 18, "saved recipe overrides the current client's default")
	welcome["surface_version"] = "18"
	eq(Protocol.decode(Protocol.encode(Protocol.WELCOME, welcome), false), {}, "surface version must be an integer")
	welcome["surface_version"] = 999
	client._on_message(Protocol.decode(Protocol.encode(Protocol.WELCOME, welcome), false))
	eq(client.state, "rejected", "unknown terrain is not sampled with a guessed recipe")
	check(client.reject_reason.contains("генератора"), "the failure is explained")


## Running: 1.5 times as far a tick, the same on both sides, never through walls.
func test_running_is_faster_and_still_stops_at_walls() -> void:
	var open := func(_x: int, _y: int) -> bool: return false
	var walk := Movement.step(Vector2i(128, 128), 1, 0, open)
	var run := Movement.step(Vector2i(128, 128), 1, 0, open, true)
	eq(walk.x - 128, Movement.WALK)
	eq(run.x - 128, Movement.RUN)
	check(absf(float(Movement.RUN) / Movement.WALK - 1.5) < 0.02, "1.5 times")
	check(absf(float(Movement.RUN_DIAGONAL) / Movement.DIAGONAL - 1.5) < 0.02, "diagonals too")
	var wall := func(x: int, _y: int) -> bool: return x == 1
	var p := Vector2i(128, 128)
	for i in 10:
		p = Movement.step(p, 1, 0, wall, true)
	eq(p.x, Movement.UNIT - Movement.HALF_X, "stopped at the wall's face")


func test_memory_network_keeps_reliable_order_under_bad_conditions() -> void:
	var net := MemoryTransport.MemoryNetwork.new()
	net.state_loss = 0.5
	net.state_duplicate = 0.5
	net.delay_steps = 2
	net.rng.seed = 3
	var server := net.server()
	var client := net.client()
	for i in 20:
		client.send(Transport.SERVER, Transport.Channel.RELIABLE, PackedByteArray([i]))
		client.send(Transport.SERVER, Transport.Channel.STATE, PackedByteArray([i]))
	var reliable: Array = []
	var state := 0
	for step in 10:
		for e in server.poll():
			if e.kind == Transport.Kind.PACKET:
				if e.channel == Transport.Channel.RELIABLE:
					reliable.append(e.data[0])
				else:
					state += 1
	eq(reliable, range(20), "reliable: all, in order")
	check(state > 0 and state != 20, "state packets lost or duplicated: %d" % state)
