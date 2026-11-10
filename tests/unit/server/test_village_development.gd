extends TestCase
## Daily economic trends, distinct from a single expensive purchase. The
## physical growth of buildings and population is a later stage.

var w: ServerWorld
var home: String
var _db := ""


func before_each() -> void:
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 12345})
	home = String(w.generator.settlements.home_plan()["id"])
	# Isolate one daily need from the surrounding villages' trades.
	w.economy._goods_of[home] = {"makes": {}, "needs": {"base:raw_fish": 1}}
	for other: String in w.economy.neighbours(home):
		w.economy.store_quiet(other)["stock"] = {}
	w.economy.store(home)["stock"] = {"base:raw_fish": 100}


func after_each() -> void:
	w.close()


func _days(n: int) -> void:
	for i in n:
		_day()
		w.economy.store(home)


func _day() -> void:
	var rate := w.time_rate
	w.time_rate = Daylight.DAY_MS
	w.advance_time()
	w.time_rate = rate


func _news() -> Array:
	return (w.chronicles.of(home)["entries"] as Array).filter(func(e: Dictionary) -> bool:
		return String(e["text"]).begins_with("Хозяйство"))


func test_distress_needs_three_days_and_recovers_without_duplicate_news() -> void:
	w.economy.store(home)["coins"] = 0
	_days(2)
	eq(w.economy.development(home)["state"], "stable", "a brief shortage does not change the lasting state")
	eq(_news().size(), 0)
	_days(1)
	eq(w.economy.development(home)["state"], "distressed")
	eq(_news().size(), 1)
	_days(5)
	eq(_news().size(), 1, "continuing distress is told once")
	w.economy.earn(home, 300)
	_days(3)
	eq(w.economy.development(home)["state"], "stable", "three supplied days restore the economy")
	eq(_news().size(), 2)


func test_wealth_without_supplies_does_not_count_as_prosperity() -> void:
	w.economy.store(home)["coins"] = 2000
	w.economy.store(home)["stock"] = {}
	_days(3)
	eq(w.economy.development(home)["state"], "distressed", "coins cannot replace missing goods")
	w.economy.put(home, "base:raw_fish", 100)
	_days(3)
	eq(w.economy.development(home)["state"], "prosperous", "supplies and a rich treasury support prosperity")


func test_a_changed_trend_breaks_the_run_and_same_day_reads_do_not_count() -> void:
	w.economy.store(home)["coins"] = 0
	_days(2)
	w.economy.earn(home, 300)
	_days(1)
	w.economy.earn(home, -300)
	_days(1)
	for i in 20:
		w.economy.development(home)
	eq(w.economy.development(home)["days"], 1, "one observation per day")
	_days(1)
	eq(w.economy.development(home)["state"], "stable", "interrupted days are not combined")
	_days(1)
	eq(w.economy.development(home)["state"], "distressed")


func test_paid_deliveries_are_counted_before_the_daily_assessment() -> void:
	var other: String = w.economy.neighbours(home)[0]
	w.economy.store_quiet(other)["stock"] = {"base:raw_fish": 100}
	w.economy.store(home)["stock"] = {}
	_days(3)
	eq(w.economy.development(home)["state"], "stable", "available imports prevent a lasting shortage")
	check(w.economy.have(home, "base:raw_fish") >= 2, "the delivery is in the store")


func test_catch_up_matches_daily_steps_and_dates_its_news() -> void:
	w.economy.store(home)["coins"] = 0
	_days(4)
	var expected := w.economy.development(home)
	var expected_news := _news().duplicate(true)
	# Restart the same economic fixture at day zero, leaving the world clock
	# four days ahead so a single query must simulate those four days.
	w.economy._stores.erase(home)
	w.note_fact("economy|" + home, JSON.stringify({"day": 0, "stock": {"base:raw_fish": 100}, "coins": 0}))
	w.chronicles.of(home)["entries"] = []
	eq(w.economy.development(home), expected, "catch-up observes every simulated day")
	eq(_news(), expected_news, "historical transitions retain their simulated date")


func test_trend_survives_reopening_the_world() -> void:
	w.economy.store(home)["coins"] = 0
	_days(2)
	w.close()
	w = ServerWorld.open(_db, ContentRegistry.load_packs(["res://content/base"]))
	eq(w.economy.development(home)["days"], 2, "the partial run is saved")
	_days(1)
	eq(w.economy.development(home)["state"], "distressed", "the third day after restart completes it")
	eq(_news().size(), 1)
	w.close()
	w = ServerWorld.open(_db, ContentRegistry.load_packs(["res://content/base"]))
	_days(1)
	eq(w.economy.development(home)["state"], "distressed", "the confirmed state survives too")
	eq(_news().size(), 1, "reopening does not announce the same state again")


