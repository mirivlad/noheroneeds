extends TestCase

var w: ServerWorld
var id: String
var db: String


func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 12345})
	id = String(w.generator.settlements.home_plan()["id"])
	_fund()


func _fund() -> void:
	w.economy._goods_of[id] = {"makes": {}, "needs": {}}
	var store := w.economy.store(id)
	store["coins"] = 10000
	store["development"]["state"] = "prosperous"
	store["development"]["trend"] = "prosperous"
	store["development"]["days"] = 3
	for item: String in ["base:plank", "base:log", "base:stone", "base:cloth", "base:bed_item", "base:chest_item"]:
		store["stock"][item] = 10000
	w.settlement_life.state(id)


func after_each() -> void:
	w.close()


func _day() -> void:
	var rate := w.time_rate
	w.time_rate = Daylight.DAY_MS
	w.advance_time()
	w.time_rate = rate
	w.economy.store(id)
	w.settlement_life.step(id)


func _project() -> Dictionary:
	return w.settlement_life.state(id)["project"]


func _clear_people(project: Dictionary) -> void:
	var sites := {}
	for row: Array in project["cells"]:
		sites[Vector2i(int(row[0]), int(row[1]))] = true
	for c: Creature in w.creatures.creatures.values().duplicate():
		if sites.has(c.cell()):
			w.creatures.remove(c.id)


func test_a_funded_house_is_built_in_three_saved_stages() -> void:
	var proposal := w.settlement_life.propose(id, 0)
	if not check(not proposal.is_empty(), "a free street plot exists"):
		return
	check(int(proposal["cost"].get("base:cloth", 0)) >= 2, "the bed costs its actual recipe ingredients")
	check(not (proposal["cost"] as Dictionary).has("base:bed_item"), "furniture is made from its ingredients")
	var stock: Dictionary = w.economy.store(id)["stock"].duplicate()
	_day()
	if not check(not _project().is_empty(), "a prosperous village starts a funded project"):
		return
	var project := _project().duplicate(true)
	eq(int(w.economy.coins(id)), 10000 - SettlementLife.WAGES)
	for item: String in project["cost"]:
		eq(w.economy.have(id, item), int(stock[item]) - int(project["cost"][item]), "materials reserved once")
	for row: Array in project["cells"]:
		eq(w.part_at("surface", int(row[0]), int(row[1])), "", "the foundation has no instant walls")
	_clear_people(project)
	_day()
	eq(_project()["stage"], 1, "walls come on the next day")
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	eq(_project()["stage"], 1, "the unfinished project survives reopening")
	_clear_people(project)
	_day()
	eq(_project(), {}, "the third stage finishes the house")
	eq((w.settlement_life.state(id)["homes"] as Array).size(), 1)
	eq(w.economy.coins(id), 10000 - SettlementLife.WAGES, "reopening and finishing do not charge again")
	for row: Array in project["cells"]:
		eq(w.part_at("surface", int(row[0]), int(row[1])), String(row[2].get("structure", "")), "real walls and furniture occupy the planned cells")
	if not (project["upper"] as Array).is_empty():
		var upper := w.levels.level(String(project["building"]), 1)
		check(upper != "", "the new house has a real upper level")
		for row: Array in project["upper"]:
			eq(w._part_at(upper, int(row[0]), int(row[1]), "roof"), String(row[2].get("roof", "")))


func test_missing_materials_are_collected_without_using_daily_reserves() -> void:
	var proposal := w.settlement_life.propose(id, 0)
	if not check(not proposal.is_empty(), "a plot exists"):
		return
	var item: String = proposal["cost"].keys()[0]
	w.economy.store(id)["stock"][item] = 0
	_day()
	eq(_project()["stage"], -1, "the funded plan waits for materials before laying its foundation")
	eq(w.economy.coins(id), 10000 - SettlementLife.WAGES, "work is funded once")
	eq(int(_project()["remaining"][item]), int(proposal["cost"][item]))
	w.economy._goods_of[id]["needs"] = {item: 1}
	w.economy.store(id)["stock"][item] = int(proposal["cost"][item]) + 1
	_day()
	check(int(_project()["remaining"][item]) > 0, "construction preserves the daily reserve")
	eq(w.economy.have(id, item), 2, "the two-day ordinary reserve stays in the store")
	eq(w.economy.coins(id), 10000 - SettlementLife.WAGES)


