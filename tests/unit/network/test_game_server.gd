extends TestCase
## Server and clients over the in-memory network: joining, movement and
## prediction, snapshots under loss, requests, reconnects, persistence.

static var _keys := {}
var net: MemoryTransport.MemoryNetwork
var world: ServerWorld
var server: GameServer
var content: ContentRegistry
var db := ""


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	db = tmp_dir().path_join("world.db")
	_start()


func after_each() -> void:
	world.close()


func _start() -> void:
	net = MemoryTransport.MemoryNetwork.new()
	net.rng.seed = 11
	world = ServerWorld.open(db, content)
	server = GameServer.new(world, net.server(), _key("server"))


func _restart() -> void:
	server.shutdown()
	world.close()
	_start()


func _key(who: String) -> PlayerIdentity:
	if not _keys.has(who):
		_keys[who] = PlayerIdentity.load_or_create(ProjectSettings.globalize_path("user://test_keys/" + who))
	return _keys[who]


func _character(name: String, planks := 0) -> PortableCharacter:
	var c := PortableCharacter.create(name, "base:humanoid_adult")
	c.styles = {"hair": "base:hair_short", "face": "base:face_soft", "eyes": "base:eyes_round"}
	if planks > 0:
		c.inventory.add("base:plank", planks)
	return c


func _client(who: String, c: PortableCharacter, signer := "") -> GameClient:
	var file := CharacterFile.export_signed(c, _key(signer if signer != "" else who), content)
	return GameClient.new(net.client(), _key(who), file, content)


func _run(ticks: int, clients: Array) -> void:
	for i in ticks:
		server.step()
		for c: GameClient in clients:
			c.step()


func _server_pos(c: GameClient) -> Vector2i:
	return world.present[c.character_id]["pos"]


func test_two_players_join_and_see_each_other() -> void:
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(30, [a, b])
	eq(a.state, "playing", a.reject_reason)
	eq(b.state, "playing", b.reject_reason)
	check(a.entities.has(b.character_id) and b.entities.has(a.character_id), "each sees the other")
	eq(a.entities[b.character_id]["name"], "Боря")
	check(a.chunks.size() >= 9, "ground around arrived: %d chunks" % a.chunks.size())


func test_prediction_matches_the_server() -> void:
	net.delay_steps = 3
	var a := _client("owner", _character("Аня"))
	_run(20, [a])
	a.move = Vector2i(1, 1)
	_run(40, [a])
	a.move = Vector2i(-1, 0)
	_run(25, [a])
	a.move = Vector2i.ZERO
	_run(15, [a])
	eq(a.position, _server_pos(a), "same place")
	check(_server_pos(a) != Vector2i.ZERO, "moved")
	eq(a.corrections, 0, "no rubber-banding on a clean network")


func test_walls_stop_both_sides_alike() -> void:
	# A wall three cells to the right of the spawn point.
	world.grant("builder", "base:plank", 3)
	world.handle("builder", {"request_id": "w", "type": "build", "location": "surface", "x": 3, "y": 0, "part": "base:wood_wall"})
	world.sync()
	var a := _client("owner", _character("Аня"))
	_run(20, [a])
	a.move = Vector2i(1, 0)
	_run(60, [a])
	eq(_server_pos(a).x, 3 * Movement.UNIT - Movement.HALF_X, "stopped at the wall")
	eq(a.position, _server_pos(a))
	eq(a.corrections, 0)


func test_snapshots_converge_on_a_bad_network() -> void:
	net.state_loss = 0.3
	net.state_duplicate = 0.2
	net.delay_steps = 2
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(30, [a, b])
	var dirs := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(1, -1)]
	for d: Vector2i in dirs:
		a.move = d
		_run(15, [a, b])
	a.move = Vector2i.ZERO
	_run(30, [a, b])
	eq(a.position, _server_pos(a), "own position settles on the server's")
	var seen: Dictionary = b.entities.get(a.character_id, {})
	eq(Vector2i(seen.get("x", 0), seen.get("y", 0)), _server_pos(a), "the other player sees it too")


