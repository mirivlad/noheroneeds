extends TestCase
## ADR-0039: a village's dwellers live by their trade's day — to work, to
## the fire in the evening, to bed at night — walking by found ways through
## the doors they open; they speak to one who comes near.

var w: ServerWorld
var _content: ContentRegistry
var plan: Dictionary


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 12345})
	plan = w.generator.settlements.home_plan()
	_load_round()


func after_each() -> void:
	w.close()


func _load_round() -> void:
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
		for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
			w.chunk("surface", cx, cy)


func _dwellers() -> Array:
	return w.creatures.creatures.values().filter(func(c: Creature) -> bool: return not c.job.is_empty())


## Lives on for `ticks` from the hour `hour` of day 2 (a jump: they catch
## up), or from now with `hour` < 0, the clock going on, near the village.
func _live(hour: float, ticks: int) -> void:
	if hour >= 0.0:
		w.world_time = Daylight.DAY_MS + int(hour * Daylight.HOUR_MS)
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	for i in ticks:
		w.tick += 1
		if hour < 0.0:
			w.advance_time()
		for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
			for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
		w.combat.step(w.tick)


func test_a_dweller_a_home_each_with_its_trade_and_the_pen_stocked() -> void:
	var ds := _dwellers()
	eq(ds.size(), (plan["homes"] as Array).size(), "a dweller a home")
	for c: Creature in ds:
		var home: Dictionary = plan["homes"][int(c.job["home"])]
		eq(String(c.job["profession"]), String(home["dweller"]), "its home's trade")
		eq(c.cell(), home["bed"] as Vector2i, "come into the world in its bed")
	var stock := w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.owner == String(plan["id"]))
	check(stock.size() >= 4, "the pen's animals, the village's: %d" % stock.size())
	for a: Creature in stock:
		check((plan["pen"]["rect"] as Rect2i).has_point(a.cell()), "in the pen")


func test_a_day_at_work_an_evening_by_the_fire_a_night_in_bed() -> void:
	_live(10.0, 1600)
	var at_work := 0
	for c: Creature in _dwellers():
		var spot := w.creatures._dweller_spot(c, "work")
		if Vector2(c.cell()).distance_to(Vector2(spot)) <= 1.0:
			at_work += 1
			check(c.held == String(_content.get_def(String(c.job["profession"])).get("holds", "")), "its tool in its hands")
	check(at_work >= _dwellers().size() - 1, "at work by mid-morning: %d of %d" % [at_work, _dwellers().size()])
	_live(19.5, 1600)
	var by_fire := 0
	for c: Creature in _dwellers():
		if Vector2(c.cell()).distance_to(Vector2(plan["fire"])) <= 4.0:
			by_fire += 1
			eq(c.held, "", "nothing in the hands of an evening")
	check(by_fire >= _dwellers().size() - 1, "by the fire in the evening: %d" % by_fire)
	_live(23.0, 1600)
	for c: Creature in _dwellers():
		var bed: Vector2i = plan["homes"][int(c.job["home"])]["bed"]
		check(c.cell() == bed and c.asleep, "asleep in its bed at night: %s at %s" % [c.job["profession"], c.cell()])
	# Morning comes while they sleep: they get up and walk out, opening doors.
	_live(4.5, 10)
	_live(-1.0, int(3.2 * Daylight.HOUR_MS / w.time_rate))
	var doors_open := 0
	for h: Dictionary in plan["homes"]:
		var door: Vector2i = h["door"]
		if w.chunk("surface", floori(door.x / 32.0), floori(door.y / 32.0)).get_props(posmod(door.x, 32), posmod(door.y, 32)).get("open", false):
			doors_open += 1
	check(doors_open >= _dwellers().size() - 1, "out through the doors they opened: %d" % doors_open)
	var walked := 0
	for c: Creature in _dwellers():
		if c.cell() != plan["homes"][int(c.job["home"])]["bed"]:
			walked += 1
	check(walked >= _dwellers().size() - 1, "out of bed by 7.7: %d" % walked)