func test_daily_production_can_fund_a_house_larger_than_the_store_cap() -> void:
	for other: String in w.economy.neighbours(id):
		w.economy._goods_of[other] = {"makes": {}, "needs": {}}
		w.economy.store_quiet(other)["stock"] = {}
	w.economy._goods_of[id] = {"makes": {"base:plank": 6}, "needs": {}}
	w.economy.store(id)["stock"]["base:plank"] = 0
	_day()
	if not check(not _project().is_empty(), "a project is prepared"):
		return
	var cost := int(_project()["cost"].get("base:plank", 0))
	check(cost > 6 * VillageEconomy.KEEP_DAYS, "the fixture's house exceeds the ordinary stock cap")
	var project := _project().duplicate(true)
	for i in 80:
		_clear_people(project)
		_day()
		if not (w.settlement_life.state(id)["homes"] as Array).is_empty():
			break
	eq((w.settlement_life.state(id)["homes"] as Array).size(), 1, "daily surplus accumulated outside the capped trading store")
	eq(w.economy.coins(id), 10000 - SettlementLife.WAGES, "preparation and work charge once")


func test_neighbours_sell_materials_for_a_prepared_house() -> void:
	var item := "base:plank"
	w.economy.store(id)["stock"][item] = 0
	for other: String in w.economy.neighbours(id):
		w.economy._goods_of[other] = {"makes": {}, "needs": {}}
		w.economy.store_quiet(other)["stock"] = {}
	var seller: String = w.economy.neighbours(id)[0]
	w.economy.store_quiet(seller)["stock"][item] = 1000
	_day()
	eq(_project()["stage"], -1)
	check(w.economy.short(id).has(item), "the ordinary village dialogue and traders see the construction demand")
	var missing := int(_project()["remaining"][item])
	var coins := w.economy.coins(id)
	var theirs := w.economy.coins(seller)
	_day()
	check(int(_project()["remaining"].get(item, 0)) < missing, "a real paid shipment supplies preparation")
	check(w.economy.coins(id) < coins and w.economy.coins(seller) > theirs, "the buyer pays the supplying village")
	w.economy.earn(id, VillageEconomy.POOR - w.economy.coins(id))
	missing = int(_project()["remaining"][item])
	_day()
	eq(w.economy.coins(id), VillageEconomy.POOR, "construction purchases preserve the ordinary treasury reserve")
	eq(int(_project()["remaining"][item]), missing, "unaffordable supplies stay at the seller")
	w.economy._goods_of[id]["needs"] = {item: 1}
	w.economy.store(id)["stock"][item] = 2
	w.economy._fetch(id, w.economy.store(id))
	eq(w.economy.coins(id), VillageEconomy.POOR, "a project cannot disguise additional purchases as everyday supplies")
	_day()
	check(w.economy.have(id, item) >= 2, "actual everyday shortages are still supplied")
	eq(int(_project()["remaining"][item]), missing, "preparation waits when everyday purchases have made the treasury poor")


func test_new_houses_respect_the_server_height_limit() -> void:
	w.max_levels = 0
	var proposal := w.settlement_life.propose(id, 0)
	if check(not proposal.is_empty(), "a single-storey plot exists"):
		eq(proposal["upper"], [], "new buildings follow the current server height limit")


func test_a_player_change_stops_construction_without_overwriting_it() -> void:
	_day()
	if not check(not _project().is_empty(), "a project exists"):
		return
	var row: Array = _project()["cells"][0]
	var at := Vector2i(int(row[0]), int(row[1]))
	var c := w.chunk("surface", at.x >> 5, at.y >> 5)
	c.set_cell("roof", at.x & 31, at.y & 31, "base:slate_roof")
	w._set_layer_props(c, "roof", at.x & 31, at.y & 31, {"owner": "player"})
	w._changed(ServerWorld.chunk_key("surface", at.x >> 5, at.y >> 5))
	_day()
	eq(_project()["stage"], 0, "the project is held")
	eq(w._part_at("surface", at.x, at.y, "roof"), "base:slate_roof", "the player's roof remains")


