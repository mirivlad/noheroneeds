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
	var c := PortableCharacter.create(name, "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
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


func test_bandit_colours_equipment_and_escort_contract_reach_two_clients() -> void:
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(35, [a, b])
	var near := Movement.cell_of(_server_pos(a))
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var looks := CreatureSim.villager_looks(rng)
	looks["colors"]["shirt"] = Bandits.SHIRT
	var bandit := world.creatures._spawn("base:bandit", "surface", near + Vector2i(5, 0), looks, 7)
	# An inactive fixture camp keeps this protocol test separate from combat.
	bandit.job = {"camp": "network-fixture", "name": "Разбойник"}
	world.combat.equip_creature(bandit, "base:bow")
	var trader := world.creatures._spawn("base:villager", "surface", near + Vector2i(1, 0), CreatureSim.villager_looks(rng), 8)
	var s := world.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var road: Dictionary = s.roads_of(0, district.x, district.y)[0]
	trader.job = {"profession": "base:trader", "name": "Гордей", "purse": 500, "from": road["from"], "toward": road["to"]}
	trader.route = {"road": road["key"], "step": 1}
	world.creatures._schedule(trader, world.tick + 10000)  # protocol fixture stays within conversation reach
	world.caravans.hire(trader, 30)
	_run(35, [a, b])
	for client: GameClient in [a, b]:
		var seen: Dictionary = client.entities.get(bandit.id, {})
		eq(seen.get("appearance", {}).get("colors", {}).get("shirt"), Bandits.SHIRT, "red shirt reaches both observers")
		eq(seen.get("held"), "base:bow", "the actual weapon, not a fixed sword")
		for id: String in world.caravans.guards(trader):
			var guard: Dictionary = client.entities.get(id, {})
			eq(guard.get("appearance", {}).get("worn", {}).get("headwear"), "base:iron_helmet")
	var hired := a.request({"type": "escort_hire", "creature": trader.id})
	_run(35, [a, b])
	check(a.results.get(hired, {}).get("ok", false), "hire through the actual request/ack protocol")
	var journal := a.request({"type": "journal"})
	_run(30, [a, b])
	eq(a.results.get(journal, {}).get("escorts", [{}])[0].get("state"), "active")
	world.combat.hurt(bandit.id, 1000, "")
	_run(35, [a, b])
	check(not a.entities.has(bandit.id) and not b.entities.has(bandit.id), "both clients see the same death")


func test_inn_services_and_competing_rentals_reach_two_clients() -> void:
	server.shutdown()
	world.close()
	db = tmp_dir().path_join("inn-world.db")
	world = ServerWorld.open(db, content, {"seed": 431})
	net = MemoryTransport.MemoryNetwork.new()
	server = GameServer.new(world, net.server(), _key("server"))
	server.wait_for_disk = true
	var s := world.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var p: Dictionary = s.inns.of_cluster(0, district.x, district.y).filter(func(site: Dictionary) -> bool: return site["site"] == "inn")[0]
	var at: Vector2i = p["host"]
	world.chunk("surface", at.x >> 5, at.y >> 5)
	var host := world.creatures.get_creature(String(world.hospitality.state(String(p["id"]))["host"]))
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(35, [a, b])
	for client: GameClient in [a, b]:
		world.move_character(client.character_id, host.pos + Vector2i(0, 512))
		world.grant(client.character_id, "base:coin", 60)
	_run(35, [a, b])
	var ra := a.request({"type": "inn_service", "creature": host.id, "service": "bed", "choice": "0"})
	var rb := b.request({"type": "inn_service", "creature": host.id, "service": "bed", "choice": "0"})
	_run(40, [a, b])
	var won_a: bool = a.results.get(ra, {}).get("ok", false)
	var won_b: bool = b.results.get(rb, {}).get("ok", false)
	check(won_a != won_b, "exactly one simultaneous renter succeeds")
	var winner := a if won_a else b
	var loser := b if won_a else a
	eq(loser.results.get(rb if won_a else ra, {}).get("reason"), "bed_rented")
	eq(int(winner.inventory().get("base:coin", 0)), 54, "the winner sees the actual payment")
	eq(int(loser.inventory().get("base:coin", 0)), 60, "the losing client keeps its money")
	world.needs.set_satiety(winner.character_id, 10)
	var meal := winner.request({"type": "inn_service", "creature": host.id, "service": "meal", "choice": "bread"})
	_run(40, [a, b])
	check(winner.results.get(meal, {}).get("ok", false), "meal through the normal request protocol")
	check(int(winner.own.get("needs", {}).get("satiety", 0)) >= 49, "fed state is replicated")
	eq(int(winner.inventory().get("base:coin", 0)), 51)
	eq(int(winner.inventory().get("base:bread", 0)), 0)


func test_animal_growth_and_hunger_reach_the_client() -> void:
	var a := _client("owner", _character("Аня"))
	_run(30, [a])
	var c := world.creatures._spawn("base:chicken", "surface", Movement.cell_of(_server_pos(a)) + Vector2i.RIGHT, {}, 5)
	c.owner = a.character_id
	world.creatures.life.offspring(c)
	# No pasture in this hunger-replication fixture.
	for y in range(c.home.y - 12, c.home.y + 13):
		for x in range(c.home.x - 12, c.home.x + 13):
			var ch := world.chunk("surface", x >> 5, y >> 5)
			ch.set_cell("ground", x & 31, y & 31, "base:sand")
			ch.set_cell("cover", x & 31, y & 31, "")
			world._changed(ServerWorld.chunk_key("surface", x >> 5, y >> 5))
	_run(30, [a])
	if not check(a.entities.has(c.id), "the chick reached the player"):
		return
	eq(a.entities[c.id].get("young"), true, "a chick, not an adult")
	eq(a.entities[c.id].get("hungry"), false)
	world.world_time += 25 * Daylight.HOUR_MS
	_run(30, [a])
	eq(a.entities[c.id].get("hungry"), true, "hunger also changes the existing replica")
	world.creatures.fed_by(c, a.character_id)
	world.world_time += 23 * Daylight.HOUR_MS
	_run(30, [a])
	eq(a.entities[c.id].get("young"), false, "the same creature grew into an adult")
	eq(a.entities[c.id].get("hungry"), false, "feeding removed the warning")


func test_equipment_reaches_owner_and_observer_under_packet_loss() -> void:
	net.state_loss = 0.3
	net.state_duplicate = 0.2
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(35, [a, b])
	world.grant(a.character_id, "base:felt_hat", 1)
	_run(20, [a, b])
	var rid := a.request({"type": "equip", "item": "base:felt_hat"})
	_run(40, [a, b])
	check(a.results.get(rid, {}).get("ok", false), "durable result reached the owner")
	eq(a.inventory().get("base:felt_hat", 0), 0, "hat removed from the bag")
	eq(a.own["appearance"]["worn"]["headwear"], "base:felt_hat")
	eq(b.entities[a.character_id]["appearance"]["worn"]["headwear"], "base:felt_hat", "others see the new layer")
	a.request({"type": "unequip", "slot": "headwear"})
	_run(40, [a, b])
	eq(a.inventory().get("base:felt_hat", 0), 1)
	check(not b.entities[a.character_id]["appearance"]["worn"].has("headwear"), "removal also converges")


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
	hare.next_think = 1 << 40  # it does only what the test tells it (else it may run from the player)
	_run(40, [a])
	var seen: Dictionary = a.entities.get(hare.id, {})
	eq(seen.get("creature"), "base:hare", "the hare came")
	# It walks off; the client follows it to where it stops.
	hare.target = (me + Vector2i(10, 6)) * Movement.UNIT
	world.creatures._movers[hare.id] = true
	for i in 120:
		_run(1, [a])
		hare.next_think = 1 << 40  # arrived, it would think again soon: not here
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


## ADR-0015 through the network: one in the street sees one on a walkway on
## a wall, not one behind a wall up there; one at a window upstairs sees the
## street, and not from the room beside it.
func test_seen_across_levels_from_walkways_and_windows() -> void:
	for y in range(-7, 7):
		for x in range(-4, 5):
			var c := world.chunk("surface", floori(x / 32.0), floori(y / 32.0))
			c.set_cell("ground", posmod(x, 32), posmod(y, 32), "base:grass")
			c.set_cell("cover", posmod(x, 32), posmod(y, 32), "")
	world.grant("builder", "base:plank", 200)
	var level := ""
	for x in range(-2, 3):
		world.handle("builder", {"request_id": "w%d" % x, "type": "build", "location": "surface", "x": x, "y": -4, "part": "base:wood_wall"})
		world.handle("builder", {"request_id": "c%d" % x, "type": "build", "location": "surface", "x": x, "y": -4, "part": "base:wood_ceiling"})
		world.handle("builder", {"request_id": "d%d" % x, "type": "build", "location": "surface", "x": x, "y": -5, "part": "base:wood_ceiling"})
	world.sync()
	level = world.levels.level(world._ceiling_building("surface", 0, -4), 1)
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(30, [a, b])
	world.move_character(a.character_id, Vector2i(128, 4 * 256 + 128))
	world.present[b.character_id]["location"] = level
	world.move_character(b.character_id, Vector2i(128, -4 * 256 + 128))
	world.relocated[b.character_id] = true
	_run(30, [a, b])
	eq(b.z, 1, "up on the walkway")
	eq(a.entities.get(b.character_id, {}).get("z"), 1, "the street sees the one on the walkway, up there")
	eq(b.entities.get(a.character_id, {}).get("z"), 0, "and the walkway sees the street")
	# Walls up there, a window in the middle facing the street.
	world.move_character(b.character_id, Vector2i(128, -5 * 256 + 128))
	for x in range(-2, 3):
		world.handle("builder", {"request_id": "u%d" % x, "type": "build", "location": level, "x": x, "y": -4,
			"part": "base:wood_window" if x == 0 else "base:wood_wall", "facing": "s"})
	world.sync()
	var hare := world.creatures._spawn("base:hare", "surface", Vector2i(0, 3), {}, 1)
	hare.next_think = 1 << 40  # it stays (else it runs from the one in the street)
	world.world_time = 12 * Daylight.HOUR_MS
	_run(30, [a, b])
	check(b.entities.has(hare.id), "at the window: the hare in the street")
	check(b.entities.has(a.character_id), "and the one in the street")
	world.move_character(b.character_id, Vector2i(256 + 128, -5 * 256 + 128))
	_run(30, [a, b])
	check(not b.entities.has(hare.id), "beside the window, behind the wall: no hare")
	check(not a.entities.has(b.character_id), "nor is that one seen from the street")


## ADR-0019 through the network: health comes to clients (own and others'),
## an arrow is seen flying, a blow is a request like any other.
func test_health_and_arrows_reach_clients() -> void:
	var a := _client("owner", _character("Аня"))
	_run(30, [a])
	world.grant(a.character_id, "base:bow", 1)
	world.grant(a.character_id, "base:arrow", 3)
	var me := Movement.cell_of(_server_pos(a))
	# A villager stands to look at one who comes close (a deer would run).
	var deer := world.creatures._spawn("base:villager", "surface", me + Vector2i(1, 0), {"body_plan": "base:human_m"}, 3)
	_run(10, [a])
	eq(a.entities.get(deer.id, {}).get("health"), 15, "a creature's health")
	eq(a.own.get("health"), 20, "and one's own")
	deer.pos = _server_pos(a) + Vector2i(200, 0)  # within reach of bare hands
	a.request({"type": "attack", "item": "", "x": deer.pos.x, "y": deer.pos.y})
	_run(10, [a])
	eq(a.entities.get(deer.id, {}).get("health"), 14, "a blow with bare hands is seen")
	world.combat.hurt(a.character_id, 4, "")
	_run(5, [a])
	eq(a.own.get("health"), 16, "being hurt is seen")
	var aim := _server_pos(a) + Vector2i(0, 10 * 256)
	a.hold("base:bow")  # into the hands first, then the shot: in order
	a.request({"type": "attack", "item": "base:bow", "x": aim.x, "y": aim.y})
	var seen := false
	for i in 12:
		_run(1, [a])
		for id: String in a.entities:
			seen = seen or a.entities[id].get("kind") == "projectile"
	check(seen, "the arrow was seen flying")


## ADR-0020: what a character has seen is kept in the world; after a restart
## the client is told it, and gets the map tiles of far chunks it asks for
## (and nothing it has not seen).
func test_the_map_of_what_was_seen_survives_a_restart() -> void:
	var c := _character("Аня")
	var a := _client("owner", c)
	_run(40, [a])
	var seen: Dictionary = world.explored(a.character_id).get("surface", {})
	check(seen.size() >= 9, "the chunks round it were seen: %d" % seen.size())
	check(a.map_tiles.has("surface|0|0"), "the client made tiles of what it got")
	world.move_character(a.character_id, Vector2i(200 * 32 * 256, 0))  # far away
	_run(40, [a])
	_restart()
	var b := _client("owner", c)
	_run(30, [b])
	var known: Dictionary = b.map_known.get("surface", {}).get("chunks", {})
	check(known.has(Vector2i(0, 0)), "told what it had seen near the start")
	check(not b.map_tiles.has("surface|0|0"), "not sent until asked")
	b.request_map("surface", [Vector2i(0, 0), Vector2i(50, 50)])
	_run(5, [b])
	var tile: Dictionary = b.map_tiles.get("surface|0|0", {})
	eq((tile.get("cells", PackedByteArray()) as PackedByteArray).size(), Chunk.CELLS, "the tile came")
	check(not b.map_tiles.has("surface|50|50"), "nothing unseen")


## ADR-0021 through the network: the other player sees what is really in the
## hands (and empty hands once it is dropped); taking a thing and using it at
## once works (requests keep their order); after a reconnect the hands are told
## again before anything else.
func test_what_is_held_through_the_network() -> void:
	var a := _client("owner", _character("Аня"))
	var b := _client("other", _character("Боря"))
	_run(30, [a, b])
	world.grant(a.character_id, "base:bow", 1)
	world.grant(a.character_id, "base:axe", 1)
	_run(5, [a, b])
	a.hold("base:bow")
	_run(10, [a, b])
	eq(b.entities.get(a.character_id, {}).get("held"), "base:bow", "the other sees the bow")
	a.request({"type": "drop", "item": "base:bow", "count": 1})
	_run(10, [a, b])
	eq(b.entities.get(a.character_id, {}).get("held"), "", "and empty hands once it is dropped")
	# A tree beside it, the axe taken and swung in the same tick.
	var me := Movement.cell_of(_server_pos(a)) + Vector2i(1, 0)
	var c := world.chunk("surface", floori(me.x / 32.0), floori(me.y / 32.0))
	c.set_cell("cover", posmod(me.x, 32), posmod(me.y, 32), "base:oak")
	a.hold("base:axe")
	b.world_events.clear()
	var rid := a.request({"type": "gather", "location": "surface", "x": me.x, "y": me.y, "layer": "cover", "item": "base:axe"})
	_run(10, [a, b])
	eq(a.results.get(rid, {}).get("ok"), true, "taken and used at once: %s" % a.results.get(rid))
	eq(b.entities.get(a.character_id, {}).get("held"), "base:axe")
	var swings := b.world_events.filter(func(e: Dictionary) -> bool: return e["type"] == "swing")
	eq(swings.size(), 1, "the other sees the blow struck")
	if not swings.is_empty():
		eq(swings[0]["id"], a.character_id)
		eq(swings[0]["octant"], 0, "toward the tree, east")
		eq(swings[0]["part"], "base:axe", "with the axe (its sound)")
	net.cut(a.transport.own_id())
	_run(5, [a, b])
	a.reconnect(net.client())
	_run(30, [a, b])
	eq(world.held_of(a.character_id), "base:axe", "after a reconnect the hands are told again")
	eq(b.entities.get(a.character_id, {}).get("held"), "base:axe", "and seen")


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


func test_a_password_or_the_worlds_link_lets_in() -> void:
	server.password = "дуб"
	var old_invite := server.new_invite()
	var stranger := _client("owner", _character("Аня"))
	_run(10, [stranger])
	eq([stranger.state, stranger.reject_reason], ["rejected", "password"], "without the password, not in")
	var wrong := _client("owner", _character("Вика"))
	wrong.password = "берёза"
	_run(10, [wrong])
	eq(wrong.state, "rejected", "a wrong one, not in")
	var guest := _client("owner", _character("Вера"))
	guest.password = "дуб"
	_run(20, [guest])
	eq(guest.state, "playing", guest.reject_reason)
	# A share link's invite lets in instead of the password; a new one voids it.
	var friend := _client("other", _character("Оля"))
	friend.invite = old_invite
	_run(20, [friend, guest])
	eq(friend.state, "playing", friend.reject_reason)
	server.new_invite()
	var late := _client("other", _character("Ира"))
	late.invite = old_invite
	_run(10, [late, friend, guest])
	eq(late.state, "rejected", "an old link no longer lets in")
	eq(HostedGame.parse_link("nhn://192.168.1.5:24680/abc123"), {"address": "192.168.1.5", "port": 24680, "invite": "abc123"})
	eq(HostedGame.parse_link("192.168.1.5:24680"), {}, "an address is not a link")
	eq(Protocol.reason_text("password"), "неверный пароль, или ссылка на мир устарела")


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


func test_planned_world_reaches_client_and_3d_geography() -> void:
	server.shutdown()
	world.close()
	var plan := WorldPlan.generate(431, "small", "cold")
	db = tmp_dir().path_join("planned.db")
	world = ServerWorld.open(db, content, {"world_plan": plan.to_dict()})
	net = MemoryTransport.MemoryNetwork.new()
	server = GameServer.new(world, net.server(), _key("server"))
	server.wait_for_disk = true
	var client := _client("owner", _character("Аня"))
	_run(30, [client])
	eq(client.state, "playing", client.reject_reason)
	check(client.geography is PlannedGeography, "the client uses the saved world plan")
	if client.geography is PlannedGeography:
		eq((client.geography as PlannedGeography).plan.to_dict(), plan.to_dict(), "the network carries exactly the saved plan")
		var point := Vector2i(200, -300)
		eq(client.geography.climate_at(point.x, point.y), world.generator.geography.climate_at(point.x, point.y), "client and server have the same climate")

## A planet's seam through the network: walking across it does not jump, the
## chunks on the other side come, and what stands there is next to one.
func test_walking_across_the_seam_of_a_planet() -> void:
	server.shutdown()
	world.close()
	var plan := WorldPlan.generate(431, "small", "temperate")
	db = tmp_dir().path_join("planet-seam.db")
	world = ServerWorld.open(db, content, {"world_plan": plan.to_dict()})
	net = MemoryTransport.MemoryNetwork.new()
	server = GameServer.new(world, net.server(), _key("server"))
	server.wait_for_disk = true
	var a := _client("owner", _character("Аня"))
	_run(30, [a])
	eq(a.state, "playing", a.reject_reason)
	# Three cells east of the western edge of the map, on open grass.
	var west := -plan.spawn.x * Chunk.SIZE
	var east := west + plan.size.x * Chunk.SIZE - 1
	for y in range(-6, 7):
		for x in range(west - 8, west + 3):
			var c := world.chunk("surface", floori(float(x) / Chunk.SIZE), floori(float(y) / Chunk.SIZE))
			c.set_cell("ground", posmod(x, Chunk.SIZE), posmod(y, Chunk.SIZE), "base:grass")
			c.set_cell("cover", posmod(x, Chunk.SIZE), posmod(y, Chunk.SIZE), "")
	for y in range(-6, 7):
		for x in range(east - 2, east + 9):
			var c := world.chunk("surface", floori(float(x) / Chunk.SIZE), floori(float(y) / Chunk.SIZE))
			c.set_cell("ground", posmod(x, Chunk.SIZE), posmod(y, Chunk.SIZE), "base:grass")
			c.set_cell("cover", posmod(x, Chunk.SIZE), posmod(y, Chunk.SIZE), "")
	for x in range(west - 7, west + 3):
		for y in range(-6, 7):
			world._changed(ServerWorld.chunk_key("surface", floori(float(x) / Chunk.SIZE), floori(float(y) / Chunk.SIZE)))
	world.move_character(a.character_id, Vector2i((west + 2) * Movement.UNIT + Movement.HALF_X, Movement.HALF_Y))
	_run(30, [a])
	eq(a.position, _server_pos(a), "placed at the west edge")
	# A hare on the far side of the seam, a step east of the player.
	var hare := world.creatures._spawn("base:hare", "surface", Vector2i(east - 1, 0), {}, 2)
	hare.next_think = 1 << 40
	_run(30, [a])
	check(a.entities.has(hare.id), "a hare a step east of the west edge is seen")
	if a.entities.has(hare.id):
		check(Vector2i(int(a.entities[hare.id]["x"]), int(a.entities[hare.id]["y"])).distance_to(a.position) < 4 * Movement.UNIT,
			"and drawn next to us, not a world away: %s vs %s" % [a.entities[hare.id], a.position])
	var before := a.position
	a.move = Vector2i(-1, 0)
	_run(40, [a])
	a.move = Vector2i.ZERO
	_run(30, [a])
	eq(a.position, _server_pos(a), "the client and the server agree after crossing")
	check(a.position.x < before.x and before.x - a.position.x <= 40 * Movement.RUN, "walked west smoothly, no jump of a world: %s -> %s" % [before, a.position])
	check(Movement.cell_of(a.position).x < west, "and past the western edge of the map, into the next lap of it: %s" % [Movement.cell_of(a.position)])
	check(not a.chunks.is_empty(), "the ground across the seam was streamed")
	check(a.corrections <= 1, "no rubber-banding at the seam: %d" % a.corrections)
