extends TestCase

var content: ContentRegistry

func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])

func _templates() -> Array:
	var chosen := []
	var definitions: Array = content.get_def("base:village")["buildings"]
	for i in 6:
		var template: Dictionary = definitions[i % definitions.size()].duplicate(true)
		template["architecture"] = SettlementArchitecture.plan(431, "terrain", str(i), template, "forest")
		chosen.append(template)
	return chosen

func test_parcels_and_wide_streets_fit_around_a_lake() -> void:
	var lake := Rect2i(-26, -90, 53, 150)
	var land := func(x: int, y: int) -> Dictionary:
		return {"what": "water" if lake.has_point(Vector2i(x, y)) else "land", "height": .50 + y * .0001}
	var fields := [{"rect": Rect2i(0, 0, 6, 4), "crop": "base:wheat_crop", "planted_hours": 1.0}]
	var pen := {"rect": Rect2i(0, 0, 7, 5), "animals": {"base:sheep": 2}}
	var layout := SettlementTerrainLayout.make(_templates(), fields, pen, land, Vector2i.ZERO, 431)
	if not check(not layout.is_empty(), "a lake is left between individually fitted parcels"): return
	eq(layout.buildings.size(), 6, "all planned buildings fit")
	eq(layout.fields.size(), 1, "the field is retained")
	var plans := Settlements.new(431, content, func(x: int, y: int) -> bool: return lake.has_point(Vector2i(x, y)), 0, Callable(), land)
	var site := plans._site(layout, Vector2i.ZERO)
	for rect: Rect2i in site.plots + [site.square, site.parking_yard, site.parking_reserve, layout.fields[0].rect, layout.pen.rect]:
		check(not rect.intersects(lake), "each entire parcel stays out of water")
	var cells := {}
	for street: Rect2i in layout.streets:
		check(street.size.x >= 3 and street.size.y >= 3, "streets have at least three cells of clearance")
		check(not street.intersects(lake), "the whole street width avoids the lake")
		for y in range(street.position.y, street.end.y):
			for x in range(street.position.x, street.end.x): cells[Vector2i(x, y)] = true
	var reached := {layout.root: true}
	var queue: Array[Vector2i] = [layout.root]
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		for direction: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next := at + direction
			if cells.has(next) and not reached.has(next):
				reached[next] = true
				queue.append(next)
	eq(reached.size(), cells.size(), "every street joins the same real network")
	for building: Dictionary in layout.buildings:
		var design: Dictionary = building.template.architecture
		var door: Vector2i = SettlementArchitecture.local_cell(design, design.door) + building.rect.position
		var outward: Vector2i = ContentRegistry.FACINGS[SettlementArchitecture.facing(design)]
		check(reached.has(door + outward * 3), "every door has a connected approach")
	check(not layout.approaches.is_empty(), "the local streets have a real exit to the road grid")
	for approach: Array in layout.approaches:
		eq(approach[0], layout.root, "an outside road starts at the caravan lane")
		var end: Vector2i = approach[-1]
		check(posmod(end.x, 8) == 0 and posmod(end.y, 8) == 0, "handoff to the coarse route is aligned")
		for at: Vector2i in approach:
			for offset: Vector2i in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN, Vector2i.ONE, -Vector2i.ONE, Vector2i(-1, 1), Vector2i(1, -1)]:
				check(not lake.has_point(at + offset), "the full approach width stays on land")

func test_small_islands_do_not_turn_into_filled_land() -> void:
	var land := func(x: int, y: int) -> Dictionary:
		return {"what": "land" if posmod(x, 16) < 8 and posmod(y, 16) < 8 else "water", "height": .1}
	check(SettlementTerrainLayout.make(_templates(), [], {}, land, Vector2i.ZERO, 431).is_empty(), "reject terrain without room for a real caravan yard")

func test_dry_high_plateaus_are_scored_without_requiring_a_low_altitude() -> void:
	var land := func(_x: int, _y: int) -> Dictionary: return {"what": "land", "height": .55}
	var plans := Settlements.new(431, content, func(_x: int, _y: int) -> bool: return false, 0, Callable(), land)
	check(plans._site_score(Vector2i.ZERO) > -INF, "a dry plateau is a candidate, with its parcels checked separately")
