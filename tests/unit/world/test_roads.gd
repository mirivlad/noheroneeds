extends TestCase
## Roads between villages are continuous and passable for a caravan: every
## cell of the way is checked, short water is bridged with a deck wide enough
## for the cart, a too long bridge is gone round, and no road is laid over
## deep water or between villages the sea parts.

var content: ContentRegistry


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())


## A settlement plan enough for a road: its street out, its fields' reach.
func _village(id: String, centre: Vector2i) -> Dictionary:
	return {"id": id, "centre": centre, "bounds": Rect2i(centre - Vector2i(12, 12), Vector2i(24, 24)),
		"ends": [centre + Vector2i(-6, 0), centre + Vector2i(6, 0)], "half": 5,
		"road": "base:dirt", "bridge": "base:bridge"}


## Land with water (and deep water) where the rects say; higher, dearer land
## elsewhere so that the coarse search still tries the water first.
func _world(water: Array, deep: Array, height := 0.1) -> Settlements:
	var wet := water.duplicate()
	var deeps := deep.duplicate()
	var land := func(x: int, y: int) -> Dictionary:
		var at := Vector2i(x, y)
		for r: Rect2i in deeps:
			if r.has_point(at):
				return {"what": "deep", "height": 0.14, "biome": 0}
		for r: Rect2i in wet:
			if r.has_point(at):
				return {"what": "water", "height": 0.12, "biome": 0}
		return {"what": "land", "height": height, "biome": 0}
	return Settlements.new(1, content, func(_x: int, _y: int) -> bool: return false, 8, Callable(), land)


func _road(a: Vector2i, b: Vector2i, water: Array, deep: Array, height := 0.1) -> Dictionary:
	return _world(water, deep, height)._road(_village("a", a), _village("b", b), [0, 0, 0, 0])


func _is_contiguous(path: Array) -> bool:
	for i in range(1, path.size()):
		var d: Vector2i = path[i] - path[i - 1]
		if absi(d.x) > 1 or absi(d.y) > 1:
			return false
	return true


func test_approaches_use_each_side_of_an_asymmetric_village() -> void:
	var s := _world([], [])
	var village := _village("a", Vector2i.ZERO)
	village["bounds"] = Rect2i(-15, -25, 66, 44)
	village["ends"] = [Vector2i(25, 0), Vector2i(25, 0)]
	village["half"] = 54
	var west := s._way_out(village, Vector2i(-100, 0))
	var east := s._way_out(village, Vector2i(100, 0))
	check(west[-1].x < -15 and west[-1].x > -35, "the west exit follows the west edge, not the long east side")
	check(east[-1].x > 51, "the east exit clears the longer yard")
	check(_is_contiguous(west) and _is_contiguous(east), "both approaches are continuous")


func test_short_water_is_bridged_without_a_gap() -> void:
	var road := _road(Vector2i.ZERO, Vector2i(200, 0), [Rect2i(96, -20, 5, 41)], [])
	check(not road.is_empty(), "a road over a short river")
	if road.is_empty():
		return
	var path: Array = road["path"]
	check(_is_contiguous(path), "every step of the way is a neighbouring cell")
	var wet := path.filter(func(at: Vector2i) -> bool: return at.x >= 96 and at.x <= 100)
	eq(wet.size(), 5, "the five cells of the river are in the way, not dropped")
	for at: Vector2i in wet:
		for o: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			var deck: Dictionary = road["cells"].get(at + o, {})
			eq(String(deck.get("over_water", "")), "base:bridge", "bridge deck at %s" % (at + o))
	# The bridge meets land on both banks.
	var first := -1
	var last := -1
	for i in path.size():
		var at: Vector2i = path[i]
		if at.x >= 96 and at.x <= 100:
			if first < 0:
				first = i
			last = i
	check(first > 0, "a bank before the bridge")
	check(last >= 0 and last + 1 < path.size(), "a bank after it")
	if first > 0:
		check(_what(path[first - 1], [Rect2i(96, -20, 5, 41)], []) != "water", "the way comes from land")
	if last >= 0 and last + 1 < path.size():
		check(_what(path[last + 1], [Rect2i(96, -20, 5, 41)], []) != "water", "and goes on to land")
	# No part of the deck hangs over deep water.
	for at: Vector2i in (road["cells"] as Dictionary):
		check(_what(at, [Rect2i(96, -20, 5, 41)], []) != "deep", "no deck over deep water at %s" % at)


