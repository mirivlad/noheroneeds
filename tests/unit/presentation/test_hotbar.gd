extends TestCase
## ADR-0021: Q brings the weapon last chosen or used into the hands and, again,
## gives back what was held; an axe is a weapon, a pick a tool; things moved,
## dropped or stored break nothing.

var bar: Hotbar
var inv := {}


func before_each() -> void:
	bar = Hotbar.new()
	bar.content = ContentRegistry.load_packs(["res://content/base"])
	bar.items.resize(Hotbar.SLOTS)
	bar.items.fill("")
	for pair: Array in [[0, "base:pickaxe"], [2, "base:axe"], [3, "base:bow"], [5, "base:plank"]]:
		bar.items[pair[0]] = pair[1]
	inv = {"base:pickaxe": 1, "base:axe": 1, "base:bow": 1, "base:arrow": 20}
	bar.choose(0)


func after_each() -> void:
	bar.free()


func test_q_takes_a_weapon_and_gives_the_pick_back() -> void:
	check(not bar.is_arm("base:pickaxe"), "a pick is a tool first")
	check(bar.is_arm("base:axe"), "an axe is a weapon, though a tool too")
	eq(bar.snatch(inv), "")
	eq(bar.items[bar.selected], "base:axe", "the first weapon, none chosen yet")
	eq(bar.snatch(inv), "")
	eq(bar.items[bar.selected], "base:pickaxe", "Q again: the pick back")


func test_q_takes_the_weapon_last_chosen() -> void:
	bar.choose(3)  # the bow, by hand
	bar.choose(0)  # back to the pick, by hand
	bar.snatch(inv)
	eq(bar.items[bar.selected], "base:bow", "the bow, chosen last")
	bar.choose(2)  # the axe, by hand: the last weapon now
	bar.choose(0)
	bar.snatch(inv)
	eq(bar.items[bar.selected], "base:axe")
	bar.used("base:bow")  # a shot with the bow (from wherever)
	bar.choose(0)
	bar.snatch(inv)
	eq(bar.items[bar.selected], "base:bow", "the weapon used last")


func test_choosing_by_hand_between_two_qs() -> void:
	bar.snatch(inv)
	bar.choose(5)  # something else by hand
	bar.snatch(inv)
	eq(bar.items[bar.selected], "base:axe", "Q brings the weapon again, not back")
	bar.snatch(inv)
	eq(bar.selected, 5, "and back to what was in the hands then")


func test_gone_and_moved_things_break_nothing() -> void:
	bar.choose(3)
	bar.choose(0)
	inv.erase("base:bow")  # dropped or put into a chest
	bar.snatch(inv)
	eq(bar.items[bar.selected], "base:axe", "the bow is gone: another weapon")
	bar.snatch(inv)
	bar.put(7, "base:axe", 2)  # the axe dragged to another slot
	bar.snatch(inv)
	eq(bar.selected, 7, "found where it went")
	inv.erase("base:pickaxe")  # the pick stored away meanwhile
	bar.snatch(inv)
	eq(bar.items[bar.selected], "base:pickaxe", "back to the pick's slot")
	eq(bar.held(inv), "", "which holds nothing now: empty hands, no harm")
	inv.erase("base:axe")
	eq(bar.snatch(inv), "оружия в ячейках нет (I — положить)", "no weapon left: said so")