func test_completed_upper_cells_keep_player_edits_after_reload() -> void:
	_day()
	if not check(not _project().is_empty(), "a project exists"):
		return
	var project := _project().duplicate(true)
	_clear_people(project)
	_day()
	_day()
	if not check(not (project["upper"] as Array).is_empty(), "the fixture exercises a real upper floor"):
		return
	var upper := w.levels.level(String(project["building"]), 1)
	var row: Array = project["upper"][0]
	var at := Vector2i(int(row[0]), int(row[1]))
	var c := w.chunk(upper, at.x >> 5, at.y >> 5)
	c.set_cell("roof", at.x & 31, at.y & 31, "")
	w._changed(ServerWorld.chunk_key(upper, at.x >> 5, at.y >> 5))
	w.close()
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	w.chunk("surface", at.x >> 5, at.y >> 5)
	eq(w.levels.level(String(project["building"]), 1), upper)
	eq(w._part_at(upper, at.x, at.y, "roof"), "", "loading the street never regenerates an edited upper floor")


func test_a_player_standing_at_a_future_wall_holds_the_whole_stage() -> void:
	_day()
	if not check(not _project().is_empty(), "a project exists"):
		return
	_clear_people(_project())
	var wall := Settlements.NONE
	for row: Array in _project()["cells"]:
		if w.content.get_def(String(row[2].get("structure", ""))).get("role", "") == "wall":
			wall = Vector2i(int(row[0]), int(row[1]))
			break
	if not check(wall != Settlements.NONE, "the house has a wall"):
		return
	var pc := PortableCharacter.create("Строитель", "base:human_ro_m")
	pc.styles = {"hair": "base:human_hair_bald"}
	w.enter("builder", pc)
	w.move_character(pc.character_id, wall * Movement.UNIT + Vector2i(128, 128))
	_day()
	eq(_project()["stage"], 0, "walls are not raised around a player")
	eq(w.part_at("surface", wall.x, wall.y), "")
	w.move_character(pc.character_id, w.spawn_position)
	_day()
	eq(_project()["stage"], 1, "work resumes when the wall cell is free")


func test_materials_money_and_the_first_stage_commit_together() -> void:
	# Make the old treasury durable, then hold new operation batches back.
	w.economy.earn(id, 0)
	check(w.sync(), "the initial economy is durable")
	var before := w.store.read_meta("economy|" + id)
	w.max_batches_in_flight = 0
	_day()
	if not check(not _project().is_empty(), "construction starts in memory"):
		return
	var project := _project().duplicate(true)
	w.commit_async()
	w.flush_state()
	w.writer.wait_idle()
	eq(w.store.read_meta("economy|" + id), before, "a state flush cannot publish wages/materials before the foundation")
	eq(w.store.read_meta("settlement_life|" + id), "", "nor publish a project before its cells")
	w.commit_async(true)
	w.writer.wait_idle()
	w.poll()
	check(w.store.read_meta("settlement_life|" + id) != "", "the construction operation committed")
	var saved: Dictionary = JSON.parse_string(w.store.read_meta("economy|" + id))
	eq(int(saved["coins"]), 10000 - SettlementLife.WAGES)
	for row: Array in project["cells"]:
		var at := Vector2i(int(row[0]), int(row[1]))
		var chunk := ChunkCodec.decode(w.store.get_chunk("surface", at.x >> 5, at.y >> 5))
		eq(chunk.get_props(at.x & 31, at.y & 31).get("construction"), project["building"], "the same operation wrote the real foundation")


