extends TestCase
## Generated floors obey the same persistence, stair and network contracts
## as player buildings; their street appearance uses the live saved cells.

func test_generated_floors_reach_two_clients_and_keep_player_edits() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var world := ServerWorld.open(path, content, {"seed": 12345})
	var plan := world.generator.settlements.home_plan()
	if not check(not plan["upper"].is_empty(), "the generated village has an upper floor"):
		world.close()
		return
	var building: String = plan["upper"].keys()[0]
	var design := {}
	var origin := Vector2i.ZERO
	for home: Dictionary in plan["homes"]:
		if String(plan["id"]) + "|" + String(home["building_id"]) == building:
			design = home["architecture"]
			origin = (home["rect"] as Rect2i).position
	var stair := SettlementArchitecture.local_cell(design, SettlementArchitecture._stairs(design)) + origin
	world.chunk("surface", stair.x >> 5, stair.y >> 5)
	var upper := world.levels.level(building, 1)
	check(upper != "", "the generated floor is registered with Levels")
	var arrival: Array = plan["cells"][stair]["props"]["arrive"]
	var landing := Vector2i(arrival[0], arrival[1])
	eq(world._upper_of("surface", landing), upper, "stairs lead to the real level")
	check(not world.is_solid(upper, landing.x, landing.y), "a walkable landing")
	var network := MemoryTransport.MemoryNetwork.new()
	var server := GameServer.new(world, network.server(), _key("settlement-server"))
	server.wait_for_disk = true
	var clients: Array[GameClient] = []
	for name: String in ["settlement-a", "settlement-b"]:
		var key := _key(name)
		var character := PortableCharacter.create(name, "base:human_ro_m")
		character.styles = {"hair": "base:human_hair_bald"}
		clients.append(GameClient.new(network.client(), key, CharacterFile.export_signed(character, key, content), content))
	_run(server, clients, 35)
	for client: GameClient in clients:
		if not check(client.state == "playing", client.reject_reason):
			server.shutdown()
			world.close()
			return
		world.move_character(client.character_id, stair * 256 + Vector2i(128, 128))
	_run(server, clients, 80)
	var chunk_key := ServerWorld.chunk_key(upper, stair.x >> 5, stair.y >> 5)
	for client: GameClient in clients:
		check(client.chunks.has(chunk_key), "the real exterior reaches each client on the street")
	var upstairs_bed := Vector2i.ZERO
	for at: Vector2i in plan["upper"][building]:
		if plan["upper"][building][at]["structure"] == "base:bed":
			upstairs_bed = at
	for client: GameClient in clients:
		eq(client.cell_at(upper, upstairs_bed, "structure"), "", "the closed floor's furniture is not sent to the street")
	var a := clients[0]
	var rid := a.request({"type": "climb", "location": "surface", "x": stair.x, "y": stair.y})
	_run(server, clients, 20)
	check(a.results.get(rid, {}).get("ok", false), "the player climbs the generated staircase")
	eq(a.location, upper)
	eq(a.z, 1)
	eq(a.cell_at(upper, upstairs_bed, "structure"), "base:bed", "the full interior arrives after climbing")
	eq(clients[1].cell_at(upper, upstairs_bed, "structure"), "", "the street observer still receives only the exterior")
	rid = a.request({"type": "climb", "location": upper, "x": stair.x, "y": stair.y, "dir": "down"})
	_run(server, clients, 20)
	check(a.results.get(rid, {}).get("ok", false), "the player comes back down")
	eq(a.location, "surface")
	var edited := landing
	var chunk := world.chunk(upper, edited.x >> 5, edited.y >> 5)
	chunk.set_cell("roof", edited.x & 31, edited.y & 31, "")
	world._changed(ServerWorld.chunk_key(upper, edited.x >> 5, edited.y >> 5))
	_run(server, clients, 30)
	for client: GameClient in clients:
		eq(client.cell_at(upper, edited, "roof"), "", "an upper roof removed by a player disappears for both clients")
	server.shutdown()
	world.close()
	world = ServerWorld.open(path, content)
	if check(world != null, "the village reopens"):
		eq(world.levels.level(building, 1), upper, "the saved level retains its identity")
		world.chunk("surface", stair.x >> 5, stair.y >> 5)
		check(world._chunks.has(chunk_key), "a saved exterior is loaded again when the street reopens")
		eq(world._part_at(upper, edited.x, edited.y, "roof"), "", "loading the surface never regenerates an edited upper floor")
		world.close()

