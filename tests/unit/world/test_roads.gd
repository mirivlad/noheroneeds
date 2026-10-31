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