func test_threshold_balances_are_stable_and_less_wealth_is_not_recovery() -> void:
	w.economy.store(home)["coins"] = 60
	_days(3)
	eq(w.economy.development(home)["state"], "stable", "exactly 60 is not a poor treasury")
	w.economy.store(home)["coins"] = 900
	_days(3)
	eq(w.economy.development(home)["state"], "stable", "exactly 900 is not a rich treasury")
	w.economy.store(home)["coins"] = 901
	_days(3)
	eq(w.economy.development(home)["state"], "prosperous")
	w.economy.store(home)["coins"] = 900
	_days(3)
	eq(w.economy.development(home)["state"], "stable")
	check(not String(_news()[-1]["text"]).contains("восстановилось"), "a smaller rich treasury is not recovery from distress")


func test_active_village_lives_without_a_trade_or_talk_request() -> void:
	w.economy.store(home)["coins"] = 0
	var villager := w.creatures._spawn("base:villager", "surface", Vector2i.ZERO, {}, 7)
	villager.job = {"village": home, "home": 0, "profession": "base:farmer"}
	for i in 3:
		_day()
		w.chronicles.step()
	var saved: Dictionary = JSON.parse_string(w.fact("economy|" + home))
	eq(saved["development"]["state"], "distressed", "the server's normal chronicle step advances the economy")


func test_long_absence_is_bounded_and_does_not_extend_an_old_streak() -> void:
	w.economy.store(home)["coins"] = 0
	_days(2)
	w.world_time += 100 * Daylight.DAY_MS
	var d := w.economy.development(home)
	eq(d["days"], 3, "the counter saturates at the confirmation threshold")
	eq(d["day"], 102, "the economy catches up to the current day")
	eq(int(w.economy.store(home)["stock"]["base:raw_fish"]), 88, "only ten missed days consume stock")
	eq(int(_news()[0]["at"]), 95 * Daylight.DAY_MS, "the skipped interval does not complete the previous two-day run")


func test_two_clients_hear_the_same_economic_news() -> void:
	var net := MemoryTransport.MemoryNetwork.new()
	var keys := _db.get_base_dir().path_join("keys")
	var server := GameServer.new(w, net.server(), PlayerIdentity.load_or_create(keys.path_join("server")))
	server.wait_for_disk = true
	var clients: Array[GameClient] = []
	for who: String in ["Аня", "Боря"]:
		var identity := PlayerIdentity.load_or_create(keys.path_join(who))
		var pc := PortableCharacter.create(who, "base:human_m")
		pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
		clients.append(GameClient.new(net.client(), identity, CharacterFile.export_signed(pc, identity, w.content), w.content))
	for i in 30:
		server.step()
		for client: GameClient in clients:
			client.step()
	for client: GameClient in clients:
		if not eq(client.state, "playing", client.reject_reason):
			return
	var npc := w.creatures._spawn("base:villager", "surface", Movement.cell_of(w.spawn_position), {}, 7)
	npc.job = {"village": home, "home": 0, "profession": "base:farmer"}
	npc.next_think = 1 << 40
	w.economy.store(home)["coins"] = 0
	var rate := w.time_rate
	w.time_rate = Daylight.DAY_MS
	for i in 3:
		server.step()
		for client: GameClient in clients:
			client.step()
	w.time_rate = rate
	var requests: Array[String] = []
	for client: GameClient in clients:
		w.move_character(client.character_id, npc.pos)
		requests.append(client.request({"type": "talk", "creature": npc.id}))
	for i in 10:
		server.step()
		for client: GameClient in clients:
			client.step()
	var heard: Array = []
	for i in clients.size():
		var result: Dictionary = clients[i].results.get(requests[i], {})
		check(result.get("ok", false), "talk through the normal request/ack protocol: %s" % str(result))
		heard.append((result.get("chronicle", []) as Array).filter(func(text: String) -> bool: return text.contains("Хозяйство")))
	eq((heard[0] as Array).size(), 1, "the daily change is visible in conversation")
	eq(heard[0], heard[1], "both clients receive the same authoritative history")
	eq(_news().size(), 1, "talking does not duplicate the event")