func _key(name: String) -> PlayerIdentity:
	return PlayerIdentity.load_or_create(ProjectSettings.globalize_path("user://test_keys/" + name))

func _run(server: GameServer, clients: Array[GameClient], ticks: int) -> void:
	for i in ticks:
		server.step()
		for client: GameClient in clients:
			client.step()

func test_inn_exterior_reaches_street_after_climbing_and_reopening() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("inn-exterior.db")
	var world := ServerWorld.open(path, content, {"seed": 431})
	var settlements := world.generator.settlements
	var district := settlements._district_of(0, settlements.home_plan()["centre"])
	var plans := settlements.inns.of_cluster(0, district.x, district.y).filter(func(p: Dictionary) -> bool: return p["site"] == "inn")
	if not check(not plans.is_empty(), "fixture has a real two-storey inn"):
		world.close()
		return
	var plan: Dictionary = plans[0]
	var host: Vector2i = plan["host"]
	world.chunk("surface", host.x >> 5, host.y >> 5)
	var upper := world.levels.level(plan["id"], 1)
	var stair := Vector2i.MAX
	for at: Vector2i in plan["cells"]:
		if plan["cells"][at].get("structure") == "base:wood_stairs": stair = at
	var roof: Vector2i = plan["upper"].keys()[0]
	# Metadata on old inn/player chunks is optional; Levels owns their height.
	for at: Vector2i in plan["upper"]:
		world.chunk(upper, at.x >> 5, at.y >> 5).meta.erase("building_z")
	for reopened in [false, true]:
		var network := MemoryTransport.MemoryNetwork.new()
		var server := GameServer.new(world, network.server(), _key("inn-exterior-server"))
		server.wait_for_disk = true
		var key := _key("inn-exterior-guest")
		var character := PortableCharacter.create("Гость", "base:human_ro_m")
		character.styles = {"hair": "base:human_hair_bald"}
		var client := GameClient.new(network.client(), key, CharacterFile.export_signed(character, key, content), content)
		_run(server, [client], 35)
		if not check(client.state == "playing", client.reject_reason):
			server.shutdown()
			world.close()
			return
		world.move_character(client.character_id, stair * Movement.UNIT + Vector2i(128, 128))
		_run(server, [client], 80)
		_check_inn_exterior(client, plan, upper, roof, "after reopening" if reopened else "before entering")
		if not reopened:
			var rid := client.request({"type": "climb", "location": "surface", "x": stair.x, "y": stair.y})
			_run(server, [client], 20)
			check(client.results.get(rid, {}).get("ok", false), "climb into the actual inn floor")
			eq(client.location, upper)
			rid = client.request({"type": "climb", "location": upper, "x": stair.x, "y": stair.y, "dir": "down"})
			_run(server, [client], 30)
			check(client.results.get(rid, {}).get("ok", false), "return to the surface")
			_check_inn_exterior(client, plan, upper, roof, "after descending")
			# An edited opening must remain an opening after reopening the world.
			var c := world.chunk(upper, roof.x >> 5, roof.y >> 5)
			c.set_cell("roof", roof.x & 31, roof.y & 31, "")
			world._changed(ServerWorld.chunk_key(upper, roof.x >> 5, roof.y >> 5))
		server.shutdown()
		world.close()
		if not reopened:
			world = ServerWorld.open(path, content)

