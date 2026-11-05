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
