extends TestCase

var w: ServerWorld
var db: String
var plan: Dictionary


func before_each() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, content, {"seed": 12345})
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	plan = w.generator.settlements.camps._layout("bandits@0,0,0", Vector2i(180, 180), [0, 0, 0, 0],
		Vector2i(130, 180), Settlements.NONE, rng)
	w.generator.settlements.camps._plans["0,0,0"] = plan
	for cy in range(5, 7):
		for cx in range(5, 7):
			w.chunk("surface", cx, cy)


func after_each() -> void:
	w.close()


func _members() -> Array:
	return w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.job.get("camp", "") == plan["id"])


func test_residents_all_armed_red_and_created_only_once() -> void:
	var members := _members()
	eq(members.size(), int(plan["population"]))
	for c: Creature in members:
		eq(c.looks["colors"]["shirt"], Bandits.SHIRT)
		check(Bandits.WEAPONS.has(c.job["weapon"]), "everyone carries a weapon, including fishers")
		check(c.job["duty"] in ["hunt", "fish"], "every resident has a peaceful occupation too")
	w.bandits.populate(plan["id"])
	eq(_members().size(), members.size(), "a second chunk notification does not add people")


func test_huts_have_solid_sides_and_back_and_a_passable_front_aisle() -> void:
	for shelter: Vector2i in plan["shelters"]:
		for y in range(-2, 3):
			check(w.is_solid("surface", shelter.x - 1, shelter.y + y), "left side stops people")
			check(w.is_solid("surface", shelter.x + 1, shelter.y + y), "right side stops people")
		check(w.is_solid("surface", shelter.x, shelter.y - 2), "back wall stops people")
		for y in range(-1, 4):
			check(not w.is_solid("surface", shelter.x, shelter.y + y), "centre aisle and south entrance stay open")
	for c: Creature in _members():
		check(not w.is_solid(c.location, c.cell().x, c.cell().y), "residents start outside, on walkable ground")
		var path := w.creatures._route(c, c.home)
		check(not path.is_empty(), "the sleeping place can be reached through the entrance")
	var c: Creature = _members()[0]
	var hut: Vector2i = plan["shelters"][0]
	c.pos = (hut + Vector2i(-3, 0)) * 256 + Vector2i(128, 128)
	w.creatures._go(c, "walk", hut, false)
	for i in 100:
		w.creatures._move(c)
	check(c.cell().x < hut.x - 1, "actual movement cannot cut across the side of the roof")


func test_death_is_permanent_and_unloaded_members_still_count_as_alive() -> void:
	var members := _members()
	var away: Creature = members.pop_back()
	# It is outside the loaded camp; absence is not evidence of death.
	w.creatures.creatures.erase(away.id)
	for c: Creature in members:
		w.combat.hurt(c.id, 1000, "")
	check(not w.bandits.state(plan["id"])["abandoned"], "the member away is still alive")
	w.creatures.creatures[away.id] = away
	w.combat.hurt(away.id, 1000, "")
	check(w.bandits.state(plan["id"])["abandoned"], "only every actual death abandons the camp")
	w.bandits.populate(plan["id"])
	eq(_members().size(), 0, "a destroyed camp does not respawn")


func test_camp_members_and_deaths_survive_restart() -> void:
	var first: Creature = _members()[0]
	var dead_id := first.id
	w.combat.hurt(dead_id, 1000, "")
	var count := _members().size()
	w.sync()
	w.close()
	w = ServerWorld.open(db, w.content, {"seed": 12345})
	w.chunk("surface", 5, 5)
	w.chunk("surface", 5, 6)
	w.chunk("surface", 6, 5)
	w.chunk("surface", 6, 6)
	eq(_members().size(), count, "saved survivors, no new population")
	check((w.bandits.state(plan["id"])["dead"] as Array).has(dead_id), "death retained")


