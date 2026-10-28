extends TestCase
## ADR-0032: satiety goes down with time and work, food brings it back,
## hungry one does not heal, starving one loses health but not the last.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 4})


func after_each() -> void:
	w.close()


func _player() -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


## The world's clock on by `hours`, needs stepped as the server does each second.
## Time goes on a minute a step; `warm`: one is kept warm (what is measured
## is something else, not the weather's cold, ADR-0055).
func _hours(hours: float, warm := "") -> void:
	var steps := int(hours * 60)
	for i in steps:
		w.world_time += Daylight.HOUR_MS / 60
		if warm != "":
			w.needs.set_warmth(warm, Needs.FULL)
		w.needs.step()


func test_satiety_goes_down_with_time_and_work() -> void:
	var a := _player()
	w.needs.step()
	eq(w.needs.satiety_of(a), Needs.FULL, "one comes full")
	_hours(18.0, a)
	check(absf(w.needs.satiety_of(a) - 50.0) < 1.0, "half in eighteen hours: %.1f" % w.needs.satiety_of(a))
	var before := w.needs.satiety_of(a)
	for i in 4:
		w.combat.swung(a, Vector2i.ZERO)
	check(absf(before - w.needs.satiety_of(a) - 1.0) < 0.01, "four blows: one")
	eq(w.needs.shown(a).get("satiety"), int(ceilf(w.needs.satiety_of(a))), "the player is told a whole number")


func test_food_fills_and_full_ones_do_not_eat() -> void:
	var a := _player()
	w.grant(a, "base:bread", 3)
	eq(_req(a, {"type": "eat", "item": "base:bread"}).get("reason"), "not_hungry", "full and whole: no")
	w.needs.set_satiety(a, 30.0)
	var r := _req(a, {"type": "eat", "item": "base:bread"})
	eq(r.get("satiety"), 70, "bread: forty")
	w.needs.set_satiety(a, 90.0)
	check(_req(a, {"type": "eat", "item": "base:bread"}).get("ok", false), "not full: one may eat")
	eq(w.needs.satiety_of(a), Needs.FULL, "never above full")


func test_the_hungry_do_not_heal_and_hunger_does_not_kill() -> void:
	var a := _player()
	w.combat.hurt(a, 10, "")
	w.needs.set_satiety(a, 10.0)
	for t in range(1, 600):
		w.combat.step(t)
	eq(w.combat.health_of(a), 10, "hungry: no health back")
	w.needs.set_satiety(a, 60.0)
	for t in range(600, 900):
		w.combat.step(t)
	check(w.combat.health_of(a) > 10, "fed: it comes back")
	w.needs.set_satiety(a, 0.0)
	w.combat.hurt(a, w.combat.health_of(a) - 3, "")
	eq(w.combat.health_of(a), 3)
	_hours(1.5)
	eq(w.combat.health_of(a), 2, "starving: one an hour")
	_hours(10.0)
	eq(w.combat.health_of(a), 1, "but never the last")
	eq(int(w.present[a].get("deaths", 0)), 0, "not dead of hunger")


func test_satiety_is_kept_and_death_does_not_starve() -> void:
	var a := _player()
	w.needs.set_satiety(a, 33.0)
	w.leave(a)
	w.sync()
	w.close()
	w = ServerWorld.open(_db, _content)
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.character_id = a
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + a, c)
	eq(w.needs.satiety_of(a), 33.0, "kept across leaving and a restart")
	w.needs.set_satiety(a, 5.0)
	w.combat.hurt(a, 100, "")
	eq(w.needs.satiety_of(a), Needs.AFTER_DEATH, "after death: half full")


## A world time (on day 2 or later) at `hour`-ish when it does or does not rain.
func _when(night: bool, raining: bool) -> int:
	for h in range(24, 24 * 60):
		var t := h * Daylight.HOUR_MS + Daylight.HOUR_MS / 2
		if Daylight.is_night(t) == night and (Weather.rain(w.weather_seed, t) > 0.8) == raining \
				and (raining or Weather.rain(w.weather_seed, t) == 0.0):
			return t
	return -1


