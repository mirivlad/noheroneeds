extends TestCase
## ADR-0066: a village's store makes and eats by its way of life; what is
## short is dear at its dwellers, what is plenty cheap; it fetches what it
## lacks from its cluster's villages, and a big delivery is written down.

var w: ServerWorld
var home: String
var _db := ""


func before_each() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, content, {"seed": 12345})
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


func test_a_trader_keeps_goods_a_village_cannot_afford() -> void:
	var e := w.economy
	var other: String = e.neighbours(home)[0]
	var trader := w.creatures._spawn("base:villager", "surface", Vector2i.ZERO, {}, 7)
	trader.job = {"profession": "base:trader", "purse": 0, "from": other, "toward": home}
	var stock := w.inventory("trade|" + trader.id)
	var item := "base:iron_sword"
	stock.add(item, 5)
	var before := e.have(home, item)
	var price := e.price(home, item)
	e.store(home)["coins"] = price * 2
	w.creatures._arrive(trader, home, other)
	eq(e.have(home, item), before + 2, "the village receives only the goods it can pay for")
	eq(stock.count(item), 3, "the unpaid goods stay on the cart")


func test_caravan_purchase_commits_stock_purse_and_village_together() -> void:
	var other: String = w.economy.neighbours(home)[0]
	var trader := w.creatures._spawn("base:villager", "surface", Vector2i.ZERO, {}, 7)
	trader.job = {"profession": "base:trader", "purse": 200, "from": home, "toward": other}
	w.creatures._make_caravan(trader, "cart")
	w.economy.earn(home, 0)
	check(w.sync(), "the starting state is on disk")
	var old_fact := w.store.read_meta("economy|" + home)
	w.creatures._load(trader, home, other)
	var stock := w.inventory("trade|" + trader.id)
	check(not stock.stacks.is_empty(), "the trader purchased a load")
	var expected_purse := int(trader.job["purse"])
	var expected_coins := w.economy.coins(home)
	check(not w.creatures.ready_to_unload(ServerWorld.chunk_key("surface", 0, 0)), "the trader's chunk waits for its pending operation")
	# The periodic state flush may run while operation writes are backpressured.
	# It must not publish the new purse or village fact without the cargo.
	w.flush_state()
	w.writer.wait_idle()
	var before_rows := w.store.entities_in_chunk("surface", 0, 0)
	var before: Dictionary = before_rows.filter(func(row: Dictionary) -> bool: return row["id"] == trader.id)[0]
	var old_trader: Dictionary = Cbor.decode(before["data"]).value
	eq(int(old_trader["job"]["purse"]), 200, "the independent flush did not write the new purse")
	eq(w.store.read_meta("economy|" + home), old_fact, "nor the new village balance")
	eq(w.store.get_inventory("trade|" + trader.id).size(), 0, "nor the cargo")
	w.commit_async(true)
	w.writer.wait_idle()
	w.poll()
	var after_rows := w.store.entities_in_chunk("surface", 0, 0)
	var after: Dictionary = after_rows.filter(func(row: Dictionary) -> bool: return row["id"] == trader.id)[0]
	var saved_trader: Dictionary = Cbor.decode(after["data"]).value
	var saved_stock := Inventory.from_data(Cbor.decode(w.store.get_inventory("trade|" + trader.id)).value)
	var saved_village: Dictionary = JSON.parse_string(w.store.read_meta("economy|" + home))
	eq(int(saved_trader["job"]["purse"]), expected_purse, "the transaction wrote the purse")
	eq(saved_stock.stacks, stock.stacks, "the same transaction wrote the cargo")
	eq(int(saved_village["coins"]), expected_coins, "and the village balance")


func test_existing_trader_gains_a_caravan_without_losing_its_cargo() -> void:
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var roads := s.roads_of(0, district.x, district.y)
	if not check(not roads.is_empty(), "a road exists"):
		return
	var road: Dictionary = roads[0]
	var path: Array = road["path"]
	var at: Vector2i = path[path.size() / 2]
	w.chunk("surface", at.x >> 5, at.y >> 5)
	var trader := w.creatures._spawn("base:villager", "surface", at, {}, 7)
	trader.route = {"road": road["key"], "i": path.size() / 2, "step": 1}
	trader.job = {"profession": "base:trader", "purse": 30, "from": road["from"], "toward": road["to"]}
	trader.changed()
	w.inventory("trade|" + trader.id).add("base:plank", 3)
	w.touch_inventory("trade|" + trader.id)
	var trader_id := trader.id
	check(w.sync(), "the old trader and its stock are saved")
	w.close()
	w = ServerWorld.open(_db, w.content)
	w.chunk("surface", at.x >> 5, at.y >> 5)
	trader = w.creatures.get_creature(trader_id)
	if not check(trader != null and not trader.job.has("horse"), "the old save has no caravan fields"):
		return
	w.world_time = 12 * Daylight.HOUR_MS
	w.creatures._traveller(trader, w.content.get_def(trader.kind))
	var horse_id := String(trader.job.get("horse", ""))
	var horse := w.creatures.get_creature(horse_id)
	if not check(horse != null, "the existing trader receives one horse"):
		return
	eq(w.inventory("trade|" + trader_id).count("base:plank"), 3, "the old cargo remains intact")
	var horse_cell := horse.cell()
	check(w.sync(), "the new relationship is saved")
	w.close()
	w = ServerWorld.open(_db, w.content)
	w.chunk("surface", at.x >> 5, at.y >> 5)
	w.chunk("surface", horse_cell.x >> 5, horse_cell.y >> 5)
	trader = w.creatures.get_creature(trader_id)
	eq(String(trader.job.get("horse", "")), horse_id, "reloading keeps the original horse id")
	check(w.creatures.get_creature(horse_id) != null, "the same horse is restored")
	eq(w.inventory("trade|" + trader_id).count("base:plank"), 3, "and the cargo is not duplicated")


