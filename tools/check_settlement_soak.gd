extends SceneTree
## Sustained, controlled economy cycle through GameServer and two real clients.
## godot --headless --audio-driver Dummy --path . -s res://tools/check_settlement_soak.gd -- --out=build/settlement-soak

var world: ServerWorld
var server: GameServer
var clients: Array[GameClient] = []
var registry: ContentRegistry
var identities: Array[PlayerIdentity] = []
var characters: Array[PackedByteArray] = []
var server_identity: PlayerIdentity
var db := ""
var village := ""
var centre := Vector2i.ZERO
var output := ""
var checks := 0
var failures: Array[String] = []
var daily: Array = []
var baseline_geography := ""
var base_homes := 0


func _initialize() -> void:
	call_deferred("run")


func verify(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)


func connect_clients() -> void:
	var net := MemoryTransport.MemoryNetwork.new()
	server = GameServer.new(world, net.server(), server_identity)
	server.wait_for_disk = true
	server.unload_after_ticks = 40
	clients.clear()
	for i in identities.size():
		clients.append(GameClient.new(net.client(), identities[i], characters[i], registry))
	for i in 60:
		tick()
	for c: GameClient in clients:
		verify(c.state == "playing", "two clients join normally: " + c.reject_reason)
		world.move_character(c.character_id, (centre + Vector2i(2, 2)) * Movement.UNIT + Vector2i(128, 128))
	for i in 60:
		tick()


func tick() -> void:
	server.step()
	for c: GameClient in clients:
		c.step()


func audit(day_number: int) -> void:
	var s := world.settlement_population.state(village)
	verify(int(s["population"]) == base_homes + (s["homes"] as Array).size() - (s["dead"] as Dictionary).size() - (s["departed"] as Dictionary).size(), "population accounting on day " + str(day_number))
	var alive := {}
	for c: Creature in world.creatures.creatures.values():
		if String(c.job.get("village", "")) != village or c.job.has("hospitality") or not c.route.is_empty():
			continue
		var slot := str(int(c.job.get("home", -1)))
		if int(slot) < 0:
			continue
		verify(not alive.has(slot), "one live resident per home on day " + str(day_number))
		alive[slot] = c.id
		verify(not (s["departed"] as Dictionary).has(slot) and not (s["dead"] as Dictionary).has(slot), "departed/dead identity does not respawn on day " + str(day_number))
		verify(String(s["residents"].get(slot, "")) == c.id, "registered UUID matches live entity on day " + str(day_number))
	verify(int(world.economy.store(village)["coins"]) >= 0, "nonnegative treasury on day " + str(day_number))
	var damaged := 0
	for departure: Dictionary in (s["departed"] as Dictionary).values():
		damaged += (departure["damage"] as Array).size()
	daily.append({"day": day_number, "population": s["population"], "homes": (s["homes"] as Array).size(),
		"leaving": (s["leaving"] as Dictionary).size(), "departed": (s["departed"] as Dictionary).size(),
		"dead": (s["dead"] as Dictionary).size(), "damaged_roof_cells": damaged,
		"coins": world.economy.store(village)["coins"], "loaded_chunks": world.loaded_chunks(),
		"condition": world.economy.development(village).duplicate(true)})


func fund(coins: int) -> void:
	var store := world.economy.store(village)
	store["coins"] = coins
	for item: String in world.economy.needs(village):
		store["stock"][item] = 10000
	for item: String in ["base:plank", "base:log", "base:cloth", "base:stone"]:
		store["stock"][item] = 10000
	world.economy._save(village)


