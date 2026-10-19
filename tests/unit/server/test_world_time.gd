extends TestCase
## ADR-0014: one clock for the world, kept across restarts, sent to clients.

var _db := ""


func before_each() -> void:
	_db = tmp_dir().path_join("world.db")


func _open() -> ServerWorld:
	return ServerWorld.open(_db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 2})


func test_time_goes_on_and_survives_a_restart() -> void:
	var w := _open()
	eq(w.world_time, Daylight.START_MS, "a new world: morning")
	for i in 200:
		w.tick = i
		w.advance_time()
	var t := w.world_time
	eq(t, Daylight.START_MS + 200 * Daylight.rate_for(24))
	w.close()
	var again := _open()
	eq(again.world_time, t, "the clock is where it was")
	again.set_day_minutes(48)
	var before := again.world_time
	again.advance_time()
	eq(again.world_time - before, Daylight.rate_for(48), "a longer day: a slower clock, the hour kept")
	again.close()


func test_light_where_it_is() -> void:
	var w := _open()
	w.grant("b", "base:plank", 10)
	w.grant("b", "base:log", 2)
	for r: Dictionary in [{"type": "build", "location": "surface", "x": 4, "y": 4, "part": "base:wood_ceiling"},
			{"type": "build", "location": "surface", "x": 9, "y": 4, "part": "base:torch"}]:
		r["request_id"] = Uuid.v4()
		w.handle("b", r)
	w.sync()
	w.world_time = 12 * Daylight.HOUR_MS
	eq(w.light_at("surface", Vector2i(0, 4)), 1.0, "noon outdoors")
	check(w.light_at("surface", Vector2i(4, 4)) < 0.5, "under the ceiling")
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS
	eq(w.light_at("surface", Vector2i(0, 4)), Daylight.NIGHT_LIGHT, "night, far from the torch")
	check(w.light_at("surface", Vector2i(10, 4)) > 0.7, "night, by the torch")
	w.close()


func test_clients_get_the_time() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var keys := tmp_dir().path_join("keys")
	var me := PlayerIdentity.load_or_create(keys.path_join("p"))
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var g := LocalGame.start(_db, content, me, PlayerIdentity.load_or_create(keys.path_join("s")),
		CharacterFile.export_signed(c, me, content))
	g.world.set_day_minutes(10)
	for i in 40:
		g.step()
	check(g.client.has_time, "the time came")
	eq(g.client.time_rate, Daylight.rate_for(10), "and its pace")
	check(absf(g.client.world_time - g.world.world_time) <= g.world.time_rate * 3, "the same clock: %d vs %d" % [g.client.world_time, g.world.world_time])
	g.close()
