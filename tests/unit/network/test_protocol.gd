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
	var raw: Array = [[1, 0, 1], [2, 5, 0], ["x", 0, 0], [3, -1, -1], [4, 1], [5, 1, 0], [6, 0, 0]]
	# The last INPUT_REDUNDANCY entries are [3..6]; [4, 1] is malformed.
	eq(Protocol.clean_inputs(raw), [[3, -1, -1], [5, 1, 0], [6, 0, 0]], "only the last few, only valid ones")


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