func _clear_round(a: String) -> Vector2i:
	var at := Movement.cell_of(w.present[a]["pos"])
	for y in range(at.y - 4, at.y + 5):
		for x in range(at.x - 4, at.x + 5):
			var cx := floori(x / 32.0)
			var cy := floori(y / 32.0)
			var c := w.chunk(w.present[a]["location"], cx, cy)
			for l: String in ["structure", "ceiling", "roof", "cover"]:
				c.set_cell(l, x - cx * 32, y - cy * 32, "")
	return at


func test_the_night_and_the_rain_chill_clothes_roofs_and_fires_warm() -> void:
	var a := _player()
	var at := _clear_round(a)
	var loc := String(w.present[a]["location"])
	for slot: String in (w.present[a]["appearance"].get("worn", {}) as Dictionary).keys():
		_req(a, {"type": "unequip", "slot": slot})
	eq(w.needs.clothes_warmth(a), 0, "nothing on")
	w.world_time = _when(true, false)
	check(w.world_time > 0, "a dry night")
	eq(w.needs.warming(a), -Needs.NIGHT_CHILL, "a dry night outdoors, bare: twelve an hour")
	for item: String in ["base:linen_shirt", "base:work_trousers", "base:boots", "base:wool_cloak"]:
		w.grant(a, item, 1)
		_req(a, {"type": "equip", "item": item})
	eq(w.needs.clothes_warmth(a), 6)
	check(absf(w.needs.warming(a) + Needs.NIGHT_CHILL * 0.28) < 0.01, "dressed: much of it kept off (%.2f)" % w.needs.warming(a))
	var cx := floori(at.x / 32.0)
	var cy := floori(at.y / 32.0)
	w.chunk(loc, cx, cy).set_cell("structure", at.x + 2 - cx * 32, at.y - cy * 32, "base:campfire")
	check(w.needs.warming(a) > 30.0, "by a fire: warm even at night (%.1f)" % w.needs.warming(a))
	w.chunk(loc, cx, cy).set_cell("structure", at.x + 2 - cx * 32, at.y - cy * 32, "")
	w.chunk(loc, cx, cy).set_cell("ceiling", at.x - cx * 32, at.y - cy * 32, "base:wood_ceiling")
	check(w.sheltered(loc, at.x, at.y), "under a ceiling")
	eq(w.needs.warming(a), Needs.SHELTER_WARMS, "under a roof the night does not reach")
	w.chunk(loc, cx, cy).set_cell("ceiling", at.x - cx * 32, at.y - cy * 32, "")
	w.world_time = _when(false, true)
	check(w.world_time > 0, "a rainy day")
	check(w.needs.warming(a) < -3.0, "rain by day chills too, through clothes (%.1f)" % w.needs.warming(a))
	w.world_time = _when(false, false)
	eq(w.needs.warming(a), Needs.DAY_WARMS, "a dry day warms")


func test_the_cold_burns_food_stops_healing_and_freezes_but_not_to_death() -> void:
	var a := _player()
	_clear_round(a)
	for slot: String in (w.present[a]["appearance"].get("worn", {}) as Dictionary).keys():
		_req(a, {"type": "unequip", "slot": slot})
	w.world_time = _when(true, false)
	w.needs.step()
	w.needs.set_warmth(a, 20.0)
	check(not w.needs.may_heal(a), "cold: no health back")
	var before := w.needs.satiety_of(a)
	w.world_time += Daylight.HOUR_MS / 60
	w.needs.step()
	check(before - w.needs.satiety_of(a) > Needs.FULL / Needs.EMPTY_HOURS / 60.0 * 1.4, "the cold burns food faster")
	w.needs.set_warmth(a, 0.0)
	w.combat.hurt(a, 17, "")
	eq(w.combat.health_of(a), 3)
	for i in 3 * 60:
		w.world_time += Daylight.HOUR_MS / 60
		w.needs.step()
		w.needs.set_warmth(a, 0.0)  # it keeps freezing
	eq(w.combat.health_of(a), 1, "freezing takes health, but not the last")
	eq(w.needs.shown(a).get("warmth"), 0, "and the player is told")