func test_both_clients_receive_construction_stages_and_real_upper_roofs() -> void:
	_day()
	if not check(not _project().is_empty(), "a project exists"):
		return
	var project := _project().duplicate(true)
	_clear_people(project)
	var net := MemoryTransport.MemoryNetwork.new()
	var keys := db.get_base_dir().path_join("keys")
	var server := GameServer.new(w, net.server(), PlayerIdentity.load_or_create(keys.path_join("server")))
	server.wait_for_disk = true
	var clients: Array[GameClient] = []
	for name: String in ["builder-a", "builder-b"]:
		var key := PlayerIdentity.load_or_create(keys.path_join(name))
		var pc := PortableCharacter.create(name, "base:human_ro_m")
		pc.styles = {"hair": "base:human_hair_bald"}
		clients.append(GameClient.new(net.client(), key, CharacterFile.export_signed(pc, key, w.content), w.content))
	_run(server, clients, 35)
	var door := Vector2i(int(project["door"][0]), int(project["door"][1]))
	var outward: Vector2i = ContentRegistry.FACINGS[SettlementArchitecture.facing({"turns": project["turns"]})]
	var wall := Vector2i.ZERO
	var wall_part := ""
	for row: Array in project["cells"]:
		if w.content.get_def(String(row[2].get("structure", ""))).get("role", "") == "wall":
			wall = Vector2i(int(row[0]), int(row[1]))
			wall_part = String(row[2]["structure"])
			break
	for client: GameClient in clients:
		if not eq(client.state, "playing", client.reject_reason):
			return
		w.move_character(client.character_id, (door + outward * 2) * Movement.UNIT + Vector2i(128, 128))
	_run(server, clients, 40)
	for client: GameClient in clients:
		eq(client.cell_at("surface", wall, "structure"), "", "each player sees the unfinished foundation")
	_clear_people(project)
	_day()
	eq(_project().get("stage"), 1, "the wall stage completes before checking its network snapshot")
	_run(server, clients, 35)
	for client: GameClient in clients:
		eq(client.cell_at("surface", wall, "structure"), wall_part, "the raised wall reaches both players")
	_clear_people(project)
	_day()
	_run(server, clients, 40)
	eq(_project(), {}, "both players remain outside the wall cells while work completes")
	if not (project["upper"] as Array).is_empty():
		var upper := w.levels.level(String(project["building"]), 1)
		for client: GameClient in clients:
			var roofs := 0
			for row: Array in project["upper"]:
				if String(row[2].get("roof", "")) != "":
					roofs += 1
					eq(client.cell_at(upper, Vector2i(int(row[0]), int(row[1])), "roof"), String(row[2]["roof"]), "the real upper roof reaches the street")
			check(roofs > 0, "the completed upper floor is covered")


func _run(server: GameServer, clients: Array[GameClient], ticks: int) -> void:
	for i in ticks:
		server.step()
		for client: GameClient in clients:
			client.step()


func test_construction_on_a_saved_finite_plan_preserves_the_original_geography() -> void:
	w.close()
	db = db.get_base_dir().path_join("planet.db")
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]),
		{"seed": 7, "require_planned": true, "preset": "small", "climate": "temperate"})
	if not check(w != null, ServerWorld.open_error):
		return
	var villages := w.generator.settlements.villages(0, 0, 0)
	if not check(not villages.is_empty(), "the planet has an actual settlement in the starting district"):
		return
	id = String(villages[0]["id"])
	_fund()
	check(w.topology.wraps(), "the fixture is a closed planet")
	var geography := w.store.read_meta("world_plan")
	var homes := (w.generator.settlements.plan_by_id(id)["homes"] as Array).size()
	for i in 8:
		_day()
		if not _project().is_empty():
			break
	if not check(not _project().is_empty(), "a new house fits beside a street on the planet"):
		return
	var project := _project().duplicate(true)
	_clear_people(project)
	_day()
	_day()
	eq(_project(), {})
	eq((w.settlement_life.state(id)["homes"] as Array).size(), 1)
	eq((w.generator.settlements.plan_by_id(id)["homes"] as Array).size(), homes, "the seeded layout remains the starting point")
	eq(w.store.read_meta("world_plan"), geography, "growth is independent of the saved geography")
	check(w.sync(), "the new cells and project are durable")
	eq(w.store.read_meta("world_plan"), geography)
