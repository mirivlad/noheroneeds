extends TestCase
## ADR-0038: settlements are a function of the seed — every chunk gets its
## part of one in any order; one stands near the spawn point, on dry land,
## out of its clearing; houses have their doors onto streets, a bed inside.

var content: ContentRegistry


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())


func _home_plan(g: SurfaceGenerator) -> Dictionary:
	for p: Dictionary in g.settlements.plans_near(Vector2i.ZERO, 300):
		if String(p["id"]).ends_with("@0,0"):
			return p
	return {}


func test_a_village_stands_near_the_spawn_point_in_every_world() -> void:
	for seed_value in [1, 7, 12345, 99991]:
		var g := SurfaceGenerator.new(seed_value, content)
		var p := _home_plan(g)
		check(not p.is_empty(), "seed %d: a village by the spawn point" % seed_value)
		if p.is_empty():
			continue
		check(Vector2(p["centre"]).length() < 120.0, "a short walk away: %s" % p["centre"])
		check(not (p["bounds"] as Rect2i).has_point(Vector2i.ZERO), "not on the spawn point")
		check((p["homes"] as Array).size() >= 4, "houses enough")


func test_houses_have_a_door_onto_the_street_a_roof_and_a_bed() -> void:
	var g := SurfaceGenerator.new(12345, content)
	var p := _home_plan(g)
	var chunks := {}
	var cell := func(at: Vector2i, layer: String) -> String:
		var k := Vector2i(floori(at.x / 32.0), floori(at.y / 32.0))
		if not chunks.has(k):
			chunks[k] = g.generate(k.x, k.y)
		return (chunks[k] as Chunk).get_cell(layer, at.x - k.x * 32, at.y - k.y * 32)
	for h: Dictionary in p["homes"]:
		var r: Rect2i = h["rect"]
		eq(cell.call(h["door"], "structure"), "base:wood_door", "%s: a door" % h["name"])
		eq((h["door"] as Vector2i).y, r.end.y - 1, "in its south wall")
		eq(cell.call(h["door"] + Vector2i(0, 1), "ground"), "base:dirt", "onto a street")
		eq(cell.call(r.position + Vector2i(2, 2), "roof"), "base:thatch_roof", "a roof over the room")
		eq(cell.call(r.position, "structure"), "base:wood_wall", "walls round it")
		check(h["bed"] != Settlements.NONE and cell.call(h["bed"], "structure") == "base:bed", "a bed to sleep in")
	check(cell.call(p["fire"], "structure") == "base:campfire", "a fire in the street")
	var pen: Dictionary = p["pen"]
	eq(cell.call(pen["gate"], "structure"), "base:wood_gate", "a pen with a gate")


func test_any_order_of_chunks_makes_the_same_village() -> void:
	var a := SurfaceGenerator.new(12345, content)
	var b := SurfaceGenerator.new(12345, content)
	var r: Rect2i = _home_plan(a)["bounds"]
	var ks := []
	for cy in range(floori(r.position.y / 32.0), floori((r.end.y - 1) / 32.0) + 1):
		for cx in range(floori(r.position.x / 32.0), floori((r.end.x - 1) / 32.0) + 1):
			ks.append(Vector2i(cx, cy))
	var first := {}
	for k: Vector2i in ks:
		first[k] = a.generate(k.x, k.y)
	ks.reverse()
	for k: Vector2i in ks:
		check(b.generate(k.x, k.y).same_as(first[k]), "chunk %s the same either way" % k)


func test_malformed_settlements_are_content_errors() -> void:
	var good: Dictionary = content.get_def("base:village").duplicate(true)
	good["id"] = "test:v"
	for bad: Dictionary in [{"houses": [3]}, {"chance": 2}, {"wall": "base:grass"}, {"buildings": []},
			{"buildings": [{"size": [2, 2], "dweller": "x"}]}, {"buildings": [{"size": [5, 4]}]},
			{"buildings": [{"size": [4, 4], "dweller": "x", "furniture": ["base:bed", "base:chest", "base:forge"]}]}]:
		var defs: Array = content.defs.values().filter(func(d: Dictionary) -> bool: return d.get("kind") != "settlement")
		defs.append(good.merged(bad, true))
		check(not ContentRegistry.from_defs(defs).errors.is_empty(), "refused: %s" % str(bad))


## Villages are met often: within a square of 1200 cells round the spawn, a
## good many in every world.
func test_villages_are_met_often() -> void:
	for seed_value in [1, 7, 12345]:
		var g := SurfaceGenerator.new(seed_value, content)
		var n := g.settlements.plans_near(Vector2i.ZERO, 600).size()
		check(n >= 12, "seed %d: %d villages within 600 cells" % [seed_value, n])


## Roads join villages, not each to all: some pairs joined, some not; some
## roads meet another partway (a crossroads); a road is dirt from one
## village's street end to the other's, two cells wide.
func test_roads_join_some_villages_and_meet_at_crossroads() -> void:
	var g := SurfaceGenerator.new(12345, content)
	var s := g.settlements
	var joined := 0
	var apart := 0
	var crossroads := 0
	for ry in range(-3, 4):
		for rx in range(-3, 4):
			if s.plan(0, rx, ry).is_empty():
				continue
			for dir in 2:
				var other := s.plan(0, rx + (1 - dir), ry + dir)
				if other.is_empty():
					continue
				var road := s.road_of(0, rx, ry, dir)
				if road.is_empty():
					apart += 1
					continue
				joined += 1
				var cells: Dictionary = road["cells"]
				var ends: Array = s.plan(0, rx, ry)["ends"]
				if dir == 1 and not (cells.has(ends[0]) or cells.has(ends[1])):
					crossroads += 1  # from the southern village to the eastern road, not to this one
	check(joined >= 6, "roads: %d" % joined)
	check(apart >= 2, "not every pair: %d apart" % apart)
	check(crossroads >= 1, "crossroads: %d" % crossroads)
	# One road on the ground: dirt where it runs, on dry land.
	var road := {}
	for ry in range(-3, 4):
		for rx in range(-3, 4):
			if road.is_empty():
				road = s.road_of(0, rx, ry, 0)
	check(not road.is_empty(), "a road east somewhere")
	var some: Vector2i = (road["cells"] as Dictionary).keys()[(road["cells"] as Dictionary).size() / 2]
	var k := Vector2i(floori(some.x / 32.0), floori(some.y / 32.0))
	eq(g.generate(k.x, k.y).get_cell("ground", some.x - k.x * 32, some.y - k.y * 32), "base:dirt", "the road on the ground")


## Biomes by climate (warmth, wetness): all of them are met in a world,
## the snow of the tundra never next to the steppe.
func test_every_biome_is_met_and_cold_keeps_from_the_steppe() -> void:
	var g := SurfaceGenerator.new(12345, content)
	var seen := {}
	var touching := 0
	for y in range(-1500, 1500, 24):
		for x in range(-1500, 1500, 24):
			var b := g.biome_id_at(x, y)
			seen[b] = true
			if b == "base:tundra" and "base:steppe" in [g.biome_id_at(x + 24, y), g.biome_id_at(x, y + 24)]:
				touching += 1
	for b: String in ["base:meadow", "base:forest", "base:taiga", "base:grove", "base:swamp", "base:steppe", "base:tundra", "base:rocky"]:
		check(seen.has(b), "%s is met" % b)
	eq(touching, 0, "tundra and steppe apart")