func test_energy_runs_down_and_a_bed_brings_it_back() -> void:
	var a := _player()
	var at := _clear_round(a)
	var loc := String(w.present[a]["location"])
	w.needs.step()
	_hours(20.0, a)
	check(absf(w.needs.energy_of(a) - 50.0) < 1.0, "half in twenty hours: %.1f" % w.needs.energy_of(a))
	check(w.needs.may_run(a), "not tired yet")
	w.needs.set_energy(a, 10.0)
	check(not w.needs.may_run(a), "tired: no running")
	var cx := floori(at.x / 32.0)
	var cy := floori(at.y / 32.0)
	w.chunk(loc, cx, cy).set_cell("structure", at.x + 1 - cx * 32, at.y - cy * 32, "base:bed")
	var bed := {"type": "sleep", "location": loc, "x": at.x + 1, "y": at.y}
	eq(_req(a, {"type": "sleep", "location": loc, "x": at.x, "y": at.y}).get("reason"), "not_a_bed")
	check(_req(a, bed.duplicate()).get("ok", false), "into bed")
	check(w.needs.asleep(a), "asleep")
	eq(Movement.cell_of(w.present[a]["pos"]), Vector2i(at.x + 1, at.y), "lying on the bed")
	var b := _player()
	w.move_character(b, w.present[a]["pos"])
	w.needs.set_energy(b, 10.0)
	eq(_req(b, bed.duplicate()).get("reason"), "someone_there", "a bed sleeps one")
	w.leave(b)
	_hours(1.0, a)
	check(w.needs.energy_of(a) > 40.0, "an hour in bed: %.1f" % w.needs.energy_of(a))
	w.combat.hurt(a, 1, "")
	check(not w.needs.asleep(a), "a blow wakes one")
	check(_req(a, bed.duplicate()).get("ok", false), "back to bed")
	_hours(3.0, a)  # full in about an hour and a half, then up and about
	check(w.needs.energy_of(a) > 95.0, "rested: %.1f" % w.needs.energy_of(a))
	check(not w.needs.asleep(a), "and up by oneself")
	eq(_req(a, bed.duplicate()).get("reason"), "not_tired", "rested ones do not lie down")


func test_winter_is_colder_and_summer_nights_milder() -> void:
	var a := _player()
	_clear_round(a)
	for slot: String in (w.present[a]["appearance"].get("worn", {}) as Dictionary).keys():
		_req(a, {"type": "unequip", "slot": slot})
	var at := func(season: int, night: bool) -> float:
		for h in 24 * Seasons.DAYS:
			var t := season * Seasons.SEASON_MS + h * Daylight.HOUR_MS + Daylight.HOUR_MS / 2
			if Daylight.is_night(t) == night and Weather.precipitation(w.weather_seed, t) == 0.0:
				w.world_time = t
				return w.needs.warming(a)
		return 0.0
	eq(at.call(Seasons.SPRING, true), -Needs.NIGHT_CHILL)
	eq(at.call(Seasons.SUMMER, true), -Needs.NIGHT_CHILL * 0.5, "summer nights half as cold")
	check(at.call(Seasons.WINTER, true) < -Needs.NIGHT_CHILL * 2.0, "winter nights much colder")
	check(at.call(Seasons.WINTER, false) < 0.0, "and winter days cold too")
	eq(at.call(Seasons.SUMMER, false), Needs.DAY_WARMS, "a summer day warms")


## Sitting (RO's sit, Insert): energy comes back a little, health twice as
## fast; a blow gets one up; asked again, one stands.
func test_sitting_rests_and_heals_faster() -> void:
	var a := _player()
	w.needs.set_energy(a, 40.0)
	eq(_req(a, {"type": "sit"}).get("sitting"), true, "sat down")
	check(w.sitting(a), "sitting")
	_hours(1.0, a)
	check(w.needs.energy_of(a) > 40.0, "energy comes back sitting: %.1f" % w.needs.energy_of(a))
	var healed := func(sits: bool) -> int:
		w.combat.hurt(a, w.combat.health_of(a) - 5, "")
		if sits:
			w.present[a]["sitting"] = true  # (a blow gets one up: sat again to measure)
		w.combat._hurt_at[a] = 0
		for t in range(1, 300):
			w.combat.step(t)
		w.present[a].erase("sitting")
		return w.combat.health_of(a) - 5
	var sat: int = healed.call(true)
	var stood: int = healed.call(false)
	check(sat > stood and sat > 0, "twice as fast sitting: %d against %d" % [sat, stood])
	w.present[a]["sitting"] = true
	w.combat.hurt(a, 1, "")
	check(not w.sitting(a), "a blow gets one up")
	_req(a, {"type": "sit"})
	eq(_req(a, {"type": "sit"}).get("sitting"), false, "asked again: up")
