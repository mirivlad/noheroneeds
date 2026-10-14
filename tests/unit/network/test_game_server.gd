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
	server.wait_for_disk = true


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
	a.run = true  # running is predicted exactly too
	a.move = Vector2i(0, -1)
	_run(25, [a])
	a.run = false
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


## Creatures (ADR-0018) reach clients, follow them on a bad network, and go
## from them when they leave memory or the player goes away and comes back.
func test_creatures_reach_clients_and_follow_them_on_a_bad_network() -> void:
	net.state_loss = 0.3
	net.state_duplicate = 0.2
	net.delay_steps = 2
	var a := _client("owner", _character("Аня"))
	_run(30, [a])
	var me := Movement.cell_of(_server_pos(a))
	var hare := world.creatures._spawn("base:hare", "surface", me + Vector2i(4, 2), {}, 1)
	_run(40, [a])
	var seen: Dictionary = a.entities.get(hare.id, {})
	eq(seen.get("creature"), "base:hare", "the hare came")
	# It walks off; the client follows it to where it stops.
	hare.target = (me + Vector2i(10, 6)) * Movement.UNIT
	world.creatures._movers[hare.id] = true
	_run(120, [a])
	eq(hare.target, Creature.NO_TARGET, "it got there")
	seen = a.entities.get(hare.id, {})
	eq(Vector2i(seen.get("x", 0), seen.get("y", 0)), hare.pos, "the client has it where it stopped")
	# The player goes far away and comes back: the hare goes and comes again.
	var home := _server_pos(a)
	world.move_character(a.character_id, home + Vector2i(200, 0) * Movement.UNIT)
	_run(60, [a])
	check(not a.entities.has(hare.id), "out of view: gone from the client")
	world.move_character(a.character_id, home)
	_run(60, [a])
	seen = a.entities.get(hare.id, {})
	eq(Vector2i(seen.get("x", 0), seen.get("y", 0)), hare.pos, "back in view, where it is")
	eq(seen.get("creature"), "base:hare", "whole again")
	# It leaves memory with its chunk: gone from the client too.
	world.creatures.drop_chunk(world.creatures._chunk_of(hare))
	_run(40, [a])
	check(not a.entities.has(hare.id), "left memory: gone from the client")


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
	# A texture pack and a translation on the client side are no obstacle (ADR-0009).
	var dressed := _client("owner", _character("Вика"))
	var reskinned := ContentRegistry.load_packs(["res://content/base"])
	reskinned.get_def("base:oak")["name"] = "Oak"
	reskinned.visuals["base:oak"] = {"mode": "flat"}
	dressed.content = reskinned
	_run(20, [dressed])
	eq(dressed.state, "playing", dressed.reject_reason)
	# Different rules.
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


## What changes in the world reaches every client as news (for sounds):
## another player's building, taking down, a door opening and closing.
func test_world_changes_reach_others_as_events() -> void:
	var a := _client("owner", _character("Аня", 10))
	var b := _client("other", _character("Боря"))
	_run(30, [a, b])
	b.world_events.clear()
	a.request({"type": "build", "location": "surface", "x": 1, "y": 1, "part": "base:wood_door"})
	_run(10, [a, b])
	a.move = Vector2i(1, 1)  # up to the door
	_run(4, [a, b])
	a.move = Vector2i.ZERO
	a.request({"type": "use", "location": "surface", "x": 1, "y": 1})
	_run(10, [a, b])
	a.request({"type": "use", "location": "surface", "x": 1, "y": 1})
	_run(10, [a, b])
	a.request({"type": "dismantle", "location": "surface", "x": 1, "y": 1})
	_run(10, [a, b])
	var types := []
	for e: Dictionary in b.world_events:
		if e["cell"] == Vector2i(1, 1):
			types.append(e["type"])
	eq(types, ["build", "open", "close", "dismantle"], "in order, once each")
	eq(b.world_events[0]["part"], "base:wood_door")
