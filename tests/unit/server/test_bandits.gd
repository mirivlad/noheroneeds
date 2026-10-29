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
