extends TestCase
## A caravan's stop in a village (ADR-0068): it arrives, stands where the
## whole harness fits, trades, rests and only then sets off back. The stop is
## measured in game time and saved in the job, so a restart in the middle of
## it does not send the caravan away at once. The trader is there to talk to
## all the while.

var w: ServerWorld
var road: Dictionary
var trader: Creature
var actor: String
var db: String


func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 11})
	var chunk := w.chunk("surface", 5, 5)
	for id: String in w.creatures.in_chunk("surface", 5, 5):
		w.creatures.remove(id)
	for y in 32:
		for x in 32:
			chunk.set_cell("ground", x, y, "base:grass")
			for layer: String in ["cover", "structure", "roof"]:
				chunk.set_cell(layer, x, y, "")
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var home_id := String(s.home_plan()["id"])
	var roads := s.roads_of(0, district.x, district.y)
	for r: Dictionary in roads:
		if String(r["from"]) != home_id and String(r["to"]) != home_id:
			road = r.duplicate()
			break
	if road.is_empty():
		road = (roads[0] as Dictionary).duplicate()
	var path: Array = []
	for x in range(164, 185):
		path.append(Vector2i(x, 170))
	road["path"] = path
	var key: Array = road["key"]
	s._roads["%d|%d|%d|%d" % [key[0], key[1], key[2], key[3]]] = road
	trader = w.creatures._spawn("base:villager", "surface", Vector2i(164, 170), {}, 3)
	trader.route = {"road": road["key"], "i": 0, "step": 1}
	trader.job = {"profession": "base:trader", "purse": 600, "name": "Гордей",
		"from": road["from"], "toward": road["to"]}
	w.creatures._make_caravan(trader, "cart")
	w.inventory("trade|" + trader.id).add("base:iron_sword", 2)
	var pc := PortableCharacter.create("Охранник", "base:human_ro_m")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("key", pc)
	actor = pc.character_id
	w.move_character(actor, trader.pos + Vector2i(128, 0))
	w.world_time = 12 * Daylight.HOUR_MS


func after_each() -> void:
	w.close()


func _step(n := 1) -> void:
	for i in n:
		w.tick += 1
		w.mark_needed("surface", 5, 5)
		if trader != null:
			var at := trader.cell()
			for cy in range((at.y >> 5) - 1, (at.y >> 5) + 2):
				for cx in range((at.x >> 5) - 1, (at.x >> 5) + 2):
					w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)


func _phase() -> String:
	return String(trader.job.get("caravan_state", "travel"))


func _run_until(phase: String, limit: int) -> bool:
	for i in limit:
		if _phase() == phase:
			return true
		_step()
	return _phase() == phase


func _run_until_from(village: String, limit: int) -> bool:
	for i in limit:
		if String(trader.job.get("from", "")) == village:
			return true
		_step()
	return String(trader.job.get("from", "")) == village


func test_stop_checks_fire_and_other_caravan_reservations() -> void:
	var at := Vector2i(174, 170)
	var centre := at * Movement.UNIT + Vector2i(128, 128)
	var heading := Vector2.RIGHT
	check(w.creatures._caravan_stop_clear(trader, centre, heading), "the empty place fits")
	var chunk := w.chunk("surface", at.x >> 5, at.y >> 5)
	chunk.set_cell("structure", at.x & 31, at.y & 31, "base:campfire")
	check(not w.creatures._caravan_stop_clear(trader, centre, heading), "a non-solid fire cannot be under the cart")
	chunk.set_cell("structure", at.x & 31, at.y & 31, "")
	chunk.set_cell("structure", (at.x + 2) & 31, at.y & 31, "base:wood_door")
	check(not w.creatures._caravan_stop_clear(trader, centre, heading), "a cart cannot block access to a door")
	chunk.set_cell("structure", (at.x + 2) & 31, at.y & 31, "")
	var saved_cells: Dictionary = road["cells"]
	road["cells"] = {at: {}}
	check(not w.creatures._caravan_stop_clear(trader, centre, heading), "a cart cannot park over a road")
	road["cells"] = saved_cells
	var other := w.creatures._spawn("base:villager", "surface", Vector2i(180, 175), {}, 4)
	other.job = {"caravan_state": "arriving", "caravan_goal": [at.x, at.y]}
	check(not w.creatures._caravan_stop_clear(trader, centre, heading), "a goal already reserved by another caravan is unavailable")
	other.job = {"caravan_state": "departing", "caravan_stop": [at.x, at.y]}
	check(not w.creatures._caravan_stop_clear(trader, centre, heading), "a departing caravan keeps its place until it moves away")
	other.job = {"caravan_state": "travel", "horse": "horse-id"}
	other.pos = centre
	check(not w.creatures._caravan_stop_clear(trader, centre, heading), "a moving cart still occupies its present place")
	other.job = {"caravan_state": "arriving", "caravan_goal": [at.x, at.y]}
	var second := at + Vector2i(13, 0)
	var second_centre := second * Movement.UNIT + Vector2i(128, 128)
	for direction: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		check(w.creatures._caravan_stop_clear(trader, second_centre, direction), "a separate place remains free for heading %s" % direction)
	var another := w.creatures._spawn("base:villager", "surface", Vector2i(180, 176), {}, 5)
	another.job = {"caravan_state": "trading", "caravan_stop": [second.x, second.y]}
	check(not w.creatures._caravan_stop_clear(trader, second_centre, heading), "the second place is reserved while trading")


