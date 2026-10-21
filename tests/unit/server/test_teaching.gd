extends TestCase
## ADR-0047 in a village: a dweller teaches what its trade knows, on its
## terms (coins, its village's trust, one's skill), and not to one it bears
## a grudge; it sells blueprints; its goods are as well made as its trade
## makes them, priced by that; a master's work sells to it for more.

var w: ServerWorld
var _content: ContentRegistry
var plan: Dictionary


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 12345})
	plan = w.generator.settlements.home_plan()
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
		for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
			w.chunk("surface", cx, cy)
	w.world_time = Daylight.DAY_MS + 10 * Daylight.HOUR_MS  # by day: awake


func after_each() -> void:
	w.close()


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _dweller(profession: String) -> Creature:
	for c: Creature in w.creatures.creatures.values():
		if String(c.job.get("profession", "")) == profession:
			return c
	return null


func _player_by(c: Creature) -> String:
	var pc := PortableCharacter.create("Аня", "base:human_f")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + pc.character_id, pc)
	w.move_character(pc.character_id, c.pos + Vector2i(Movement.UNIT, 0))
	return pc.character_id


func _terms(a: String, c: Creature, recipe: String) -> Dictionary:
	var talk := _req(a, {"type": "talk", "creature": c.id})
	for t: Dictionary in talk.get("teaches", []):
		if t["recipe"] == recipe:
			return t
	return {}


func test_a_dweller_teaches_on_its_terms_and_its_village_trust() -> void:
	var farmer := _dweller("base:farmer")
	check(farmer != null, "a farmer in the village")
	if farmer == null:
		return
	var a := _player_by(farmer)
	eq(_req(a, {"type": "talk", "creature": farmer.id}).get("standing"), 0, "a stranger to the village")
	eq(TalkPanel.trust_word(0, false), "чужак")
	var t := _terms(a, farmer, "base:bake_bread")
	check(not t.is_empty(), "it would teach bread")
	eq(t.get("price"), 15)
	var strict := int(t["standing"]) > 0
	eq(t["why"], "standing" if strict else "no_money", "a stranger with no coins: %s" % str(t))
	var learn := {"type": "learn", "creature": farmer.id, "recipe": "base:bake_bread"}
	eq(_req(a, learn.duplicate()).get("reason"), t["why"])
	w.grant(a, "base:coin", 40)
	if strict:  # a strict one teaches those its village trusts: a request done
		w.chronicles._trust(w.chronicles.of(String(farmer.job["village"])), a, 1)
	var r := _req(a, learn.duplicate())
	check(r.get("ok", false), str(r))
	check(w.knowledge.knows(a, "base:bake_bread"), "learned")
	eq(w.inventory(a).count("base:coin"), 25, "for fifteen coins")
	eq(_terms(a, farmer, "base:bake_bread")["why"], "known_already")
	eq(_req(a, {"type": "learn", "creature": farmer.id, "recipe": "base:forge_iron_axe"}).get("reason"), "not_taught",
		"a farmer does not teach the forge")
	# Struck, it bears a grudge and will not teach; the village trusts one less.
	var before := w.chronicles.standing(farmer, a)
	w.combat.hurt(farmer.id, 1, a)
	eq(w.chronicles.standing(farmer, a), before - 1, "trust lost")
	eq(_req(a, {"type": "learn", "creature": farmer.id, "recipe": "base:cook_stew"}).get("reason"), "grudge")


func test_a_smiths_goods_blueprints_and_what_it_pays_for_a_masters_axe() -> void:
	var smith := _dweller("base:smith")
	check(smith != null, "a smith in the village")
	if smith == null:
		return
	var a := _player_by(smith)
	var g := _req(a, {"type": "trade_look", "creature": smith.id})
	check(g.get("ok", false), str(g))
	var axe: Array = g["sells"]["base:axe"]
	var q := Wear.quality(axe[2])
	check(q >= 0.7 and q <= 0.9, "its axes are as well made as a smith makes them: %.2f" % q)
	eq(int(axe[1]), maxi(1, roundi(15 * Wear.worth(_content, axe[2]))), "and priced by it")
	check((g["blueprints"] as Dictionary).has("base:make_bow"), "it sells a bow's blueprint")
	w.grant(a, "base:coin", 200)
	check(_req(a, {"type": "trade", "creature": smith.id, "item": "base:axe", "count": 1}).get("ok", false), "an axe bought")
	eq(w.inventory(a).state_of("base:axe", 0), axe[2], "as it was made")
	check(_req(a, {"type": "trade", "creature": smith.id, "blueprint": "base:make_bow"}).get("ok", false), "a blueprint bought")
	eq(w.inventory(a).state_of("base:blueprint", 0), {"recipe": "base:make_bow"})
	# What it pays: a master's axe more than a novice's.
	var coins := w.inventory(a).count("base:coin")
	w.grant(a, "base:axe", 2, [{"quality": 0.5, "by": "Новичок"}, {"quality": 1.0, "mods": ["base:fine", "base:sturdy"], "by": "Мастер"}])
	var r := _req(a, {"type": "trade", "creature": smith.id, "item": "base:axe", "count": 1, "buy": false, "copy": 1})
	check(r.get("ok", false), str(r))
	var novice_paid := w.inventory(a).count("base:coin") - coins
	coins = w.inventory(a).count("base:coin")
	r = _req(a, {"type": "trade", "creature": smith.id, "item": "base:axe", "count": 1, "buy": false, "copy": 1})
	check(r.get("ok", false), str(r))
	var master_paid := w.inventory(a).count("base:coin") - coins
	check(master_paid >= 2 * novice_paid, "a master's axe sells for twice a novice's at least: %d vs %d" % [master_paid, novice_paid])
	# The window says beforehand what the dweller pays for each copy.
	var tp := TradePanel.new()
	tp.content = _content
	tp.goods = g
	eq(tp.price_of("base:axe", {"quality": 1.0, "mods": ["base:fine", "base:sturdy"]}), master_paid, "the trade window's price is the one paid")
	eq(tp.price_of("base:axe", {"quality": 0.5}), novice_paid)
	tp.free()
