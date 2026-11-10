extends TestCase

var w: ServerWorld
var id: String
var db: String
var base: int


func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 12345})
	var plan := w.generator.settlements.home_plan()
	id = String(plan["id"])
	base = (plan["homes"] as Array).size()
	for home: Dictionary in plan["homes"]:
		var bed: Vector2i = home["bed"]
		w.chunk("surface", bed.x >> 5, bed.y >> 5)
	for c: Creature in w.creatures.creatures.values().duplicate():
		if String(w.content.get_def(c.kind).get("behavior", "")) == "predator":
			w.creatures.remove(c.id)
	_fund(500)


func after_each() -> void:
	w.close()


func _fund(coins: int) -> void:
	w.economy._goods_of[id] = {"makes": {"base:wheat": 10}, "needs": {"base:raw_fish": 2}}
	var store := w.economy.store(id)
	store["coins"] = coins
	for item: String in ["base:plank", "base:log", "base:stone", "base:cloth", "base:raw_fish"]:
		store["stock"][item] = 10000


func _days(n: int) -> void:
	for i in n:
		var rate := w.time_rate
		w.time_rate = Daylight.DAY_MS
		w.advance_time()
		w.time_rate = rate
		w.economy.store(id)
		w.settlement_life.step(id)


func _state() -> Dictionary:
	return w.settlement_population.state(id)


func _one_departure() -> String:
	if not check(w.settlement_population._depart(id), "a household can leave"):
		return ""
	var key: String = (_state()["leaving"] as Dictionary).keys()[0]
	var cid := String(_state()["leaving"][key]["id"])
	var resident := w.creatures.get_creature(cid)
	resident.health = 3
	resident.changed()
	w.settlement_population.finish_departure(resident)
	return key


func test_completed_housing_gets_a_real_resident_with_work_and_sleep() -> void:
	_fund(10000)
	w.economy.store(id)["development"] = {"state": "prosperous", "trend": "prosperous", "days": 3, "day": 0}
	_days(1)
	var project: Dictionary = w.settlement_life.state(id)["project"]
	if not check(not project.is_empty(), "a house is under construction"):
		return
	for row: Array in project["cells"]:
		var cell := Vector2i(int(row[0]), int(row[1]))
		for c: Creature in w.creatures.creatures.values().duplicate():
			if c.cell() == cell:
				w.creatures.remove(c.id)
	_days(2)
	var homes: Array = _state()["homes"]
	if not check(homes.size() == 1, "a house is completed"):
		return
	var cid := String(homes[0].get("resident", ""))
	if not check(w.creatures.has(cid), "the new resident is a real server creature"):
		return
	var resident := w.creatures.get_creature(cid)
	eq(int(resident.job["home"]), base)
	eq(String(resident.job["profession"]), String(homes[0]["dweller"]))
	var bed := Vector2i(int(homes[0]["bed"][0]), int(homes[0]["bed"][1]))
	eq(w.creatures._dweller_spot(resident, "night"), bed, "the NPC's normal schedule uses the new home's bed")
	check(w.creatures._dweller_spot(resident, "work") != Creature.NO_TARGET, "the new worker has a real workplace")
	eq(int(_state()["population"]), base + 1)
	check(int(w.economy.makes(id)["base:wheat"]) > 10, "the new worker contributes to production")
	for i in 10:
		w.settlement_population.populate(id)
	eq(int(_state()["population"]), base + 1, "repeated updates cannot duplicate a household")
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	w.chunk("surface", resident.cell().x >> 5, resident.cell().y >> 5)
	eq(String(_state()["homes"][0]["resident"]), cid, "the resident's identity is durable")
	eq(int(_state()["population"]), base + 1)


func test_long_distress_starts_a_real_departure_without_declaring_a_death() -> void:
	w.economy.store(id)["coins"] = 0
	_days(2)
	eq(_state()["leaving"], {}, "a brief problem cannot evict a household")
	_days(SettlementPopulation.LEAVE_DAYS)
	if not check((_state()["leaving"] as Dictionary).size() == 1, "one household decides to leave after prolonged distress"):
		return
	var slot: String = (_state()["leaving"] as Dictionary).keys()[0]
	var cid := String(_state()["leaving"][slot]["id"])
	var resident := w.creatures.get_creature(cid)
	var start := resident.pos
	for i in 1800:
		if not w.creatures.has(cid):
			break
		w.tick += 1
		w.creatures._tick = w.tick
		w.creatures._dweller(resident, w.content.get_def(resident.kind))
		if w.creatures.has(cid):
			w.creatures._move(resident)
	check(resident.pos != start, "departure uses the existing movement and door navigation")
	check(not w.creatures.has(cid), "the person leaves after reaching the edge of the village: start=%s pos=%s target=%s path=%d exit=%s" % [start, resident.pos, resident.target, resident.path.size(), resident.job.get("leave_to", [])])
	check((_state()["departed"] as Dictionary).has(slot), "the departed identity is retained")
	check(not (_state()["dead"] as Dictionary).has(slot), "economic migration is not death")
	eq(int(_state()["population"]), base - 1)
	check(int(w.economy.makes(id)["base:wheat"]) < 10, "fewer residents make less")


