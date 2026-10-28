extends TestCase
## ADR-0066: a village's store makes and eats by its way of life; what is
## short is dear at its dwellers, what is plenty cheap; it fetches what it
## lacks from its cluster's villages, and a big delivery is written down.

var w: ServerWorld
var home: String


func before_each() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), content, {"seed": 12345})
	home = String(w.generator.settlements.home_plan()["id"])


func after_each() -> void:
	w.close()


func test_a_day_makes_and_eats() -> void:
	var e := w.economy
	var makes := e.makes(home)
	var needs := e.needs(home)
	check(not makes.is_empty() and not needs.is_empty(), "the home village lives by a way: %s" % e.way_of(home).get("id"))
	var item: String = makes.keys()[0]
	var eaten: String = needs.keys()[0]
	var made_before := e.have(home, item)
	var eaten_before := e.have(home, eaten)
	eq(made_before, int(makes[item]) * VillageEconomy.START_DAYS + int(needs.get(item, 0)) * VillageEconomy.START_DAYS, "three days to start with")
	w.world_time += Daylight.DAY_MS
	eq(e.have(home, item), made_before + int(makes[item]) - int(needs.get(item, 0)), "a day's making")
	check(e.have(home, eaten) <= eaten_before, "a day's need eaten (or fetched back)")


func test_short_is_dear_and_plenty_cheap() -> void:
	var e := w.economy
	var need: String = e.needs(home).keys()[0]
	var made: String = e.makes(home).keys()[0]
	e.store(home)["stock"][need] = 0
	eq(e.factor(home, need), VillageEconomy.DEAREST, "none of what it needs: the dearest")
	check(e.short(home).has(need), "and it says so")
	e.store(home)["stock"][made] = e.want(home, made) * 10
	check(e.factor(home, made) < 0.6, "plenty: cheap (%.2f)" % e.factor(home, made))
	eq(e.factor(home, "base:pike"), 1.0, "what is not of its way: the trade's price")


func test_a_short_village_fetches_from_its_neighbours() -> void:
	var e := w.economy
	var others := e.neighbours(home)
	check(not others.is_empty(), "the home village has neighbours in its cluster")
	# A thing the home village needs, made plenty of at a neighbour.
	var need: String = e.needs(home).keys()[0]
	var other: String = others[0]
	e.store(home)["stock"][need] = 0
	e.store_quiet(other)["stock"][need] = e.want(other, need) + 100
	w.world_time += Daylight.DAY_MS
	var got := e.have(home, need)
	check(got >= int(e.needs(home)[need]) * VillageEconomy.SHORT_DAYS, "fetched what it lacked: %d" % got)
	check(e.have(other, need) < e.want(other, need) + 100, "out of the neighbour's spare")
	var told: Array = (w.chronicles.of(home)["entries"] as Array).filter(func(x: Dictionary) -> bool:
		return String(x["text"]).begins_with("Из деревни"))
	check(not told.is_empty(), "the delivery is in the chronicle")


func test_a_dwellers_prices_follow_its_village() -> void:
	var e := w.economy
	var trade := {"buys": {"base:raw_fish": 4}, "sells": {}}
	var need := "base:raw_fish"
	if not e.needs(home).has(need):
		need = e.needs(home).keys()[0]
		trade["buys"] = {need: 4}
	e.store(home)["stock"][need] = e.want(home, need)
	var plenty := w._buy_price(trade, need, home)
	e.store(home)["stock"][need] = 0
	check(w._buy_price(trade, need, home) > plenty, "short: it pays more (%d > %d)" % [w._buy_price(trade, need, home), plenty])


func _player() -> String:
	var c := PortableCharacter.create("Ваня", "base:human_m")
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


## ADR-0067: what a village fetches from a neighbour it pays for.
func test_deliveries_are_paid_for() -> void:
	var e := w.economy
	var other: String = e.neighbours(home)[0]
	var need: String = e.needs(home).keys()[0]
	e.store(home)["stock"][need] = 0
	e.store_quiet(other)["stock"][need] = e.want(other, need) + 100
	var mine := e.coins(home)
	var theirs := e.coins(other)
	w.world_time += Daylight.DAY_MS
	var got := e.have(home, need)
	check(got > 0, "fetched")
	check(e.coins(home) < mine and e.coins(other) > theirs, "paid for: %d -> %d, %d -> %d" % [mine, e.coins(home), theirs, e.coins(other)])


## ADR-0067: a trader on a road takes a load where it sets out, sells it to a
## player on the way, and at the road's end the village takes what is left.
func test_a_trader_carries_goods_between_villages() -> void:
	var e := w.economy
	var s := w.generator.settlements
	var road := {}
	var dist := s._district_of(0, s.home_plan()["centre"])
	for rd: Dictionary in s.roads_of(0, dist.x, dist.y):
		if String(rd["from"]) == home or String(rd["to"]) == home:
			road = rd
			break
	check(not road.is_empty(), "a road from the home village")
	var from := String(road["from"])
	var to := String(road["to"])
	var path: Array = road["path"]
	var c := w.creatures._spawn("base:villager", "surface", path[2], {}, 7)
	c.route = {"road": road["key"], "i": 2, "step": 1}
	c.job = {"profession": "base:trader", "name": "Савва", "purse": 200, "from": from, "toward": to}
	var coins_from := e.coins(from)
	w.creatures._load(c, from, to)
	var stock := w.inventory("trade|" + c.id)
	check(not stock.stacks.is_empty(), "a load taken: %s" % str(stock.stacks))
	check(e.coins(from) > coins_from, "bought of the village it left")
	# A player meets it on the road and buys a thing.
	var a := _player()
	w.move_character(a, c.pos)
	var item: String = stock.stacks.keys()[0]
	w.grant(a, "base:coin", 500)
	var look := _req(a, {"type": "trade_look", "creature": c.id})
	check(look.get("ok", false) and (look["sells"] as Dictionary).has(item), "it sells its load: %s" % str(look))
	var n := int(stock.stacks[item])
	check(_req(a, {"type": "trade", "creature": c.id, "item": item, "count": 1, "buy": true}).get("ok", false), "bought one of it")
	eq(int(stock.stacks.get(item, 0)), n - 1, "one less carried")
	var talk := _req(a, {"type": "talk", "creature": c.id})
	check(String(talk.get("says", "")).contains("Иду"), "it says where it goes: " + String(talk.get("says", "")))
	# At the road's end.
	var before := e.have(to, item)
	w.creatures._arrive(c, to, from)
	var back := int(stock.stacks.get(item, 0))  # (it may take some of it back for the other village)
	eq(e.have(to, item) + back, before + n - 1, "the rest of its load in the village's store")
	eq(String(c.job["toward"]), from, "and back the other way")
