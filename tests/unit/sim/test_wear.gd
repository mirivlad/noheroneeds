extends TestCase
## ADR-0046: each copy keeps its own state in an inventory; the rules of
## wear — what a thing lasts, dull and broken, mends that cost in proportion
## and take a share off, the worth of a worn thing.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())


func test_copies_keep_their_states_in_order() -> void:
	var inv := Inventory.new()
	inv.add("base:axe", 1)
	check(inv.states.is_empty(), "plain copies keep no states")
	inv.add("base:axe", 2, [{"wear": 10}, {"wear": 20}])
	eq(inv.count("base:axe"), 3)
	eq(inv.states_of("base:axe"), [{}, {"wear": 10}, {"wear": 20}], "what comes goes to the end")
	eq(inv.take("base:axe", 1, 1), [{"wear": 10}], "a named copy is taken")
	eq(inv.states_of("base:axe"), [{}, {"wear": 20}])
	inv.to_front("base:axe", 1)
	eq(inv.state_of("base:axe", 0), {"wear": 20}, "a copy put first is the one in use")
	eq(inv.take("base:axe", 3), [], "not so many: nothing taken")
	eq(inv.count("base:axe"), 2)
	check(inv.remove("base:axe", 1), "the last one goes")
	eq(inv.states_of("base:axe"), [{"wear": 20}])
	inv.set_state("base:axe", 0, {})
	check(not inv.states.has("base:axe"), "all plain again: no states kept")
	inv.add("base:plank", 5)
	inv.add("base:pickaxe", 1, [{"wear": 3, "repairs": 1}])
	var back := Inventory.from_data(Cbor.decode(Cbor.encode(inv.to_data())).value)
	eq(back.stacks, inv.stacks, "counts saved")
	eq(back.states_of("base:pickaxe"), [{"wear": 3, "repairs": 1}], "and each copy's state")


func test_a_thing_lasts_dulls_breaks_and_is_mended_a_few_times() -> void:
	var axe := "base:axe"
	eq(Wear.durability(_content, axe), 400)
	eq(Wear.condition(_content, axe, {}), 1.0, "new")
	check(not Wear.wears(_content, "base:plank"), "planks do not wear")
	eq(Wear.condition(_content, "base:plank", {"wear": 99}), 1.0)
	var s := Wear.used({}, 290)
	check(not Wear.dull(_content, axe, s), "a quarter left and more: as new")
	s = Wear.used(s, 20)
	check(Wear.dull(_content, axe, s), "less than a quarter: dull")
	eq(Wear.pace(_content, axe, s), Wear.DULL_PACE, "slower")
	eq(Wear.damage(_content, axe, s, 4), 3, "and weaker")
	s = Wear.used(s, 90)
	check(Wear.broken(_content, axe, s), "at its durability: broken")
	eq(Wear.mends_left(_content, axe, s), 4, "mended four times at most")
	eq(Wear.mend_cost(_content, axe, s), {"base:plank": 1, "base:stone": 1}, "a full mend: the repair's materials")
	eq(Wear.mend_cost(_content, axe, {"wear": 40}), {"base:plank": 1, "base:stone": 1}, "a little wear: still one of each (rounded up)")
	eq(Wear.mend_cost(_content, "base:pickaxe", {"wear": 100}), {"base:plank": 1, "base:stone": 1},
		"a quarter worn pick: half its stones (one of two)")
	var m := Wear.mended(s)
	eq(Wear.spent(m), 0, "mended: no wear")
	eq(Wear.limit(_content, axe, m), 340, "but it lasts less: 15% off")
	for i in 3:
		m = Wear.mended(Wear.used(m, 10))
	eq(Wear.limit(_content, axe, m), 160, "four mends: 40% of new")
	eq(Wear.mends_left(_content, axe, Wear.used(m, 10)), 0, "and no more")
	check(not Wear.mendable(_content, "base:flint_axe", {"wear": 5}), "flint is not mended")
	check(Wear.value(_content, axe, {"wear": 200}) < 0.51 and Wear.value(_content, axe, {"wear": 200}) > 0.49, "half worn: worth half")
	eq(Wear.value(_content, axe, {"wear": 400}), Wear.BROKEN_VALUE, "broken: little")


func test_every_tool_weapon_and_armour_wears_and_flint_alone_is_not_mended() -> void:
	for id: String in _content.defs:
		var d := _content.get_def(id)
		if d.get("kind") != "item":
			continue
		if d.has("tools") or d.has("weapon") or int(d.get("armor", 0)) > 0:
			check(Wear.wears(_content, id), "%s wears" % id)
			check(d.has("repair") or String(id).begins_with("base:flint_"), "%s is mended, or is flint" % id)
		if d.has("repair"):
			check(not Wear.mend_cost(_content, id, {"wear": 1}).is_empty(), "%s: a mend costs something" % id)
	# Better material lasts longer.
	check(Wear.durability(_content, "base:flint_axe") < Wear.durability(_content, "base:axe")
		and Wear.durability(_content, "base:axe") < Wear.durability(_content, "base:iron_axe"), "flint < stone < iron")
	check(Wear.durability(_content, "base:flint_pick") < Wear.durability(_content, "base:pickaxe")
		and Wear.durability(_content, "base:pickaxe") < Wear.durability(_content, "base:iron_pickaxe"), "the same for picks")


func test_the_card_tells_the_condition() -> void:
	var card := ItemCard.text(_content, "base:axe", {"wear": 100})
	check(card.begins_with("Каменный топор"), card)
	check(card.contains("Состояние: 75%"), card)
	check(card.contains("Износ: 100 из 400"), card)
	check(card.contains("у верстака"), card)
	check(ItemCard.text(_content, "base:axe", {"wear": 400}).contains("сломано"), "broken told")
	check(ItemCard.text(_content, "base:flint_axe", {}).contains("развалится"), "flint falls apart")
	eq(ItemCard.text(_content, "base:plank", {}, 12), "Доска ×12", "a plain thing: its name and count")
	check(ItemCard.text(_content, "base:leather_armor", {"wear": 300}).contains("Защита: нет"), "broken armour keeps nothing off")
