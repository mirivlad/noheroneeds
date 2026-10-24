extends TestCase
## ADR-0055: weather is of a place — fronts pass over the land, a wet
## climate rains more; it freezes by the place's warmth: the warm south has
## no snow in winter, the north has it in spring too; crops stand still
## while it freezes there.

const SEED := 4242


func test_it_freezes_by_the_warmth_of_the_place() -> void:
	var winter := Seasons.WINTER * Seasons.SEASON_MS + Daylight.DAY_MS
	var spring := Daylight.DAY_MS
	check(Seasons.freezing(winter) and not Seasons.freezing(spring), "a middling place: winter only")
	check(not Seasons.freezing(winter, 0.9), "the warm south: not even in winter")
	check(Seasons.freezing(spring, -0.9) and Seasons.freezing(winter, -0.9), "the far north: spring too")
	check(not Seasons.freezing(Seasons.SUMMER * Seasons.SEASON_MS, -0.9), "but summer is summer")
	eq(Seasons.frozen_ms(0.0, Seasons.YEAR_MS, 0.0), float(Seasons.SEASON_MS), "a middling year: a season frozen")
	eq(Seasons.frozen_ms(0.0, Seasons.YEAR_MS, 0.9), 0.0, "the south: none")
	check(Seasons.frozen_ms(0.0, Seasons.YEAR_MS, -0.9) >= 3.0 * Seasons.SEASON_MS, "the north: most of the year")


func test_snow_in_the_north_rain_in_the_south() -> void:
	var south_snow := 0.0
	var north_snow := 0.0
	var south_rain := 0.0
	for h in Seasons.YEAR_MS / Daylight.HOUR_MS:
		var t := (h + 0.5) * Daylight.HOUR_MS
		south_snow += Weather.snow(SEED, t, Vector2i.ZERO, Vector2(0.9, 0.0))
		south_rain += Weather.rain(SEED, t, Vector2i.ZERO, Vector2(0.9, 0.0))
		north_snow += Weather.snow(SEED, t, Vector2i.ZERO, Vector2(-0.9, 0.0))
	eq(south_snow, 0.0, "never snow in the warm south")
	check(south_rain > 0.0, "it rains there all year")
	check(north_snow > 0.0, "snow in the north")


func test_a_wet_climate_rains_more_and_fronts_pass() -> void:
	var year := float(Seasons.YEAR_MS)
	var wet := Weather.rain_hours(SEED, 0.0, year, Vector2i.ZERO, Vector2(0.9, 0.8))
	var dry := Weather.rain_hours(SEED, 0.0, year, Vector2i.ZERO, Vector2(0.9, -0.8))
	check(wet > dry * 1.5, "a wet climate rains more: %.0f vs %.0f hours" % [wet, dry])
	# The weather of places far apart differs; of places near, hardly.
	var apart := 0
	var near_most := 0.0
	var times := 200
	for i in times:
		var t := i * 3.7 * Daylight.HOUR_MS
		var here := Weather.wetness(SEED, t, Vector2i(100, 100))
		if absf(here - Weather.wetness(SEED, t, Vector2i(5100, -3000))) > 0.15:
			apart += 1
		near_most = maxf(near_most, absf(here - Weather.wetness(SEED, t, Vector2i(108, 100))))
	check(apart > times / 5, "far apart, another weather: %d of %d" % [apart, times])
	check(near_most < 0.05, "a few cells on, the same: %.3f" % near_most)


func test_crops_grow_through_a_southern_winter() -> void:
	var wheat := {"crop": {"stages": 4, "grow_hours": 48}}
	var sown := float(Seasons.WINTER * Seasons.SEASON_MS)
	var later := sown + 4 * Daylight.DAY_MS
	eq(Crops.stage(wheat, sown, later), 0, "a middling winter: it stands still")
	check(Crops.stage(wheat, sown, later, -1, Vector2i.ZERO, Vector2(0.9, 0.0)) > 0, "in the south it grows")