func _check_inn_exterior(client: GameClient, plan: Dictionary, upper: String, edited: Vector2i, stage: String) -> void:
	var walls := 0
	var roofs := 0
	for at: Vector2i in plan["upper"]:
		var spec: Dictionary = plan["upper"][at]
		var role := String(client.content.get_def(String(spec.get("structure", ""))).get("role", ""))
		if role in ["wall", "window", "door"]:
			eq(client.cell_at(upper, at, "structure"), spec["structure"], "saved upper wall reaches the street " + stage)
			walls += 1
		elif spec.get("structure", "") != "":
			eq(client.cell_at(upper, at, "structure"), "", "closed floor furnishings remain private " + stage)
		if spec.get("roof", "") != "" and at != edited:
			eq(client.cell_at(upper, at, "roof"), spec["roof"], "saved upper roof reaches the street " + stage)
			roofs += 1
	check(walls > 0 and roofs > 0, "actual walls and roof inspected " + stage)
	var key := ServerWorld.chunk_key(upper, edited.x >> 5, edited.y >> 5)
	var c: Chunk = client.chunks.get(key)
	check(c != null and int(c.meta.get("building_z", 0)) == 1, "street adapter knows the true upper height " + stage)
	if stage == "after reopening": eq(client.cell_at(upper, edited, "roof"), "", "reopening preserves the player's roof opening")

func test_third_floor_receives_saved_lower_architecture_without_private_contents() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("floor-stack.db")
	var world := ServerWorld.open(path, content, {"seed": 431})
	var building := "test-floor-stack"
	var lower := world.levels.create_level(building, 1)
	var current := world.levels.create_level(building, 2)
	for location: String in [lower, current]:
		var c := world.chunk(location, 0, 0)
		for y in range(1, 4):
			for x in range(1, 4):
				c.set_cell("ground", x, y, "base:wood_floor")
				c.set_cell("ceiling" if location == lower else "roof", x, y, "base:wood_ceiling" if location == lower else "base:thatch_roof")
		c.set_cell("structure", 1, 1, "base:wood_wall")
		c.set_cell("structure", 2, 2, "base:bed")
		world._changed(ServerWorld.chunk_key(location, 0, 0))
	world.sync()
	world.close()
	world = ServerWorld.open(path, content)
	check(not world._chunks.has(ServerWorld.chunk_key(lower, 0, 0)), "lower floor starts only on disk, not in the loaded floor list")
	var network := MemoryTransport.MemoryNetwork.new()
	var server := GameServer.new(world, network.server(), _key("floor-stack-server"))
	server.wait_for_disk = true
	var key := _key("floor-stack-guest")
	var character := PortableCharacter.create("Гость", "base:human_ro_m")
	character.styles = {"hair": "base:human_hair_bald"}
	var client := GameClient.new(network.client(), key, CharacterFile.export_signed(character, key, content), content)
	_run(server, [client], 35)
	if not check(client.state == "playing", client.reject_reason):
		server.shutdown()
		world.close()
		return
	world.present[client.character_id]["location"] = current
	world.move_character(client.character_id, Vector2i(2, 2) * Movement.UNIT + Vector2i(128, 128))
	world.relocated[client.character_id] = true
	_run(server, [client], 100)
	eq(client.z, 2, "the character is on the real third floor")
	eq(client.cell_at(current, Vector2i(2, 2), "structure"), "base:bed", "current floor retains the full interior")
	eq(client.cell_at(lower, Vector2i(1, 1), "structure"), "base:wood_wall", "saved lower exterior is streamed without visiting it")
	eq(client.cell_at(lower, Vector2i(2, 2), "structure"), "", "lower bedroom furniture is not disclosed")
	eq(client.cell_at(lower, Vector2i(2, 2), "ground"), "base:wood_floor", "lower floor slab is preserved")
	eq(client.cell_at(lower, Vector2i(2, 2), "ceiling"), "base:wood_ceiling", "lower ceiling supports the current floor")
	var c := client.chunk_at(lower, 2, 2)
	check(c != null and c.meta.get("exterior", false), "lower location is an exterior snapshot")
	if c:
		eq(c.meta.get("building"), building, "exterior identifies its own building")
		eq(c.meta.get("building_z"), 1, "lower architecture retains its true height")
	c = client.chunk_at(current, 2, 2)
	check(c != null and c.meta.get("building") == building, "current full chunk identifies the same building")
	check(not client.map_known.has(lower), "viewing a lower facade does not explore its private map")
	server.shutdown()
	world.close()
