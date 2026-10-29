extends TestCase

var w: ServerWorld


func before_each() -> void:
	w = ServerWorld.open(tmp_dir().path_join("world.db"), ContentRegistry.load_packs(["res://content/base"]), {"seed": 11})
	for cy in [4, 5, 6]:
		for cx in [4, 5, 6]:
			var chunk := w.chunk("surface", cx, cy)
			for id: String in w.creatures.in_chunk("surface", cx, cy):
				w.creatures.remove(id)
			for y in 32:
				for x in 32:
					for layer: String in ["cover", "structure", "roof"]:
						chunk.set_cell(layer, x, y, "")
					chunk.set_cell("ground", x, y, "base:grass")


func after_each() -> void:
	w.close()


func _npc(at: Vector2i, weapon: String, helmet := false) -> Creature:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var c := w.creatures._spawn("base:caravan_guard", "surface", at, CreatureSim.villager_looks(rng), 7)
	w.combat.equip_creature(c, weapon, helmet)
	return c


func test_npc_spear_uses_its_reach_damage_and_condition() -> void:
	var c := _npc(Vector2i(170, 170), "base:spear")
	var target := w.creatures._spawn("base:deer", "surface", Vector2i(172, 170), {}, 1)
	check(w.combat.creature_attack(c, target.id), "the spear reaches beyond the old NPC's natural attack")
	eq(target.health, 5, "actual spear damage")
	eq(int(c.job["weapon_state"]["wear"]), 1, "the real copy was used")
	c.job["weapon_state"] = {"wear": 300}
	w.combat.step(100)
	check(not w.combat.creature_attack(c, target.id), "a broken spear cannot strike")


func test_npc_bow_spends_arrows_and_hits_with_real_projectiles() -> void:
	var c := _npc(Vector2i(170, 170), "base:bow")
	var target := w.creatures._spawn("base:deer", "surface", Vector2i(177, 170), {}, 1)
	check(w.combat.creature_attack(c, target.id), "an archer shoots at range")
	eq(w.inventory("gear|" + c.id).count("base:arrow"), 19)
	eq(target.health, 10, "shooting does not apply instant remote damage")
	for tick in range(1, 30):
		w.combat.step(tick)
	eq(target.health, 5, "the travelling arrow hit")
	w.inventory("gear|" + c.id).remove("base:arrow", 19)
	check(not w.combat.creature_attack(c, target.id), "no unlimited ammunition")


func test_helmet_protects_wears_and_drops_with_its_state() -> void:
	var c := _npc(Vector2i(170, 170), "base:spear", true)
	eq(w.combat.armor_of(c.id), 1)
	w.combat.hurt(c.id, w.combat.through_armor(c.id, 5), "")
	eq(c.health, 16)
	eq(c.job["armor_states"]["headwear"]["wear"], 1)
	w.combat.hurt(c.id, 1000, "")
	var helmets: Array = w.items.values().filter(func(it: Dictionary) -> bool: return it["item"] == "base:iron_helmet")
	eq(helmets.size(), 1, "one physical helmet")
	eq(helmets[0]["states"][0]["wear"], 2, "its condition survives the drop")


func test_archer_does_not_shoot_through_his_own_escort() -> void:
	var c := _npc(Vector2i(170, 170), "base:bow")
	var ally := _npc(Vector2i(173, 170), "base:spear")
	c.job["guard_driver"] = "same trader"
	ally.job["guard_driver"] = "same trader"
	var target := w.creatures._spawn("base:deer", "surface", Vector2i(177, 170), {}, 1)
	check(not w.combat.creature_attack(c, target.id), "a friendly body blocks the shot")
	eq(w.inventory("gear|" + c.id).count("base:arrow"), 20)


func test_rich_trader_and_valuable_cargo_hire_more_real_guards() -> void:
	var poor := w.creatures._spawn("base:villager", "surface", Vector2i(165, 170), {}, 2)
	poor.job = {"profession": "base:trader", "purse": 80, "from": ""}
	var rich := w.creatures._spawn("base:villager", "surface", Vector2i(185, 170), {}, 3)
	rich.job = {"profession": "base:trader", "purse": 800, "from": ""}
	var poor_wanted := w.caravans.desired(poor)
	check(w.caravans.desired(rich) > poor_wanted, "personal wealth matters")
	w.inventory("trade|" + poor.id).add("base:iron_sword", 20)
	check(w.caravans.desired(poor) > poor_wanted, "valuable cargo matters too")
	w.caravans.hire(rich, 60)
	var roster := w.caravans.guards(rich)
	eq(roster.size(), 6)
	eq(int(rich.job["purse"]), 740, "hiring transfers actual money")
	var weapons := []
	for id: String in roster:
		var guard := w.creatures.get_creature(id)
		eq(guard.looks["worn"]["headwear"], "base:iron_helmet")
		eq(int(guard.job["purse"]), 10)
		weapons.append(guard.job["weapon"])
	for weapon: String in Caravans.WEAPONS:
		check(weapons.has(weapon), "mixed escort weapon: " + weapon)
	w.caravans.attacked(w.creatures.get_creature(roster[0]), "enemy", rich.pos)
	for id: String in roster:
		check(w.creatures.get_creature(id).memory.has("enemy"), "all nearby guards respond")


func test_multiple_guards_follow_a_moving_trader_around_trees() -> void:
	var trader := w.creatures._spawn("base:villager", "surface", Vector2i(166, 170), {}, 3)
	trader.job = {"profession": "base:trader", "purse": 800, "from": ""}
	w.caravans.hire(trader, 60)
	var roster := w.caravans.guards(trader).duplicate()
	var tree := Vector2i(182, 173)
	w.chunk("surface", tree.x >> 5, tree.y >> 5).set_cell("cover", tree.x & 31, tree.y & 31, "base:oak")
	w.creatures._go(trader, "travel", Vector2i(184, 170), false)
	var crossed := false
	for tick in 800:
		if trader.target != Creature.NO_TARGET:
			w.creatures._move(trader)
		for id: String in roster:
			var guard := w.creatures.get_creature(id)
			if tick % 10 == 0:
				w.creatures._guard_caravan(guard)
			if guard.target != Creature.NO_TARGET:
				w.creatures._move(guard)
			if tree in BodySize.cells(guard.pos, BodySize.of(w.content.get_def(guard.kind))["half"]):
				crossed = true
	check(trader.cell().distance_to(Vector2i(184, 170)) <= 1, "the trader moved along the road")
	for id: String in roster:
		var guard := w.creatures.get_creature(id)
		check(guard.cell().distance_to(trader.cell()) <= 5, "every guard follows, including the rear rank: %s" % guard.cell())
	check(not crossed, "the escort does not walk through trees to keep formation")