func test_caravan_delivers_when_it_reaches_the_end_of_the_road() -> void:
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var roads := s.roads_of(0, district.x, district.y)
	if not check(not roads.is_empty(), "a road exists"):
		return
	var road: Dictionary = roads[0]
	var path: Array = road["path"]
	if not check(path.size() > 8, "the road has enough cells"):
		return
	var start: Vector2i = path[-4]
	var finish: Vector2i = path[-1]
	for p: Vector2i in path.slice(path.size() - 8):
		w.chunk("surface", p.x >> 5, p.y >> 5)
	var trader := w.creatures._spawn("base:villager", "surface", start, {}, 7)
	trader.route = {"road": road["key"], "i": path.size() - 4, "step": 1}
	trader.job = {"profession": "base:trader", "name": "Савва", "purse": 0,
		"from": String(road["from"]), "toward": String(road["to"])}
	w.creatures._make_caravan(trader, "cart")
	var stock := w.inventory("trade|" + trader.id)
	stock.add("base:iron_sword", 2)
	var before := w.economy.have(String(road["to"]), "base:iron_sword")
	w.world_time = 12 * Daylight.HOUR_MS
	w.creatures._traveller(trader, w.content.get_def(trader.kind))
	eq(w.economy.have(String(road["to"]), "base:iron_sword"), before, "no sale before arrival")
	eq(int(trader.route["step"]), 1, "still heading to the destination")
	for i in 200:
		w.creatures._move(trader)
		if trader.target == Creature.NO_TARGET:
			break
	eq(trader.cell(), finish, "the wagon reaches the road's end")
	w.creatures._traveller(trader, w.content.get_def(trader.kind))
	eq(w.economy.have(String(road["to"]), "base:iron_sword"), before + 2, "the cargo arrives in the village store")
	eq(int(trader.route["step"]), -1, "then the caravan turns back")


func test_caravan_chooses_a_pack_horse_when_the_nearby_road_is_too_narrow() -> void:
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var roads := s.roads_of(0, district.x, district.y)
	if not check(not roads.is_empty(), "a road exists"):
		return
	var road: Dictionary = roads[0]
	var path: Array = road["path"]
	if not check(path.size() > 15, "the road has enough cells"):
		return
	for p: Vector2i in path.slice(0, 15):
		for dy in range(-5, 6):
			for dx in range(-5, 6):
				var at := p + Vector2i(dx, dy)
				var chunk := w.chunk("surface", at.x >> 5, at.y >> 5)
				chunk.set_cell("ground", at.x & 31, at.y & 31, "base:grass")
				chunk.set_cell("cover", at.x & 31, at.y & 31, "")
				chunk.set_cell("structure", at.x & 31, at.y & 31, "")
	var open := w.creatures._spawn("base:villager", "surface", path[0], {}, 7)
	while open.rand(914) < .3:
		open.seed += 1  # this trader would normally choose a cart
	open.route = {"road": road["key"], "i": 0, "step": 1}
	open.job = {"profession": "base:trader"}
	w.creatures._make_caravan(open)
	eq(open.job.get("caravan_type"), "cart", "a clear road permits the cart")
	var blocked: Vector2i = path[4]
	w.chunk("surface", blocked.x >> 5, blocked.y >> 5).set_cell("cover", blocked.x & 31, blocked.y & 31, "base:oak")
	var narrow := w.creatures._spawn("base:villager", "surface", path[0], {}, open.seed)
	narrow.route = {"road": road["key"], "i": 0, "step": 1}
	narrow.job = {"profession": "base:trader"}
	w.creatures._make_caravan(narrow)
	eq(narrow.job.get("caravan_type"), "pack", "the same trader uses a pack horse when a tree blocks the cart")