func test_a_leaving_resident_is_not_teleported_home_by_catch_up() -> void:
	if not check(w.settlement_population._depart(id), "a resident has begun leaving"):
		return
	var key: String = (_state()["leaving"] as Dictionary).keys()[0]
	var cid := String(_state()["leaving"][key]["id"])
	var person := w.creatures.get_creature(cid)
	person.pos += Vector2i(2 * Movement.UNIT, 0)
	var current := person.pos
	w.creatures._catch_up(person, w.content.get_def(person.kind))
	eq(person.pos, current, "an unfinished departure keeps its actual road position")
	check(person.job.has("leave_to"), "the journey remains active after catch-up")


func test_abandoned_roofs_and_a_returned_person_survive_reopening() -> void:
	var slot := _one_departure()
	if slot == "":
		return
	var cid := String(_state()["departed"][slot]["id"])
	var identity: Dictionary = _state()["departed"][slot]["data"].duplicate(true)
	w.economy.store(id)["coins"] = 0
	_days(SettlementPopulation.ABANDON_DAYS)
	var damage: Array = _state()["departed"][slot]["damage"].duplicate(true)
	if not check(not damage.is_empty(), "a long-empty house loses real roof cells"):
		return
	for row: Array in damage:
		eq(w._part_at(String(row[0]), int(row[1]), int(row[2]), "roof"), "")
	# A player can repair one patch with a different material. Economic
	# recovery must keep that work and pay only for the other missing parts.
	var first: Array = damage[0]
	var c := w.chunk(String(first[0]), int(first[1]) >> 5, int(first[2]) >> 5)
	c.set_cell("roof", int(first[1]) & 31, int(first[2]) & 31, "base:slate_roof")
	w._set_layer_props(c, "roof", int(first[1]) & 31, int(first[2]) & 31, {"owner": "player"})
	w._changed(ServerWorld.chunk_key(String(first[0]), int(first[1]) >> 5, int(first[2]) >> 5))
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	check((_state()["departed"] as Dictionary).has(slot), "the departure and damaged house are durable")
	_fund(500)
	_days(8)
	if not check(w.creatures.has(cid), "the person returns after sustained recovery and paid repairs"):
		return
	var returned := w.creatures.get_creature(cid)
	eq(returned.job.get("name"), identity["job"]["name"])
	eq(returned.health, int(identity["health"]), "returning does not resurrect or heal a different person")
	eq(w.economy.coins(id), 500 - (damage.size() - 1) * SettlementPopulation.REPAIR_WAGE)
	eq(w._part_at(String(first[0]), int(first[1]), int(first[2]), "roof"), "base:slate_roof", "the player's replacement remains")
	for i in range(1, damage.size()):
		var row: Array = damage[i]
		eq(w._part_at(String(row[0]), int(row[1]), int(row[2]), "roof"), String(row[3]))
	check(not (_state()["departed"] as Dictionary).has(slot), "the restored household is occupied again")
	eq(int(_state()["population"]), base)


func test_killed_residents_are_not_returned_by_economic_recovery() -> void:
	check(w.settlement_population._depart(id), "a person has begun leaving before being killed")
	var slot: String = (_state()["leaving"] as Dictionary).keys()[0]
	var cid := String(_state()["leaving"][slot]["id"])
	var resident := w.creatures.get_creature(cid)
	w.chronicles.died(resident, "")
	w.creatures.remove(cid)
	_days(12)
	check(not w.creatures.has(cid), "the killed NPC stays absent")
	check((_state()["dead"] as Dictionary).has(slot), "death is durable population state")
	check(not (_state()["departed"] as Dictionary).has(slot), "a dead person is not an economic returnee")
	eq(int(_state()["population"]), base - 1)
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	var home: Dictionary = w.settlement_life.plan(id)["homes"][int(slot)]
	var bed: Vector2i = home["bed"]
	w.chunk("surface", bed.x >> 5, bed.y >> 5)
	check(not w.creatures.has(cid), "loading the old home does not resurrect the dead resident")
	eq(int(_state()["population"]), base - 1)


func test_unloaded_registered_people_can_be_found_without_loading_their_home() -> void:
	var slot: String = (_state()["residents"] as Dictionary).keys()[0]
	var cid := String(_state()["residents"][slot])
	var name := String(w.creatures.get_creature(cid).job["name"])
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	if w.creatures.has(cid):
		w.creatures.drop_chunk(w.creatures._chunk_of(w.creatures.get_creature(cid)))
	var before := w._chunks.size()
	var person := w.settlement_population._person(cid)
	check(person != null and person.job.get("name") == name, "the unloaded person's stored identity is found")
	eq(w._chunks.size(), before, "the identity lookup reads the entity, not a generated village")