func test_a_too_long_bridge_is_gone_round_by_land() -> void:
	# A long lake, but the land round it is high and dear: the coarse search
	# first goes straight across; the cell-by-cell check sends it round.
	var lake := [Rect2i(80, -30, 31, 61)]
	var road := _road(Vector2i.ZERO, Vector2i(200, 0), lake, [], 0.4)
	check(not road.is_empty(), "a way round the long water")
	if road.is_empty():
		return
	var path: Array = road["path"]
	check(_is_contiguous(path), "the detour is continuous too")
	for at: Vector2i in path:
		check(_what(at, lake, []) != "water" and _what(at, lake, []) != "deep", "the detour is dry at %s" % at)
	check(not path.any(func(at: Vector2i) -> bool: return at.x >= 80 and at.x <= 110 and at.y >= -30 and at.y <= 30),
		"the way does not cross the lake")


func test_the_sea_between_two_villages_makes_no_road() -> void:
	var road := _road(Vector2i.ZERO, Vector2i(200, 0), [Rect2i(70, -4000, 60, 8000)], [])
	check(road.is_empty(), "no road across water that has no end in reach")


func test_a_bridge_never_stands_over_deep_water() -> void:
	# Deep water lies under one corner of the two-cell deck at the only narrow
	# crossing; the way must shift or there is no road.
	var river := [Rect2i(96, -20, 5, 41)]
	var deep := [Rect2i(97, 1, 1, 1)]
	var road := _road(Vector2i.ZERO, Vector2i(200, 0), river, deep)
	if road.is_empty():
		return  # no way: honest
	for at: Vector2i in (road["cells"] as Dictionary):
		check(_what(at, river, deep) != "deep", "no deck over deep water at %s" % at)


func _what(at: Vector2i, water: Array, deep: Array) -> String:
	for r: Rect2i in deep:
		if r.has_point(at):
			return "deep"
	for r: Rect2i in water:
		if r.has_point(at):
			return "water"
	return "land"


func test_a_terrain_step_is_a_pass_while_a_crag_remains_blocked() -> void:
	for cliff: bool in [true, false]:
		var land := func(x: int, _y: int) -> Dictionary:
			return {"what": "rock" if x >= 88 and x <= 104 else "land", "height": .3, "cliff": cliff}
		var plans := Settlements.new(1, content, func(_x: int, _y: int) -> bool: return false, 0, Callable(), land)
		var road := plans._road(_village("a", Vector2i.ZERO), _village("b", Vector2i(200, 0)), [0, 0, 0, 0])
		check(not road.is_empty() if cliff else road.is_empty(), "cut a pass through a terrain step, never a solid crag barrier")


func test_full_road_width_avoids_walls_at_diagonals_and_turns() -> void:
	var plans := _world([], [])
	var diagonal: Array[Vector2i] = []
	plans._line(diagonal, Vector2i.ZERO, Vector2i(16, 16))
	check(not plans._bad_cells(diagonal, [Rect2i(6, 5, 1, 1)]).is_empty(), "the wall beside the diagonal is in its full width")
	var corner: Array[Vector2i] = []
	plans._line(corner, Vector2i.ZERO, Vector2i(8, 0))
	corner.pop_back()  # adjacent segments share one vertex, as in _way_path
	plans._line(corner, Vector2i(8, 0), Vector2i(8, 8))
	check(not plans._bad_cells(corner, [Rect2i(7, -1, 1, 1)]).is_empty(), "the outside of the turn must also be clear")
	var a := _village("a", Vector2i.ZERO)
	var b := _village("b", Vector2i(80, 80))
	var wall := Rect2i(6, 5, 1, 1)
	for village: Dictionary in [a, b]:
		village["adaptive"] = true
		village["ends"] = [village["centre"], village["centre"]]
		village["road_obstacles"] = [wall]
	var road := plans._road(a, b, [0, 0, 0, 0])
	if not check(not road.is_empty(), "a road can go around the obstructed diagonal"): return
	for at: Vector2i in road.cells:
		check(not wall.has_point(at), "no materialized part of the road clips the wall")


