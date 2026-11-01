extends TestCase
## The same server and client over real ENet on localhost.


func test_join_move_and_build_over_enet() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := ServerWorld.open(tmp_dir().path_join("world.db"), content)
	var st := ENetTransport.new()
	var port := 0
	for p in range(41000, 41050):
		if st.start_server(p, 8) == OK:
			port = p
			break
	if not check(port != 0, "a free port"):
		world.close()
		return
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var server := GameServer.new(world, st, PlayerIdentity.load_or_create(keys + "server"))
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	c.inventory.add("base:plank", 3)
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var ct := ENetTransport.new()
	ct.start_client("127.0.0.1", port)
	var client := GameClient.new(ct, owner, CharacterFile.export_signed(c, owner, content), content)
	var rid := ""
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		server.step()
		client.step()
		if client.state == "playing" and client.has_position:
			if rid == "":
				client.move = Vector2i(1, 0)
				rid = client.request({"type": "build", "location": "surface", "x": 0, "y": 3, "part": "base:wood_wall"})
			elif client.results.has(rid) and _pos(world, client).x > 200:
				break
		OS.delay_msec(5)
	eq(client.state, "playing", client.reject_reason)
	eq(client.results.get(rid), {"ok": true}, "request answered over ENet")
	check(_pos(world, client).x > 200, "moved")
	check(not client.chunks.is_empty(), "chunks arrived on the bulk channel")
	ct.close()
	server.shutdown()
	st.close()
	world.close()


func _pos(world: ServerWorld, client: GameClient) -> Vector2i:
	return world.present[client.character_id]["pos"] if world.present.has(client.character_id) else Vector2i.ZERO


func test_huge_plan_is_transferred_over_enet() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "huge", "cold")
	var world := ServerWorld.open(tmp_dir().path_join("world.db"), content, {"world_plan": plan.to_dict()})
	var st := ENetTransport.new()
	var port := 0
	for p in range(41000, 41050):
		if st.start_server(p, 8) == OK:
			port = p
			break
	if not check(port != 0, "a free port"):
		world.close()
		return
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var server := GameServer.new(world, st, PlayerIdentity.load_or_create(keys + "server"))
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var ct := ENetTransport.new()
	ct.start_client("127.0.0.1", port)
	var client := GameClient.new(ct, owner, CharacterFile.export_signed(c, owner, content), content)
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and client.state != "playing":
		server.step()
		client.step()
		OS.delay_msec(5)
	eq(client.state, "playing", client.reject_reason)
	if client.geography is PlannedGeography:
		eq((client.geography as PlannedGeography).plan.to_dict(), plan.to_dict(), "the full saved plan arrives over ENet")
	else:
		check(false, "planned geography arrived")
	ct.close()
	server.shutdown()
	st.close()
	world.close()