func test_request_result_after_commit_and_seen_by_others() -> void:
	var a := _client("owner", _character("Аня", 10))
	var b := _client("other", _character("Боря"))
	_run(30, [a, b])
	var rid := a.request({"type": "build", "location": "surface", "x": 2, "y": 2, "part": "base:wood_wall"})
	# Resent by a confused client: still one wall.
	a.transport.send(Transport.SERVER, Transport.Channel.RELIABLE, Protocol.encode(Protocol.REQUEST, {"request": a._requests[rid]}))
	_run(20, [a, b])
	eq(a.results.get(rid), {"ok": true})
	eq(world.inventory(a.character_id).count("base:plank"), 7, "paid once")
	var c: Chunk = b.chunks.get(ServerWorld.chunk_key("surface", 0, 0))
	eq(c.get_cell("structure", 2, 2) if c else "", "base:wood_wall", "the other player's ground shows the wall")


func test_reconnect_resends_and_applies_once() -> void:
	var a := _client("owner", _character("Аня", 10))
	_run(30, [a])
	a.move = Vector2i(0, 1)
	_run(10, [a])
	a.move = Vector2i.ZERO
	_run(5, [a])
	var place := _server_pos(a)
	var rid := a.request({"type": "build", "location": "surface", "x": -2, "y": -2, "part": "base:wood_wall"})
	server.step()  # the server takes the request...
	net.cut(a.transport.own_id())  # ...and the connection drops before the result
	_run(5, [a])
	eq(a.state, "disconnected")
	a.reconnect(net.client())
	_run(30, [a])
	eq(a.state, "playing", a.reject_reason)
	eq(a.results.get(rid), {"ok": true}, "answered after the reconnect")
	eq(world.inventory(a.character_id).count("base:plank"), 7, "built once")
	eq(_server_pos(a), place, "back where it was")
	eq(a.unanswered_requests(), 0)


func test_world_keeps_its_own_copy_of_a_known_character() -> void:
	var c := _character("Аня", 10)
	var a := _client("owner", c)
	_run(30, [a])
	a.request({"type": "build", "location": "surface", "x": 1, "y": -3, "part": "base:wood_wall"})
	_run(10, [a])
	a.transport.close()
	_run(5, [a])
	# The same old file (still 10 planks) does not refill the world's inventory.
	var again := _client("owner", c)
	_run(30, [again])
	eq(again.state, "playing", again.reject_reason)
	eq(world.inventory(c.character_id).count("base:plank"), 7)


func test_position_survives_a_server_restart() -> void:
	var c := _character("Аня")
	var a := _client("owner", c)
	_run(30, [a])
	a.move = Vector2i(-1, 1)
	_run(20, [a])
	a.move = Vector2i.ZERO
	_run(5, [a])
	var place := _server_pos(a)
	_restart()
	var back := _client("owner", c)
	_run(30, [back])
	eq(back.state, "playing", back.reject_reason)
	eq(_server_pos(back), place)
	eq(back.position, place)


func test_refusals() -> void:
	# Another key presents this character file: it is signed by "owner".
	var stolen := _client("other", _character("Аня"), "owner")
	_run(10, [stolen])
	eq(stolen.state, "rejected")
	check(stolen.reject_reason.contains("another key"), stolen.reject_reason)
	# A character the world already knows, re-signed by someone else.
	var c := _character("Аня")
	var a := _client("owner", c)
	_run(20, [a])
	a.transport.close()
	_run(5, [a])
	var thief := _client("other", c)
	_run(20, [thief])
	eq(thief.state, "rejected")
	eq(thief.reject_reason, "not_owner")
	# Different content.
	var odd := _client("owner", _character("Вера"))
	odd.content = ContentRegistry.from_defs([{"id": "test:x", "kind": "item"}])
	_run(10, [odd])
	eq(odd.state, "rejected")
	check(odd.reject_reason.contains("content"), odd.reject_reason)


func test_wrong_protocol_version_is_refused() -> void:
	var t := net.client()
	_run(2, [])
	t.send(Transport.SERVER, Transport.Channel.RELIABLE, Protocol.encode(Protocol.HELLO,
		{"v": Protocol.VERSION + 1, "content": content.fingerprint(), "key_alg": PlayerIdentity.KEY_ALG, "public_key": _key("owner").public_pem()}))
	_run(3, [])
	var got := ""
	for e in t.poll():
		if e.kind == Transport.Kind.PACKET:
			got = String(Protocol.decode(e.data, false).get("reason", ""))
	check(got.begins_with("protocol"), got)
	eq(server.session_count(), 0)