# Recipe 20: route validation follows the materialized footprint.
func _terrain(sample: Callable, recipe := 20) -> Settlements:
	return Settlements.new(1, content, func(_x: int, _y: int) -> bool: return false, 8, Callable(), sample, "", recipe)

func _line_path() -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	for x in 24: path.append(Vector2i(x, 0))
	return path

func test_a_chasm_is_a_costly_crossing_and_long_decks_are_rejected() -> void:
	var land := func(x: int, _y: int) -> Dictionary: return {"what": "chasm" if x >= 2 and x <= 21 else "land", "height": .1}
	var current := _terrain(land)
	var old := _terrain(land, 18)
	check(current._point(Vector2i(1, 0)).x >= 12, "the route does not treat a ravine like flat land")
	eq(old._point(Vector2i(1, 0)).x, 1.0, "saved roads retain the old recipe")
	check(not current._bad_cells(_line_path()).is_empty(), "a twenty-cell chasm bridge is refused")
	eq(old._bad_cells(_line_path()), [], "the legacy road validator is preserved")

func test_short_chasm_crossings_need_land_at_both_full_width_ends() -> void:
	var land := func(x: int, y: int) -> Dictionary:
		return {"what": "chasm" if (x >= 8 and x <= 11) or (x == 12 and y == 1) else "land", "height": .1}
	check(not _terrain(land)._bad_cells(_line_path()).is_empty(), "the second lane cannot end over the ravine")
	var good := func(x: int, _y: int) -> Dictionary: return {"what": "chasm" if x >= 8 and x <= 11 else "land", "height": .1}
	eq(_terrain(good)._bad_cells(_line_path()), [], "a short two-ended crossing remains possible")

func test_side_of_a_road_cannot_cut_an_unchecked_crag() -> void:
	var land := func(x: int, y: int) -> Dictionary:
		return {"what": "rock" if x == 8 and y == 1 else "land", "height": .1, "cliff": false}
	check(not _terrain(land)._bad_cells(_line_path()).is_empty(), "actual materialized width is checked")
	eq(_terrain(land, 19)._bad_cells(_line_path()), [], "recipe 19's validator is retained")

func test_a_road_cannot_sprout_a_hanging_lane_along_a_ravine() -> void:
	var land := func(_x: int, y: int) -> Dictionary: return {"what": "chasm" if y == 1 else "land", "height": .1}
	check(not _terrain(land)._bad_cells(_line_path()).is_empty(), "a bridge must cross the ravine, not run along its bank")
	eq(_terrain(land, 19)._bad_cells(_line_path()), [], "the stored legacy route remains unchanged")

func test_a_long_cliff_cut_is_rerouted_but_a_narrow_pass_still_works() -> void:
	var long_cut := func(x: int, _y: int) -> Dictionary: return {"what": "rock" if x >= 7 and x <= 13 else "land", "height": .1, "cliff": true}
	check(not _terrain(long_cut)._bad_cells(_line_path()).is_empty(), "no seven-cell trench through a cliff")
	var short_pass := func(x: int, _y: int) -> Dictionary: return {"what": "rock" if x == 8 else "land", "height": .1, "cliff": true}
	eq(_terrain(short_pass)._bad_cells(_line_path()), [], "a narrow worked pass remains available")

func test_road_goes_round_a_long_chasm_instead_of_filling_it() -> void:
	var ravine := Rect2i(90, -20, 22, 41)
	var land := func(x: int, y: int) -> Dictionary: return {"what": "chasm" if ravine.has_point(Vector2i(x, y)) else "land", "height": .1}
	var road := _terrain(land)._road(_village("a", Vector2i.ZERO), _village("b", Vector2i(200, 0)), [0, 0, 0, 0])
	if not check(not road.is_empty(), "a nearby natural route still connects the villages"): return
	check(_is_contiguous(road["path"]), "the reroute has no missing cells")
	for at: Vector2i in road["cells"]: check(not ravine.has_point(at), "no part of the road becomes a gratuitous long deck")
