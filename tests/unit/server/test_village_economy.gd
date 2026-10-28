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
