extends TestCase


func _settlements(biome: String) -> Settlements:
	return Settlements.new(12345, ContentRegistry.load_packs(["res://content/base"]),
		func(_x: int, _y: int) -> bool: return false, 8,
		func(_x: int, _y: int) -> String: return biome)


func test_one_camp_for_a_cluster_and_only_in_forest() -> void:
	var s := _settlements("base:forest")
	var plan := s.camps.of_cluster(0, 0, 0)
	check(not plan.is_empty(), "a suitable forest near the cluster's roads has a camp")
	if plan.is_empty():
		return
	eq(s.camps.of_cluster(0, 0, 0), plan, "one stable camp per cluster")
	check(s.villages(0, 0, 0).size() >= 2, "belongs to ordinary villages")
	for v: Dictionary in s.villages(0, 0, 0):
		check(not (plan["bounds"] as Rect2i).grow(24).intersects(v["bounds"]), "out of the village")
	check(int(plan["population"]) >= 6 and int(plan["population"]) <= 10, "finite initial population")
	eq(_settlements("base:steppe").camps.of_cluster(0, 0, 0), {}, "no invented forest in steppe")


func test_camps_are_independent_of_exploration_order() -> void:
	var a := _settlements("base:forest")
	var b := _settlements("base:forest")
	var first := a.camps.of_cluster(0, 0, 0)
	b.camps.of_cluster(0, 1, 0)
	eq(b.camps.of_cluster(0, 0, 0), first)
	if not first.is_empty():
		eq(b.camps.by_id(first["id"]), first)
		eq(b.camps.plans_touching((first["centre"] as Vector2i).x >> 5, (first["centre"] as Vector2i).y >> 5).size(), 1)


func test_real_geography_has_a_camp_and_new_chunks_stamp_its_contents() -> void:
	var g := SurfaceGenerator.new(12345, ContentRegistry.load_packs(["res://content/base"]))
	var found := {}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if found.is_empty():
				found = g.settlements.camps.of_cluster(0, dx, dy)
	check(not found.is_empty(), "a real forest near the roads can host bandits")
	if found.is_empty():
		return
	var middle: Vector2i = found["centre"]
	var c := g.generate(middle.x >> 5, middle.y >> 5)
	eq(c.meta.get("bandit_camp"), found["id"])
	eq(c.get_cell("structure", posmod(middle.x, 32), posmod(middle.y, 32)), "base:campfire")
	var chest: Vector2i = found["chest"]
	c = g.generate(chest.x >> 5, chest.y >> 5)
	eq(c.get_props(posmod(chest.x, 32), posmod(chest.y, 32)).get("store"), "camp|" + found["id"])
