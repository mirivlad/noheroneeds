extends TestCase
## ADR-0041: a bag of cells, a stack a cell; the cells laid out as the player
## arranged them.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])


func test_cells_by_stack_size() -> void:
	eq(Bag.used(_content, {}), 0)
	eq(Bag.used(_content, {"base:plank": 99}), 1, "a full stack, a cell")
	eq(Bag.used(_content, {"base:plank": 100, "base:axe": 1}), 3, "one over: a second cell; an axe its own")
	eq(Bag.room_for(_content, {"base:plank": 100}, "base:plank", 2), 98, "what the second cell still takes")
	eq(Bag.room_for(_content, {"base:plank": 100}, "base:plank", 3), 98 + 99, "and a free cell")
	eq(Bag.room_for(_content, {"base:plank": 100}, "base:axe", 2), 0, "no free cell: no axe")


func test_cells_laid_out_as_arranged() -> void:
	var stacks := {"base:plank": 120, "base:axe": 1, "base:stone": 5}
	var laid := Bag.lay_out(_content, stacks, ["", "", "base:axe", "", "base:stone"], 6)
	var order: Array = laid["order"]
	eq(order[2], "base:axe", "where it was put")
	eq(order[4], "base:stone")
	eq([order[0], order[1]], ["base:plank", "base:plank"], "the planks' two stacks in the first free cells")
	eq(laid["cells"][0], ["base:plank", 99], "a full stack first")
	eq(laid["cells"][1], ["base:plank", 21], "what is left in the next")
	eq((laid["cells"] as Array).size(), 6, "as many cells as the bag has")
	# The stone is gone: its cell frees; fewer planks: one cell of them.
	laid = Bag.lay_out(_content, {"base:plank": 50, "base:axe": 1}, order, 6)
	eq(laid["order"], ["base:plank", "", "base:axe", "", "", ""])
	# More than fits: cells past the bag's (an overfull bag shows all).
	eq((Bag.lay_out(_content, {"base:axe": 1, "base:pickaxe": 1, "base:bow": 1}, [], 2)["cells"] as Array).size(), 3)
