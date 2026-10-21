extends TestCase
## ADR-0047: the rules of mastery — a novice's chance against how hard a
## recipe is, a master's near-certainty; quality from half to whole;
## enhancements from high mastery on, a master's at least two; what a
## failure spoils; skills' effects; the quality and enhancements of a copy in
## its wear and worth.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())


func test_a_novice_fails_hard_things_a_master_hardly_ever() -> void:
	check(absf(Mastery.chance(100, 0, 0) - 0.1) < 0.001, "a novice at the hardest: one in ten")
	check(absf(Mastery.chance(50, 0, 0) - 0.5) < 0.001, "at a simple one: one in two")
	check(Mastery.chance(0, 0, 0) >= 0.89, "the primitive ones hardly fail (flint, cord)")
	check(absf(Mastery.chance(100, 100, 100) - 0.99) < 0.001, "a master: 99 in 100, however hard")
	var last := 0.0
	for m in range(0, 101, 10):
		var c := Mastery.chance(60, m, 0)
		check(c >= last, "practice helps: %d -> %.2f" % [m, c])
		last = c
	check(Mastery.chance(60, 0, 100) > Mastery.chance(60, 0, 0), "a skilled smith does a new smithing recipe better")


func test_quality_goes_from_half_to_whole_and_a_masters_is_whole() -> void:
	for roll: float in [0.0, 0.5, 1.0]:
		check(Mastery.quality(0, 0, roll) >= 0.5 and Mastery.quality(0, 0, roll) <= 0.55, "a novice's: about half (%.2f)" % Mastery.quality(0, 0, roll))
		eq(Mastery.quality(100, 100, roll), 1.0, "a master's: whole")
	check(Mastery.quality(60, 60, 0.5) > 0.7 and Mastery.quality(60, 60, 0.5) < 0.8, "sure of success, the quality still grows")


func test_a_master_makes_two_enhancements_at_least_a_novice_none() -> void:
	var total := 0
	for i in 1000:
		var roll := float(i) / 1000.0
		var n := Mastery.enhancements(100, 100, roll)
		check(n >= 2, "a master: two at least")
		total += n
		eq(Mastery.enhancements(30, 30, roll), 0, "a novice: none")
	check(absf(total / 1000.0 - Mastery.MOST_ENHANCEMENTS) < 0.05, "on average 2.4: %f" % (total / 1000.0))
	var hoe := Mastery.fitting(_content, "base:hoe")
	check(hoe.size() >= 3, "a hoe has three enhancements and more to come by: %s" % str(hoe))
	check(not Mastery.fitting(_content, "base:linen_shirt").has("base:sturdy"), "a shirt does not wear: no sturdiness for it")
	check(Mastery.fitting(_content, "base:wool_cloak").has("base:warm"), "a cloak may come warm")


## The author's mark: a master of hoes makes about 99 in 100, whole, with
## two of the three enhancements at least. Practice gets there in some
## hundred-odd attempts.
func test_from_novice_to_master_of_hoes_by_practice() -> void:
	var xp := 0
	var attempts := 0
	var made := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var difficulty := int(_content.get_def("base:make_hoe")["difficulty"])
	while Mastery.level_of(xp, Mastery.RECIPE_K) < 100 and attempts < 1000:
		attempts += 1
		var works := rng.randf() < Mastery.chance(difficulty, Mastery.level_of(xp, Mastery.RECIPE_K), 40)
		xp += Mastery.XP_SUCCESS if works else Mastery.XP_FAIL
		made += 1 if works else 0
	check(attempts > 80 and attempts < 200, "a master after %d attempts" % attempts)
	var ok := 0
	for i in 100:
		ok += 1 if rng.randf() < Mastery.chance(difficulty, 100, 40) else 0
	check(ok >= 95, "then about 99 hoes of 100: %d" % ok)
	eq(Mastery.quality(100, 40, 0.3), 1.0, "whole")


func test_a_failure_spoils_half_but_never_what_is_precious() -> void:
	eq(Mastery.spoiled(_content, {"base:plank": 1, "base:iron_ingot": 2}), {"base:plank": 1}, "the iron is melted again")
	eq(Mastery.spoiled(_content, {"base:fiber": 3}), {"base:fiber": 2}, "half, rounded up")


func test_skills_give_their_effects_by_level() -> void:
	eq(Mastery.effect(_content, "base:woodcutting", 0, "pace"), 1.0, "a novice: as it is")
	check(absf(Mastery.effect(_content, "base:woodcutting", 100, "pace") - 0.8) < 0.001, "a woodcutter: a fifth faster")
	check(absf(Mastery.effect(_content, "base:woodcutting", 50, "wear") - 0.85) < 0.001, "halfway: half of it")
	eq(Mastery.effect(_content, "base:melee", 0, "damage"), 0.0)
	eq(Mastery.effect(_content, "base:melee", 100, "damage"), 2.0)
	eq(Mastery.effect(_content, "base:building", 100, "pace"), 1.0, "a skill gives only what it says")
	check(Mastery.level_of(Mastery.XP_SUCCESS * 120, Mastery.RECIPE_K) >= 99, "some 120 attempts that worked: a master")


func test_quality_and_enhancements_show_in_wear_and_worth() -> void:
	var novice := {"quality": 0.5}
	var master := {"quality": 1.0, "mods": ["base:sturdy", "base:keen"]}
	eq(Wear.limit(_content, "base:spear", novice), 150, "half quality: half the durability")
	eq(Wear.limit(_content, "base:spear", master), 375, "whole and sturdy: a quarter more")
	eq(Wear.damage(_content, "base:spear", master, 5), 6, "keen: one more")
	check(Wear.worth(_content, master) > 1.5 * Wear.worth(_content, {}), "a master's thing is worth much more than a plain one")
	check(Wear.worth(_content, novice) < Wear.worth(_content, {}), "a novice's less")
	eq(Wear.armor(_content, "base:leather_armor", {"mods": ["base:reinforced"]}), 3, "reinforced: armour +1")
	eq(Wear.warmth(_content, "base:wool_cloak", {"mods": ["base:warm"]}), 4, "warm: +1")