func test_caravan_travels_the_road_between_villages() -> void:
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var roads := s.roads_of(0, district.x, district.y)
	if not check(not roads.is_empty(), "a road exists"):
		return
	var road: Dictionary = roads[0]
	var path: Array = road["path"]
	if not check(path.size() > 8, "the road has enough cells"):
		return
	var chunks := {}
	for p: Vector2i in path:
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var key := Vector2i((p.x >> 5) + dx, (p.y >> 5) + dy)
				if not chunks.has(key):
					w.chunk("surface", key.x, key.y)
					chunks[key] = true
	# A tree has fallen across the road after it was generated. The caravan
	# must get around it without driving the horse through the blocked cell.
	var obstruction: Vector2i = path[path.size() / 2]
	w.chunk("surface", obstruction.x >> 5, obstruction.y >> 5).set_cell("cover", obstruction.x & 31, obstruction.y & 31, "base:oak")
	for variant: String in ["cart", "pack"]:
		_check_caravan_route(road, path, obstruction, variant)


func _check_caravan_route(road: Dictionary, path: Array, obstruction: Vector2i, variant: String) -> void:
	var trader := w.creatures._spawn("base:villager", "surface", path[0], {}, 7)
	trader.route = {"road": road["key"], "i": 0, "step": 1}
	trader.job = {"profession": "base:trader", "name": "Савва", "purse": 0,
		"from": String(road["from"]), "toward": String(road["to"])}
	w.creatures._make_caravan(trader, variant)
	w.inventory("trade|" + trader.id).add("base:iron_sword", 2)
	var destination := String(road["to"])
	var before := w.economy.have(destination, "base:iron_sword")
	w.world_time = 12 * Daylight.HOUR_MS
	var pc := PortableCharacter.create("Охранник", "base:human_ro_m")
	w.enter("escort-" + variant, pc)
	w.move_character(pc.character_id, trader.pos)
	check(w.caravans.hire_player(pc.character_id, trader).get("ok", false) == false, "a penniless employer cannot hire")
	trader.job["purse"] = 100
	check(w.caravans.hire_player(pc.character_id, trader).get("ok", false), "a real inter-village journey hires an escort")
	var steps := 0
	var crossed_tree := false
	var horse := w.creatures.get_creature(String(trader.job["horse"]))
	while int(trader.route["step"]) == 1 and steps < path.size() * 90:
		if trader.target == Creature.NO_TARGET:
			w.creatures._traveller(trader, w.content.get_def(trader.kind))
		w.creatures._move(trader)
		w.move_character(pc.character_id, trader.pos)
		if obstruction in BodySize.cells(horse.pos, BodySize.of(w.content.get_def(horse.kind))["half"]):
			crossed_tree = true
		steps += 1
	if int(trader.route["step"]) != -1:
		print("CARAVAN_STUCK cell=", trader.cell(), " target=", trader.target, " state=", trader.state, " path=", trader.path,
			" horse=", horse.cell(), " heading=", trader.job.get("caravan_heading"), " route_i=", trader.route.get("i"),
			" road=", path.slice(maxi(0, int(trader.route.get("i", 0)) - 8), mini(path.size(), int(trader.route.get("i", 0)) + 8)))
	check(int(trader.route["step"]) == -1, "%s went around the obstruction and travelled the whole road (%d cells, %d ticks, at %s, tree %s)" % [variant, path.size(), steps, trader.cell(), obstruction])
	check(not crossed_tree, "the horse never entered the tree's cell")
	eq(w.economy.have(destination, "base:iron_sword"), before + 2, "%s: the destination receives the cargo" % variant)
	eq(w.caravans.contract(pc.character_id).get("state"), "arrived", "arrival automatically settles the escort contract")
	if int(trader.route["step"]) != -1:
		return
	steps = 0
	while int(trader.route["step"]) == -1 and steps < path.size() * 90:
		if trader.target == Creature.NO_TARGET:
			w.creatures._traveller(trader, w.content.get_def(trader.kind))
		w.creatures._move(trader)
		if obstruction in BodySize.cells(horse.pos, BodySize.of(w.content.get_def(horse.kind))["half"]):
			crossed_tree = true
		steps += 1
	check(int(trader.route["step"]) == 1, "%s returns to its starting village (%d ticks, at %s)" % [variant, steps, trader.cell()])
	check(not crossed_tree, "%s avoids the tree on the return too" % variant)
	eq(String(trader.job.get("from", "")), String(road["from"]), "the return delivery is processed at the starting village")


## ADR-0066: the land round a village adds to what it makes and needs — a
## forest's village has wood to make, a steppe's lacks it.
func test_the_land_round_a_village_counts() -> void:
	var e := w.economy
	var s := w.generator.settlements
	var forest := ""
	var bare := ""
	for p: Dictionary in s.plans_near(s.home_plan()["centre"], 3000):
		var g := e._goods(String(p["id"]))
		if forest == "" and int(g["makes"].get("base:log", 0)) > 0:
			forest = String(p["id"])
		if bare == "" and int(g["needs"].get("base:log", 0)) > 0:
			bare = String(p["id"])
	check(forest != "" or bare != "", "the land counts somewhere near")
	if forest != "":
		check(e.want(forest, "base:log") > 0, "a forest village makes wood: %s" % str(e._goods(forest)["makes"]))
	if bare != "":
		check(e.short(bare).has("base:log") or e.have(bare, "base:log") > 0, "a bare one needs it: %s" % str(e._goods(bare)["needs"]))
