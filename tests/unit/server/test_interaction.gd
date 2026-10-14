extends TestCase
## Doors, things on the ground, reach.

var _worlds: Array[ServerWorld] = []
var _db := ""


func before_each() -> void:
	_db = tmp_dir().path_join("world.db")


func after_each() -> void:
	for w in _worlds:
		w.close()
	_worlds.clear()


func _world() -> ServerWorld:
	var w := ServerWorld.open(_db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 1})
	_worlds.append(w)
	return w


func _arrive(w: ServerWorld, name: String, cell: Vector2i) -> String:
	var c := PortableCharacter.create(name, "base:humanoid_adult")
	eq(w.enter("key-" + name, c), "")
	w.move_character(c.character_id, cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2))
	return c.character_id


func _req(w: ServerWorld, actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	var out := {}
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			out = ack[2]
	return out


func _walk(w: ServerWorld, id: String, dx: int, ticks: int) -> void:
	for i in ticks:
		var p: Dictionary = w.present[id]
		w.move_character(id, Movement.step(p["pos"], dx, 0, func(x: int, y: int) -> bool: return w.is_solid("surface", x, y)))


func test_door_opens_and_closes() -> void:
	var w := _world()
	var a := _arrive(w, "a", Vector2i(0, 0))
	w.grant(a, "base:plank", 4)
	eq(_req(w, a, {"type": "build", "location": "surface", "x": 2, "y": 0, "part": "base:wood_door"}), {"ok": true})
	_walk(w, a, 1, 40)
	check(w.present[a]["pos"].x < 2 * Movement.UNIT, "a closed door stops the way")
	eq(_req(w, a, {"type": "use", "location": "surface", "x": 2, "y": 0}), {"ok": true, "open": true})
	_walk(w, a, 1, 4)
	check(w.present[a]["pos"].x > 2 * Movement.UNIT, "an open door lets through")
	eq(_req(w, a, {"type": "use", "location": "surface", "x": 2, "y": 0})["reason"], "someone_there", "not on someone's head")
	_walk(w, a, 1, 10)
	eq(_req(w, a, {"type": "use", "location": "surface", "x": 2, "y": 0}), {"ok": true, "open": false})
	eq(_req(w, a, {"type": "use", "location": "surface", "x": 9, "y": 0})["reason"], "too_far")


func test_drop_and_pick_up_once() -> void:
	var w := _world()
	var a := _arrive(w, "a", Vector2i(0, 0))
	var b := _arrive(w, "b", Vector2i(1, 0))
	w.grant(a, "base:stone", 5)
	var dropped := _req(w, a, {"type": "drop", "item": "base:stone", "count": 3})
	check(dropped.get("ok", false), str(dropped))
	eq(w.inventory(a).count("base:stone"), 2)
	# Both reach for it in the same tick: one gets it.
	var r1 := {"request_id": "p1", "type": "pickup", "entity": dropped["entity"]}
	var r2 := {"request_id": "p2", "type": "pickup", "entity": dropped["entity"]}
	w.handle(b, r2)
	w.handle(a, r1)
	w.sync()
	var got := {}
	for ack: Array in w.take_acks():
		got[ack[0]] = ack[2]
	eq(got[b], {"ok": true, "item": "base:stone", "count": 3})
	eq(got[a], {"ok": false, "reason": "gone"})
	eq(w.inventory(a).count("base:stone") + w.inventory(b).count("base:stone"), 5, "nothing doubled")


func test_things_on_the_ground_survive_restart() -> void:
	var w := _world()
	var a := _arrive(w, "a", Vector2i(3, 3))
	w.grant(a, "base:log", 2)
	var dropped := _req(w, a, {"type": "drop", "item": "base:log", "count": 2})
	w.close()
	_worlds.clear()
	var w2 := _world()
	w2.chunk("surface", 0, 0)
	eq(w2.items.get(dropped["entity"], {}).get("count", 0), 2, "still lying there")
	eq(w2.items_in_chunk("surface", 0, 0), [dropped["entity"]])


func test_pickup_needs_reach() -> void:
	var w := _world()
	var a := _arrive(w, "a", Vector2i(0, 0))
	var far := _arrive(w, "far", Vector2i(6, 0))
	w.grant(a, "base:stone", 1)
	var dropped := _req(w, a, {"type": "drop", "item": "base:stone", "count": 1})
	eq(_req(w, far, {"type": "pickup", "entity": dropped["entity"]})["reason"], "too_far")


func test_clients_see_things_and_their_own_inventory() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var net := MemoryTransport.MemoryNetwork.new()
	var w := _world()
	w.starter_kit = {"base:stone": 4}
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var server := GameServer.new(w, net.server(), PlayerIdentity.load_or_create(keys + "server"))
	server.wait_for_disk = true
	var clients: Array = []
	for who: String in ["owner", "other"]:
		var key := PlayerIdentity.load_or_create(keys + who)
		var c := PortableCharacter.create(who, "base:humanoid_adult")
		c.styles = {"hair": "base:hair_short", "face": "base:face_soft", "eyes": "base:eyes_round"}
		clients.append(GameClient.new(net.client(), key, CharacterFile.export_signed(c, key, content), content))
	for i in 30:
		server.step()
		for c: GameClient in clients:
			c.step()
	var a: GameClient = clients[0]
	var b: GameClient = clients[1]
	a.request({"type": "drop", "item": "base:stone", "count": 1})
	for i in 10:
		server.step()
		for c: GameClient in clients:
			c.step()
	var seen := 0
	for id: String in b.entities:
		if b.entities[id].get("kind") == "item":
			seen += 1
	eq(seen, 1, "the other player sees the stone")
	eq(a.inventory(), {"base:stone": 3}, "own inventory arrives")
	check(not b.entities.get(a.character_id, {}).has("inventory"), "nobody else's inventory is sent")


## Atomicity by construction: the request, the inventory change and the thing
## on the ground go to the disk in one batch (one transaction).
func test_drop_and_pickup_are_one_transaction_each() -> void:
	var w := _world()
	var a := _arrive(w, "a", Vector2i(0, 0))
	w.grant(a, "base:stone", 2)
	w.sync()
	var spy := BatchSpy.new()
	w.writer.stop()
	w.writer = spy
	w.handle(a, {"request_id": "d", "type": "drop", "item": "base:stone", "count": 2})
	w.commit_async(true)
	var drop: StoreWriter.Batch = spy.batches[-1]
	check(drop.requests.size() == 1 and drop.inventories.size() == 1 and drop.items.size() == 1, "drop in one batch")
	w.poll()
	var entity: String = w.take_acks()[0][2]["entity"]
	w.handle(a, {"request_id": "p", "type": "pickup", "entity": entity})
	w.commit_async(true)
	var pick: StoreWriter.Batch = spy.batches[-1]
	check(pick.requests.size() == 1 and pick.inventories.size() == 1 and pick.removed_entities == [entity], "pickup in one batch")


class BatchSpy:
	extends StoreWriter
	var batches: Array = []
	var _finished: Array[int] = []

	func submit(batch: StoreWriter.Batch) -> int:
		batches.append(batch)
		batch.id = batches.size()
		_finished.append(batch.id)
		return batch.id

	func take_done() -> Array[int]:
		var out := _finished
		_finished = []
		return out

	func queued_operations() -> int:
		return 0

	func queued() -> int:
		return 0