func test_occupied_berths_use_the_connected_reserve() -> void:
	var home: Dictionary = w.generator.settlements.home_plan()
	var area: Rect2i = (home["bounds"] as Rect2i).grow(8)
	for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
		for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
			w.chunk("surface", cx, cy)
	var start: Vector2i = home["ends"][0]
	trader.pos = start * Movement.UNIT + Vector2i(128, 128)
	road["to"] = home["id"]
	var parking: Array = home["parking"]
	for index in 2:
		var other := w.creatures._spawn("base:villager", "surface", start, {}, index + 40)
		var reserved: Vector2i = parking[index]
		other.job = {"caravan_state": "trading", "caravan_stop": [reserved.x, reserved.y]}
	var fallback: Vector2i = parking[2]
	eq(w.creatures._caravan_stop_spot(trader), fallback, "both occupied berths lead to the separate reserve")
	for spot: Vector2i in parking:
		check(not w.creatures._caravan_route(trader, spot, 16).is_empty(), "the cart and horse have a route to %s" % spot)


func test_two_caravans_reserve_and_trade_at_distinct_berths() -> void:
	var home: Dictionary = w.generator.settlements.home_plan()
	var area: Rect2i = (home["bounds"] as Rect2i).grow(8)
	for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
		for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
			w.chunk("surface", cx, cy)
	# Loading roads may spawn unrelated traders; isolate the two under test.
	for spawned: Creature in w.creatures.creatures.values():
		if spawned != trader and String(spawned.job.get("horse", "")) != "":
			w.creatures.remove(String(spawned.job["horse"]))
			w.creatures.remove(spawned.id)
	road["to"] = home["id"]
	var places: Array = home["parking"]
	var first: Vector2i = places[0]
	var second: Vector2i = places[1]
	trader.pos = first * Movement.UNIT + Vector2i(128, 128)
	trader.job["caravan_heading"] = [0, 1]
	trader.job["horse_heading"] = [0, 1]
	w.creatures._move_caravan_horse(trader)
	w.creatures._caravan_arrive(trader)
	eq(w.creatures._caravan_goal(trader), first, "the first caravan reserves its berth")
	var other := w.creatures._spawn("base:villager", "surface", second, {}, 91)
	other.route = {"road": road["key"], "i": 0, "step": 1}
	other.job = {"profession": "base:trader", "purse": 600, "name": "Другой", "from": road["from"], "toward": road["to"]}
	w.creatures._make_caravan(other, "cart")
	other.job["caravan_heading"] = [0, 1]
	other.job["horse_heading"] = [0, 1]
	w.creatures._move_caravan_horse(other)
	var second_centre := second * Movement.UNIT + Vector2i(128, 128)
	check(w.creatures._fits(other, second), "the second trader fits")
	check(w.creatures._caravan_cart_fits(other, second_centre, Vector2.DOWN), "the second cart fits")
	check(w.creatures._caravan_horse_fits(other, second_centre, Vector2.DOWN), "the second horse fits")
	check(w.creatures._caravan_stop_clear(other, second_centre, Vector2.DOWN), "the second berth is clear")
	w.creatures._caravan_arrive(other)
	eq(w.creatures._caravan_goal(other), second, "the second caravan takes the other berth")
	w.creatures._caravan_at_stop(trader, "arriving")
	w.creatures._caravan_at_stop(other, "arriving")
	eq(String(trader.job.get("caravan_state", "")), "trading", "the first caravan can trade")
	eq(String(other.job.get("caravan_state", "")), "trading", "the second caravan can trade")
	check(trader.cell().distance_to(other.cell()) >= 12, "their carts and horses have separate space")