func test_a_backpressured_departure_and_return_keep_the_latest_live_person() -> void:
	w.economy.earn(id, 0)
	check(w.sync(), "the original resident and treasury are durable")
	w.max_batches_in_flight = 0
	var slot := _one_departure()
	if slot == "":
		return
	var cid := String(_state()["departed"][slot]["id"])
	_days(4)
	if not check(w.creatures.has(cid), "the person has returned in memory"):
		return
	w.commit_async()
	w.flush_state()
	w.writer.wait_idle()
	check(not w.store.entity(cid).is_empty(), "the older durable resident is unchanged while the operation waits")
	check(w.sync(), "the combined migration operation commits")
	check(not w.store.entity(cid).is_empty(), "the latest live person is not deleted by the older departure")
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	var row := w.store.entity(cid)
	check(not row.is_empty(), "the returned identity survives reopening")
	eq(int(_state()["population"]), base)


func test_prolonged_decline_keeps_one_household_for_trade_and_recovery() -> void:
	w.economy.store(id)["coins"] = 0
	for i in 60:
		_days(1)
		for key: String in (_state()["leaving"] as Dictionary).keys():
			var person := w.settlement_population._person(String(_state()["leaving"][key]["id"]))
			if person != null:
				w.settlement_population.finish_departure(person)
	eq(int(_state()["population"]), 1, "economic departures do not remove the last trading household")
	eq((_state()["departed"] as Dictionary).size(), base - 1)


func test_neighbours_fund_repair_materials_beyond_one_delivery() -> void:
	# Exercise the data-driven cost contract: three roof parts cost nine
	# logs here, more than the normal eight-unit construction delivery.
	w.content.get_def("base:thatch_roof")["cost"] = {"base:log": 3}
	var slot := _one_departure()
	if slot == "":
		return
	var cid := String(_state()["departed"][slot]["id"])
	w.economy.store(id)["coins"] = 0
	_days(SettlementPopulation.ABANDON_DAYS)
	var damage: Array = _state()["departed"][slot]["damage"]
	if not check(damage.size() == 3, "three real roof patches need repair"):
		return
	_fund(500)
	w.economy.store(id)["stock"]["base:log"] = 0
	var seller: String = w.economy.neighbours(id)[0]
	w.economy._goods_of[seller] = {"makes": {}, "needs": {}}
	w.economy.store_quiet(seller)["stock"]["base:log"] = 1000
	var theirs := w.economy.coins(seller)
	check(w.economy.short(id).has("base:log"), "repair materials contribute to the village's real demand")
	_days(8)
	check(w.creatures.has(cid), "paid deliveries let the repaired household return")
	check(w.economy.coins(seller) > theirs, "the repair supply was bought, not fabricated")
	eq(w.economy.have(id, "base:log"), 0, "the complete nine-unit bill was consumed by repair")


func test_two_clients_see_the_same_departure_and_returned_identity() -> void:
	var net := MemoryTransport.MemoryNetwork.new()
	var keys := db.get_base_dir().path_join("keys")
	var server := GameServer.new(w, net.server(), PlayerIdentity.load_or_create(keys.path_join("server")))
	server.wait_for_disk = true
	var clients: Array[GameClient] = []
	for who: String in ["witness-a", "witness-b"]:
		var identity := PlayerIdentity.load_or_create(keys.path_join(who))
		var pc := PortableCharacter.create(who, "base:human_ro_m")
		pc.styles = {"hair": "base:human_hair_bald"}
		clients.append(GameClient.new(net.client(), identity, CharacterFile.export_signed(pc, identity, w.content), w.content))
	_run(server, clients, 35)
	var slots: Array = (_state()["residents"] as Dictionary).keys()
	slots.sort_custom(func(a: String, b: String) -> bool: return int(a) > int(b))
	var cid := String(_state()["residents"][slots[0]])
	var resident := w.creatures.get_creature(cid)
	var name := String(resident.job["name"])
	for client: GameClient in clients:
		if not eq(client.state, "playing", client.reject_reason):
			return
		w.move_character(client.character_id, resident.pos)
	_run(server, clients, 35)
	for client: GameClient in clients:
		check(client.entities.has(cid), "both witnesses initially see the resident")
	check(w.settlement_population._depart(id), "the witnessed person begins a normal departure")
	for i in 1400:
		if not w.creatures.has(cid):
			break
		_run(server, clients, 1)
	_run(server, clients, 15)
	check(not w.creatures.has(cid), "the departure completes on the real server")
	for client: GameClient in clients:
		check(not client.entities.has(cid), "the removed person disappears for each witness")
	_days(5)
	if not check(w.creatures.has(cid), "the same person returns after recovery"):
		return
	# The clock jumped several days without AI ticks. Let the normal catch-up
	# put the returned worker at today's job before moving the witnesses.
	_run(server, clients, 10)
	resident = w.creatures.get_creature(cid)
	for client: GameClient in clients:
		w.move_character(client.character_id, resident.pos)
	_run(server, clients, 35)
	for client: GameClient in clients:
		check(client.entities.has(cid), "the original identity reaches both clients again: replica=%s npc=%s player=%s client=%s" % [server._replica.has(cid), resident.pos, w.present[client.character_id]["pos"], client.location])
		eq(client.entities.get(cid, {}).get("name"), name)


func _run(server: GameServer, clients: Array[GameClient], ticks: int) -> void:
	for i in ticks:
		server.step()
		for client: GameClient in clients:
			client.step()
