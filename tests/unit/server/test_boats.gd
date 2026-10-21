extends TestCase
## ADR-0052: a raft made by hand, a boat at a workbench; put on the water,
## got into, rowed by the one at the helm with the others sitting; out onto
## the shore; worn by the way; taken back from the water.

var w: ServerWorld
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 5})
	before_each_ground()


func after_each() -> void:
	w.close()


func _player(x := 5) -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, Vector2i(x * 256 + 128, 8 * 256 + 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func test_a_raft_is_made_by_hand_from_logs_and_cord() -> void:
	w.knowledge.never_fail = true
	var a := _player()
	w.grant(a, "base:log", 6)
	w.grant(a, "base:cord", 4)
	check(w.knowledge.knows(a, "base:make_raft"), "everyone knows how")
	check(_req(a, {"type": "craft", "recipe": "base:make_raft", "count": 1}).get("ok", false), "made without a workbench")
	eq(w.inventory(a).count("base:raft"), 1)
	check(not w.knowledge.knows(a, "base:make_boat"), "a boat is learnt (from a fisher)")


func test_launch_board_row_land_and_take_back() -> void:
	var a := _player()
	var b := _player(4)
	var c := _player(3)
	w.grant(a, "base:boat", 1)
	eq(_req(b, {"type": "launch", "item": "base:boat"}).get("reason"), "not_enough", "only one's own")
	var far := _player(30)
	w.grant(far, "base:raft", 1)
	w.move_character(far, Vector2i(70 * 256 + 128, 8 * 256 + 128))
	eq(_req(far, {"type": "launch", "item": "base:raft"}).get("reason"), "no_water", "no water next to one")
	var put := _req(a, {"type": "launch", "item": "base:boat", "x": 6, "y": 8})
	check(put.get("ok", false), "on the water: %s" % put)
	var boat := String(put["entity"])
	eq(w.inventory(a).count("base:boat"), 0, "out of the bag")
	eq(Movement.cell_of(Vector2i(w.items[boat]["x"], w.items[boat]["y"])), Vector2i(6, 8), "next to one, where one pointed")
	# In: the first at the helm; the second sits; there are two seats.
	eq(_req(a, {"type": "board", "entity": boat}), {"ok": true, "helm": true})
	check(w.boats.at_helm(a) and not w.in_water(a), "at the helm, not swimming")
	eq(_req(b, {"type": "board", "entity": boat}), {"ok": true, "helm": false})
	w.move_character(c, Vector2i(5 * 256 + 128, 9 * 256 + 128))
	eq(_req(c, {"type": "board", "entity": boat}).get("reason"), "no_seat")
	eq(_req(c, {"type": "pickup", "entity": boat}).get("reason"), "crewed", "not taken from under them")
	# Rowed: over water only; all in it go along.
	check(w.boats.blocks_boat("surface", 5, 8) and not w.boats.blocks_boat("surface", 30, 8), "land keeps a boat out")
	var to := Vector2i(50 * 256 + 128, 8 * 256 + 128)
	var at := Vector2i(w.items[boat]["x"], w.items[boat]["y"])
	while at.x < to.x:
		at = Movement.step_at(at, 1, 0, func(x: int, y: int) -> bool: return w.boats.blocks_boat("surface", x, y),
			w.boats.speed_of(a))
		w.boats.row(a, at)
	eq(Movement.cell_of(w.present[b]["pos"]), Movement.cell_of(to), "the one sitting came along")
	eq(Movement.cell_of(Vector2i(w.items[boat]["x"], w.items[boat]["y"])), Movement.cell_of(to), "and the boat")
	check(Wear.spent((w.items[boat]["states"] as Array)[0]) >= 1, "worn by the way: %s" % w.items[boat].get("states"))
	w.boats.row(b, to + Vector2i(256, 0))
	eq(Movement.cell_of(w.present[b]["pos"]), Movement.cell_of(to), "one sitting does not row")
	# Out, onto the shore: none here, all water round.
	eq(_req(b, {"type": "land"}).get("reason"), "no_shore")
	for i in 400:
		at = Movement.step_at(at, 1, 0, func(x: int, y: int) -> bool: return w.boats.blocks_boat("surface", x, y), w.boats.speed_of(a))
		w.boats.row(a, at)
	eq(Movement.cell_of(at).x, 59, "a boat stops at the shore")
	check(_req(b, {"type": "land", "x": 60, "y": 8}).get("ok", false), "the one sitting steps ashore")
	eq(Movement.cell_of(w.present[b]["pos"]), Vector2i(60, 8))
	check(w.boats.aboard(b) == "" and w.boats.at_helm(a), "the other still rows")
	check(_req(a, {"type": "land", "x": 60, "y": 9}).get("ok", false), "and steps ashore too")
	check(not w.boats.crews.has(boat) and w.items.has(boat), "the boat stays, empty, where it was")
	# Taken back with its wear.
	var worn: Dictionary = (w.items[boat]["states"] as Array)[0]
	check(_req(a, {"type": "pickup", "entity": boat}).get("ok", false), "pulled out and taken")
	eq(w.inventory(a).state_of("base:boat", 0), worn, "its wear kept")


func test_leaving_the_game_or_drifting_off_leaves_the_boat() -> void:
	var a := _player()
	var b := _player(4)
	w.grant(a, "base:raft", 1)
	var boat := String(_req(a, {"type": "launch", "item": "base:raft", "x": 6, "y": 8})["entity"])
	check(_req(a, {"type": "board", "entity": boat}).get("ok", false), "on the raft")
	eq(_req(b, {"type": "board", "entity": boat}).get("reason"), "no_seat", "a raft holds one")
	w.leave(a)
	check(not w.boats.crews.has(boat), "left the game: out of it")
	var again := _player()
	check(_req(again, {"type": "board", "entity": boat}).get("ok", false), "another gets on")
	w.move_character(again, Vector2i(1 * 256, 8 * 256))  # carried off some other way
	w.boats.check()
	eq(w.boats.aboard(again), "", "far from it: no longer on it")


## Through the network: the client rows as the server does (no corrections),
## others see the boat move.
func test_rowing_through_the_network() -> void:
	w.close()
	var net := MemoryTransport.MemoryNetwork.new()
	w = ServerWorld.open(tmp_dir().path_join("net.db"), _content, {"seed": 5})
	before_each_ground()
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var server := GameServer.new(w, net.server(), PlayerIdentity.load_or_create(keys + "server"))
	server.wait_for_disk = true
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var ch := PortableCharacter.create("Аня", "base:human_m")
	ch.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var client := GameClient.new(net.client(), owner, CharacterFile.export_signed(ch, owner, _content), _content)
	for i in 40:
		server.step()
		client.step()
	if not check(client.state == "playing", client.reject_reason):
		return
	var id := client.character_id
	w.move_character(id, Vector2i(5 * 256 + 128, 8 * 256 + 128))
	w.grant(id, "base:boat", 1)
	for i in 10:
		server.step()
		client.step()
	client.request({"type": "launch", "item": "base:boat", "x": 6, "y": 8})
	for i in 10:
		server.step()
		client.step()
	var boat := ""
	for e: String in client.entities:
		if String(client.entities[e].get("item", "")) == "base:boat":
			boat = e
	if not check(boat != "", "the boat is seen on the water"):
		return
	client.request({"type": "board", "entity": boat})
	for i in 10:
		server.step()
		client.step()
	check(client.aboard() == boat and bool(client.own.get("helm", false)), "the client knows it is at the helm")
	var corrections := client.corrections
	var x0 := client.position.x
	client.move = Vector2i(1, 0)
	for i in 100:
		server.step()
		client.step()
	client.move = Vector2i.ZERO
	for i in 10:
		server.step()
		client.step()
	var rowed := client.position.x - x0
	check(rowed > 90 * 60, "rowed faster than walking: %d units in 100 ticks" % rowed)
	eq(client.corrections - corrections, 0, "the client rowed as the server did")
	eq(Movement.cell_of(Vector2i(client.entities[boat]["x"], client.entities[boat]["y"])), Movement.cell_of(client.position), "the boat came along")


## Grass to x 5, then water; dry land again from x 60.
func before_each_ground() -> void:
	for cx in 3:
		var c := w.chunk("surface", cx, 0)
		for y in Chunk.SIZE:
			for x in Chunk.SIZE:
				var gx := cx * Chunk.SIZE + x
				c.set_cell("ground", x, y, "base:water" if gx >= 6 and gx < 60 else "base:grass")
				c.set_cell("cover", x, y, "")
				c.set_cell("structure", x, y, "")
		for id: String in w.creatures.in_chunk("surface", cx, 0):
			w.creatures.remove(id)