func test_random_raids_use_hunters_and_fishers_and_continue_after_losses() -> void:
	var seen := {}
	var fishers := false
	var hunters := false
	for n in 16:
		w.world_time += Daylight.DAY_MS
		var selected := w.bandits.start_raid(plan["id"])
		check(not selected.is_empty(), "a finite random raid party")
		for id: String in selected:
			seen[id] = true
			var c := w.creatures.get_creature(id)
			fishers = fishers or c.job["duty"] == "fish"
			hunters = hunters or c.job["duty"] == "hunt"
			c.job["raid"] = false
		w.bandits.state(plan["id"])["raid"] = []
	check(seen.size() > 4 and fishers and hunters, "different residents of both occupations participate")
	var killed := w.bandits.start_raid(plan["id"])
	for id: String in killed:
		w.combat.hurt(id, 1000, "")
	check(not w.bandits.start_raid(plan["id"]).is_empty(), "survivors can raid after an entire party was killed")


func test_camp_cooks_and_consumes_actual_food_and_handles_empty_stocks() -> void:
	var stock := w.inventory("store|camp|" + String(plan["id"]))
	var before := stock.count("base:raw_meat")
	w.world_time += Daylight.HOUR_MS * 6
	w.bandits._meals(plan["id"])
	check(stock.count("base:raw_meat") + stock.count("base:cooked_meat") < before, "residents eat from their real store")
	for item: String in stock.stacks.keys():
		stock.remove(item, stock.count(item))
	w.world_time += Daylight.HOUR_MS * 6
	w.bandits._meals(plan["id"])
	check(stock.stacks.is_empty(), "an empty store cannot cook or feed anyone")


func test_real_loot_returns_to_the_visible_chest_without_copying() -> void:
	var c: Creature = _members()[0]
	c.pos = (plan["centre"] as Vector2i) * Movement.UNIT + Vector2i(128, 128)
	w.inventory("haul|" + c.id).add("base:coin", 17)
	w.inventory("haul|" + c.id).add("base:iron_sword", 1, [{"wear": 13}])
	w.bandits.return_home(c, plan)
	eq(w.inventory("haul|" + c.id).count("base:coin"), 0)
	var stock := w.inventory("store|camp|" + String(plan["id"]))
	eq(stock.count("base:coin"), 17)
	eq(stock.states["base:iron_sword"][0]["wear"], 13)
	w.bandits.return_home(c, plan)
	eq(stock.count("base:coin"), 17, "returning twice cannot duplicate cargo")


func test_raid_walks_to_the_road_kills_trader_and_brings_back_real_goods() -> void:
	# Controlled terrain, real movement/perception/weapons/items, no scripted
	# delivery or automatic victory calculation.
	for y in range(166, 194):
		for x in range(120, 194):
			var chunk := w.chunk("surface", x >> 5, y >> 5)
			chunk.set_cell("ground", x & 31, y & 31, "base:grass")
			chunk.set_cell("cover", x & 31, y & 31, "")
			if Vector2i(x, y) != plan["chest"]:
				chunk.set_cell("structure", x & 31, y & 31, "")
	var trader := w.creatures._spawn("base:villager", "surface", plan["raid_at"], {}, 7)
	trader.job = {"profession": "base:trader", "purse": 7}
	w.inventory("trade|" + trader.id).add("base:plank", 3)
	w.world_time = Daylight.DAY_MS + 8 * Daylight.HOUR_MS
	var party := w.bandits.start_raid(plan["id"])
	for id: String in party:
		var c := w.creatures.get_creature(id)
		c.job["weapon"] = "base:spear"
		c.held = "base:spear"
	var start_coins := w.inventory("store|camp|" + String(plan["id"])).count("base:coin")
	for tick in 2600:
		w.tick += 1
		w.advance_time()
		for id: String in party:
			var c := w.creatures.get_creature(id)
			if c == null:
				continue
			if tick % 12 == 0:
				w.creatures._perceive(c, w.content.get_def(c.kind))
				w.bandits.think(c)
			if c.target != Creature.NO_TARGET:
				w.creatures._move(c)
		w.combat.step(w.tick)
		if not w.creatures.has(trader.id) and (w.bandits.state(plan["id"])["raid"] as Array).is_empty():
			break
	check(not w.creatures.has(trader.id), "the raid reached and fought the trader")
	var stock := w.inventory("store|camp|" + String(plan["id"]))
	check(stock.count("base:plank") > 0 or stock.count("base:coin") > start_coins, "actual dropped goods reached the camp")
	check((w.bandits.state(plan["id"])["raid"] as Array).is_empty(), "the surviving raiders returned")