func test_a_caravan_stops_trades_rests_and_only_then_goes_on() -> void:
	var to := String(road["to"])
	var before := w.economy.have(to, "base:iron_sword")
	check(_run_until("arriving", 4000), "the road ends: the caravan gets in")
	check(String(trader.job.get("from", "")) != to, "no goods change hands before it has stopped")
	check(_run_until("trading", 400), "it reaches a place where the whole harness fits")
	eq(String(trader.job.get("from", "")), to, "it trades as a trader of this village")
	eq(int(trader.route["step"]), -1, "the road is turned round for the way back")
	check(trader.job.has("caravan_stop"), "the place it stands is saved")
	check(String(trader.job.get("caravan_stop_kind", "")) in ["square", "village", "roadside"],
		"the stop knows what kind of place it is")
	eq(int(trader.job.get("caravan_until", 0)), w.world_time + w.caravans.trade_ms(trader),
		"trading lasts a stretch of game time")
	eq(w.economy.have(to, "base:iron_sword"), before + 2, "the load is sold here")
	# It is here to talk to, and it does not slip away while trading.
	w.move_character(actor, trader.pos + Vector2i(128, 0))
	var talk := w._talk(actor, {"creature": trader.id}, "talk")
	check(talk.get("ok", false), "the trader answers during its stop")
	check(talk.get("trader", false), "as a trader, with its escort offer")
	var stop := trader.cell()
	_step(20)
	eq(_phase(), "trading", "still trading a moment later")
	eq(trader.cell(), stop, "and still at its place")
	# Trading ends, then the rest.
	w.world_time = int(trader.job["caravan_until"])
	check(_run_until("resting", 50), "trading gives way to a rest")
	eq(int(trader.job.get("caravan_until", 0)), w.world_time + w.caravans.rest_ms(trader),
		"the rest lasts its own stretch of game time")
	check(trader.cell().distance_to(stop) <= 2, "it rests where it stopped")
	w.world_time = int(trader.job["caravan_until"])
	check(_run_until("departing", 50), "the rest gives way to leaving")
	eq(int(trader.job.get("caravan_until", 0)), w.world_time + w.caravans.depart_ms(trader),
		"leaving takes a little while too")
	check(trader.cell().distance_to(stop) <= 2, "it is still there while saying goodbye")
	w.world_time = int(trader.job["caravan_until"])
	check(_run_until("travel", 50), "then it is under way again")
	eq(int(trader.route["step"]), -1, "back along the same road")
	check(_run_until_from(String(road["from"]), 4000), "it comes back to where it set out")
	eq(int(trader.route["step"]), 1, "and turns round there for the next journey")


func test_it_stops_in_the_village_it_came_to() -> void:
	var s := w.generator.settlements
	var home := s.home_plan()
	var district := s._district_of(0, home["centre"])
	var village_road := {}
	for r: Dictionary in s.roads_of(0, district.x, district.y):
		if String(r["to"]) != String(home["id"]) and String(r["from"]) != String(home["id"]):
			continue
		var cells: Array = r["path"]
		var end: Vector2i = cells[-1] if String(r["to"]) == String(home["id"]) else cells[0]
		if (home["bounds"] as Rect2i).grow(8).has_point(end):
			village_road = r
			break
	check(not village_road.is_empty(), "the home village has a road")
	if village_road.is_empty():
		return
	var path: Array = village_road["path"]
	var i := path.size() - 6 if String(village_road["to"]) == String(home["id"]) else 5
	var step := 1 if String(village_road["to"]) == String(home["id"]) else -1
	# What the server has in memory: the village and the road leading in.
	var area: Rect2i = (home["bounds"] as Rect2i).grow(24).merge(Rect2i(path[i] as Vector2i, Vector2i.ONE).grow(8))
	for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
		for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
			w.chunk("surface", cx, cy)
	trader = w.creatures._spawn("base:villager", "surface", path[i], {}, 12)
	trader.route = {"road": village_road["key"], "i": i, "step": step}
	trader.job = {"profession": "base:trader", "purse": 600, "name": "Гордей",
		"from": village_road["from"], "toward": village_road["to"]}
	w.creatures._make_caravan(trader, "cart")
	w.inventory("trade|" + trader.id).add("base:iron_sword", 1)
	w.move_character(actor, trader.pos + Vector2i(128, 0))
	check(_run_until("trading", 4000), "the caravan gets in and trades")
	check(String(trader.job.get("caravan_stop_kind", "")) in ["square", "village"],
		"it stops at the village, not out on the road: " + str(trader.job.get("caravan_stop_kind", "")))
	check(trader.cell().distance_to(home["fire"] as Vector2i) <= 20,
		"its place is by the village: %s, fire %s" % [trader.cell(), home["fire"]])


func test_a_restart_in_the_middle_of_a_stop_does_not_send_the_caravan_off() -> void:
	check(_run_until("trading", 5000), "the caravan is trading")
	var until := int(trader.job["caravan_until"])
	var stop := trader.cell()
	var data := trader.to_data()
	eq(String((data["job"] as Dictionary).get("caravan_state", "")), "trading", "the phase is saved")
	eq(int((data["job"] as Dictionary).get("caravan_until", 0)), until, "and so is the time it ends")
	# Come back as a saved world does: the same creature, read from its data.
	var loaded := Creature.from_data(trader.id, trader.location, data)
	w.creatures.creatures.erase(trader.id)
	w.creatures.add(loaded)
	trader = loaded
	_step(50)
	eq(_phase(), "trading", "a restart does not send it off at once")
	eq(trader.cell(), stop, "and it stays at its stop")
	w.world_time = until
	check(_run_until("resting", 50), "only the saved end of trading moves it on")