func run() -> void:
	output = ProjectSettings.globalize_path("res://build/settlement-soak")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output)
	db = output.path_join("world.db")
	if FileAccess.file_exists(db):
		printerr("Use a new output directory; a soak run does not replace an existing world")
		quit(1)
		return
	var began := Time.get_ticks_usec()
	registry = ContentRegistry.load_packs(["res://content/base"])
	world = ServerWorld.open(db, registry, {"seed": 7, "require_planned": true, "preset": "small", "climate": "temperate"})
	if world == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	var plans := world.generator.settlements.villages(0, 0, 0)
	if plans.is_empty():
		world.close()
		quit(1)
		return
	var plan: Dictionary = plans[0]
	village = String(plan["id"])
	centre = plan["fire"]
	base_homes = (plan["homes"] as Array).size()
	baseline_geography = world.store.read_meta("world_plan")
	world.time_rate = 0
	for home: Dictionary in plan["homes"]:
		var bed: Vector2i = home["bed"]
		world.chunk("surface", bed.x >> 5, bed.y >> 5)
	server_identity = PlayerIdentity.load_or_create(output.path_join("keys/server"))
	for i in 2:
		var key := PlayerIdentity.load_or_create(output.path_join("keys/client-" + str(i)))
		var pc := PortableCharacter.create("Наблюдатель " + str(i), "base:human_ro_m")
		pc.styles = {"hair": "base:human_hair_bald"}
		identities.append(key)
		characters.append(CharacterFile.export_signed(pc, key, registry))
	connect_clients()
	fund(10000)
	for d in range(1, 121):
		# Only scenario inputs change. The normal hourly/daily server path
		# performs every economic, construction and population transition.
		if d in [8, 51, 101]: fund(500)
		if d == 20: fund(0)
		if d == 81: fund(10000)
		for c: Creature in world.creatures.creatures.values().duplicate():
			if String(registry.get_def(c.kind).get("behavior", "")) == "predator":
				world.creatures.remove(c.id)
		for c: GameClient in clients:
			var player: Dictionary = world.present[c.character_id]
			player["satiety"] = Needs.FULL
			player["warmth"] = Needs.FULL
			player["energy"] = Needs.FULL
		if d in [35, 40]:
			for c: GameClient in clients:
				var at := centre + (Vector2i(300, 0) if d == 35 else Vector2i(2, 2))
				world.move_character(c.character_id, at * Movement.UNIT + Vector2i(128, 128))
		world.time_rate = Daylight.DAY_MS / 160
		for i in 160:
			tick()
		world.time_rate = 0
		audit(d)
		if d % 10 == 0:
			print("SOAK ", JSON.stringify(daily[-1]))
		if d == 60:
			var previous := world.settlement_population.state(village).duplicate(true)
			server.shutdown()
			world.close()
			world = ServerWorld.open(db, registry)
			verify(world != null, "world reopens halfway through the run")
			if world == null:
				quit(1)
				return
			verify(world.settlement_population.state(village) == previous, "all household records survive reopening")
			world.time_rate = 0
			connect_clients()
	verify(daily.any(func(s: Dictionary) -> bool: return int(s["homes"]) > 0), "simulation built permanent housing")
	verify(daily.any(func(s: Dictionary) -> bool: return int(s["population"]) > base_homes), "new housing received real residents")
	verify(daily.any(func(s: Dictionary) -> bool: return int(s["departed"]) > 0), "sustained poverty caused departures")
	verify(daily.any(func(s: Dictionary) -> bool: return int(s["damaged_roof_cells"]) > 0), "empty housing deteriorated")
	verify(int(daily[79]["departed"]) == 0 and int(daily[79]["damaged_roof_cells"]) == 0, "stable recovery restored the departed households and roofs")
	verify(world.store.read_meta("world_plan") == baseline_geography, "120 simulated days preserve geography")
	verify(world.sync() and world.store.integrity_ok(), "final SQLite integrity and durable operations")
	var report := {"controlled_setup": true, "setup": "two MemoryTransport clients; actual production/needs; day=160 server ticks; injected treasury and initial stocks at phase boundaries; witnesses replenished daily; predators excluded from this economic scenario", "days": 120, "server_ticks_in_days": 19200,
		"seed": 7, "preset": "small", "climate": "temperate", "village": village, "checks": checks,
		"failures": failures, "wall_seconds": (Time.get_ticks_usec() - began) / 1000000.0, "history": daily, "source_sha256": {}}
	for path: String in ["tools/check_settlement_soak.gd", "src/server/settlement_life.gd", "src/server/settlement_population.gd", "src/server/creature_sim.gd", "src/server/village_economy.gd", "src/server/game_server.gd", "src/server/server_world.gd"]:
		report["source_sha256"][path] = FileAccess.get_sha256("res://" + path)
	server.shutdown()
	world.close()
	FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("SOAK_RESULT ", JSON.stringify({"days": 120, "checks": checks, "failures": failures, "wall_seconds": report["wall_seconds"]}))
	Art.clear()
	quit(0 if failures.is_empty() else 1)