func test_server_and_client_know_the_same_climate() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var w := ServerWorld.open(tmp_dir().path_join("world.db"), content, {"seed": 2})
	var g := Geography.of(2)
	for at: Vector2i in [Vector2i.ZERO, Vector2i(900, -400), Vector2i(-3000, 2500)]:
		eq(w.climate_at("surface", at), g.climate_at(at.x, at.y), "at %s" % at)
	eq(w.climate_at("underground", Vector2i.ZERO), Vector2.ZERO, "off the surface: mild")
	w.close()


## Rain prevents lighting a new open fire; an existing one still cooks and
## warms. Server refusals and the client's blueprint give the same reason.
func test_rain_blocks_new_fires_but_existing_fires_keep_working() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var w := ServerWorld.open(tmp_dir().path_join("world.db"), content, {"seed": 2})
	var cell := Vector2i(3, 3)
	var c := w.chunk("surface", 0, 0)
	for at: Vector2i in [cell, cell + Vector2i(1, 0), cell + Vector2i(0, 1)]:
		c.set_cell("ground", at.x, at.y, "base:grass")
		c.set_cell("cover", at.x, at.y, "")
		c.set_cell("structure", at.x, at.y, "")
		c.set_cell("ceiling", at.x, at.y, "")
		c.set_cell("roof", at.x, at.y, "")
	c.set_cell("structure", 3, 3, "base:campfire")
	var wet := -1.0
	for h in 2000:
		var t := float(h) * Daylight.HOUR_MS
		if Weather.rain(w.weather_seed, t, cell, w.climate_at("surface", cell)) > 0.6:
			wet = t
			break
	if not check(wet >= 0.0, "a hard rain comes"):
		w.close()
		return
	w.world_time = int(wet)
	var character := PortableCharacter.create("Повар", "base:human_m")
	w.enter("cook", character)
	var actor := character.character_id
	w.move_character(actor, Vector2i(3, 4) * Movement.UNIT + Vector2i(128, 128))
	w.knowledge.all_known = true
	w.knowledge.never_fail = true
	w.grant(actor, "base:raw_meat", 1)
	w.grant(actor, "base:log", 2)
	check(w.station_near(actor, "fire"), "the fire still cooks in hard rain")
	check(w.needs._fire_near("surface", cell) > 0.0, "and warms")
	w.handle(actor, {"type": "craft", "recipe": "base:cook_meat", "request_id": "rain-cooking"})
	w.sync()
	eq(w.inventory(actor).count("base:cooked_meat"), 1, "meat actually cooked")
	w.take_acks()
	w.handle(actor, {"type": "build", "location": "surface", "x": 4, "y": 3,
		"part": "base:campfire", "request_id": "rain-build"})
	w.sync()
	var replies := w.take_acks()
	eq(replies[0][2].get("reason"), "rain", "a new fire is refused explicitly")
	eq(w.inventory(actor).count("base:log"), 2, "no logs wasted")
	var client := GameClient.new(null, null, PackedByteArray(), content)
	client.location = "surface"
	client.weather_seed = w.weather_seed
	client.world_time = w.world_time
	client.geography = Geography.of(2)
	client.chunks[ServerWorld.chunk_key("surface", 0, 0)] = c
	var view := ClientBuildView.new(client)
	eq(BuildRules.check(view, content, "base:campfire", "surface", 4, 3, ""), "rain", "the blueprint agrees")
	c.set_cell("roof", 4, 3, "base:thatch_roof")
	eq(BuildRules.check(view, content, "base:campfire", "surface", 4, 3, ""), "", "under a roof it can be lit")
	w.handle(actor, {"type": "build", "location": "surface", "x": 4, "y": 3,
		"part": "base:campfire", "request_id": "covered-build"})
	w.sync()
	eq(c.get_cell("structure", 4, 3), "base:campfire", "the server allows it under cover too")
	w.close()
