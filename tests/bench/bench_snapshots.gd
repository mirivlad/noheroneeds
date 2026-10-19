extends TestCase
## The server tick in one process, without ENet and without bots competing
## for the processor: n clients walking about and a crowd of creatures around
## them, over the in-memory network. Shows the sections of the tick, steady
## and worst (run: tools/run_tests.sh --bench --only=bench_snapshots).
## --snap_ticks=N changes the length (default 600 = 30 s of game).

static var _keys := {}


func bench_20_clients_no_crowd() -> void:
	_run(20, 0)


func bench_20_clients_500_creatures() -> void:
	_run(20, 500)


func _key(who: String) -> PlayerIdentity:
	if not _keys.has(who):
		_keys[who] = PlayerIdentity.load_or_create(ProjectSettings.globalize_path("user://test_keys/" + who))
	return _keys[who]


func _run(n: int, crowd: int) -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := ServerWorld.open(tmp_dir().path_join("world.db"), content, {"seed": 5})
	var net := MemoryTransport.MemoryNetwork.new()
	var server := GameServer.new(world, net.server(), _key("server"))
	if crowd > 0:
		world.creatures.spawn_crowd(crowd, 40)
	var clients: Array[GameClient] = []
	for i in n:
		var c := PortableCharacter.create("Бот %d" % i, "base:human_m")
		c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
		var file := CharacterFile.export_signed(c, _key("bot%d" % i), content)
		clients.append(GameClient.new(net.client(), _key("bot%d" % i), file, content))
	var r := RandomNumberGenerator.new()
	r.seed = 3
	for i in 100:  # join and settle
		server.step()
		for c in clients:
			c.step()
	server.take_stats()
	var ticks := int(options.get("snap_ticks", 600))
	var client_usec := 0
	for t in ticks:
		for c in clients:
			if r.randf() < 0.05:
				c.move = Vector2i(r.randi_range(-1, 1), r.randi_range(-1, 1))
		server.step()
		var t0 := Time.get_ticks_usec()
		for c in clients:
			c.step()
		client_usec += Time.get_ticks_usec() - t0
		if (t + 1) % 200 == 0:
			var s := server.take_stats()
			print("  %d clients, %d creatures: tick p50 %d p99 %d max %d us, %s" % [n, crowd, int(s["p50"]),
				int(s["p99"]), int(s["max"]), JSON.stringify(s["sections_ms"])])
			print("    slowest tick: " + JSON.stringify(s["slowest_ms"]))
	print("MEASURE snap%d_c%d_client_step_avg %.2f ms (all %d clients)" % [n, crowd, client_usec / 1000.0 / ticks, n])
	eq(clients.filter(func(c: GameClient) -> bool: return c.state == "playing").size(), n, "everyone plays")
	server.shutdown()
	world.close()