func test_one_near_is_spoken_to_by_trade() -> void:
	_live(10.0, 1600)
	var c: Creature = _dwellers().filter(func(d: Creature) -> bool: return d.job["village"] == plan["id"])[0]
	var pc := PortableCharacter.create("Аня", "base:human_m")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + pc.character_id, pc)
	w.move_character(pc.character_id, c.pos + Vector2i(Movement.UNIT, 0))
	_live(10.2, 200)
	check(c.said > 0 and c.say != "", "it says something: %s" % c.say)
	var lines: Dictionary = _content.get_def(String(c.job["profession"]))["lines"]
	var all := []
	for k: String in lines:
		all.append_array(lines[k])
	all.append_array(w.chronicles._names.get("asks", []))  # or of what it asks (ADR-0042)
	var news: bool = (w.chronicles._names.get("news", []) as Array).any(func(f: String) -> bool:
		return c.say.begins_with(f.get_slice("{news}", 0)))
	check(all.has(c.say) or news, "a line of its trade (or the village's news): " + c.say)


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func test_trade_with_a_dweller_coins_stock_purse_and_the_morning() -> void:
	_live(10.0, 1600)
	var farmer: Creature = _dwellers().filter(func(c: Creature) -> bool: return c.job["profession"] == "base:farmer")[0]
	var pc := PortableCharacter.create("Аня", "base:human_m")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + pc.character_id, pc)
	var a := pc.character_id
	w.move_character(a, farmer.pos + Vector2i(Movement.UNIT * 8, 0))
	eq(_req(a, {"type": "trade_look", "creature": farmer.id}).get("reason"), "too_far")
	w.move_character(a, farmer.pos + Vector2i(Movement.UNIT, 0))
	var g := _req(a, {"type": "trade_look", "creature": farmer.id})
	check(g.get("ok", false), str(g))
	eq(g["sells"]["base:bread"], [4, 6], "four loaves at six")
	eq(g["purse"], 60)
	var buy := {"type": "trade", "creature": farmer.id, "item": "base:bread", "count": 1, "buy": true}
	eq(_req(a, buy.duplicate()).get("reason"), "no_money", "no coins yet")
	w.grant(a, "base:coin", 20)
	g = _req(a, buy.merged({"count": 2}, true))
	check(g.get("ok", false), str(g))
	eq(w.inventory(a).count("base:bread"), 2)
	eq(w.inventory(a).count("base:coin"), 8, "twelve paid")
	eq(g["sells"]["base:bread"][0], 2, "two left")
	eq(g["purse"], 72, "into its purse")
	eq(_req(a, buy.merged({"count": 3}, true)).get("reason"), "sold_out")
	w.grant(a, "base:raw_meat", 30)
	g = _req(a, {"type": "trade", "creature": farmer.id, "item": "base:raw_meat", "count": 10, "buy": false})
	eq(w.inventory(a).count("base:coin"), 38, "ten pieces of meat at three")
	eq(g["purse"], 42)
	eq(_req(a, {"type": "trade", "creature": farmer.id, "item": "base:raw_meat", "count": 20, "buy": false}).get("reason"),
		"no_money_there", "its purse is not bottomless")
	eq(_req(a, {"type": "trade", "creature": farmer.id, "item": "base:stone", "count": 1, "buy": false}).get("reason"), "not_bought")
	# The next morning: stock and purse as the trade says again.
	_live(-1.0, 0)
	w.world_time += Daylight.DAY_MS
	g = _req(a, {"type": "trade_look", "creature": farmer.id})
	eq(g["sells"]["base:bread"][0], 4, "restocked")
	eq(g["purse"], 60)
	farmer.asleep = true
	eq(_req(a, {"type": "trade_look", "creature": farmer.id}).get("reason"), "not_now", "not in its sleep")
