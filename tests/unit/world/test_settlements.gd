extends TestCase
## ADR-0038, ADR-0054: settlements are a function of the seed — every chunk
## gets its part of one in any order; one stands near the spawn point, on
## dry land, out of its clearing; houses have their doors onto streets, a
## bed inside. Villages come in clusters joined by roads that go round the
## heights and deep water; some clusters are joined with their neighbours,
## some with none; a village lives by its place.

var content: ContentRegistry


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())


func _home_plan(g: SurfaceGenerator) -> Dictionary:
	return g.settlements.home_plan()


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
	for bad: Dictionary in [{"houses": [3]}, {"cluster_chance": 2}, {"villages": [3, 1]}, {"ways": [{"id": "x", "near": "moon"}]},
			{"ways": [{"id": "x", "buildings": {"castle": {"weight": 2}}}]}, {"wall": "base:grass"}, {"buildings": []},
			{"buildings": [{"size": [2, 2], "dweller": "x"}]}, {"buildings": [{"size": [5, 4]}]},
			{"buildings": [{"size": [4, 4], "dweller": "x", "furniture": ["base:bed", "base:chest", "base:forge"]}]}]:
		var defs: Array = content.defs.values().filter(func(d: Dictionary) -> bool: return d.get("kind") != "settlement")
		defs.append(good.merged(bad, true))
		check(not ContentRegistry.from_defs(defs).errors.is_empty(), "refused: %s" % str(bad))


## Villages are met often: within 1000 cells of the spawn, a good many in
## every world, in clusters.
func test_villages_are_met_often() -> void:
	for seed_value in [1, 7, 12345]:
		var g := SurfaceGenerator.new(seed_value, content)
		var n := g.settlements.plans_near(Vector2i.ZERO, 1000).size()
		check(n >= 6, "seed %d: %d villages within 1000 cells" % [seed_value, n])


## A cluster's villages are all joined; clusters are joined with their
## neighbours by chance — some are, some are not; a road runs on dry land
## or fords and short bridges, never through deep water or rock, and is
## dirt on the ground.
func test_clusters_are_joined_and_some_clusters_with_each_other() -> void:
	var g := SurfaceGenerator.new(12345, content)
	var s := g.settlements
	var clusters := 0
	var links := 0
	var apart := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var mine := s.villages(0, dx, dy)
			if mine.is_empty():
				continue
			clusters += 1
			var roads := s.roads_of(0, dx, dy)
			var here := "@%d,%d#" % [dx, dy]
			var inner := roads.filter(func(r: Dictionary) -> bool: return String(r["from"]).contains(here) and String(r["to"]).contains(here))
			check(inner.size() >= mine.size() - 1 - 1, "district %d,%d: its %d villages joined by %d roads" % [dx, dy, mine.size(), inner.size()])
			for dir in 2:
				if s.villages(0, dx + (1 - dir), dy + dir).is_empty():
					continue
				var other := "@%d,%d#" % [dx + (1 - dir), dy + dir]
				if roads.any(func(r: Dictionary) -> bool: return String(r["to"]).contains(other)):
					links += 1
				else:
					apart += 1
			for r: Dictionary in roads:
				for at: Vector2i in r["path"]:
					var land := String(g.land_at(at.x, at.y)["what"])
					if not check(land != "deep" and land != "rock", "road %s through %s at %s" % [r["id"], land, at]):
						return
	check(clusters >= 4, "clusters round spawn: %d" % clusters)
	check(links + apart >= 2, "neighbouring clusters: %d joined, %d not" % [links, apart])
	# One road on the ground: dirt where it runs.
	var road: Dictionary = s.roads_of(0, 0, 0)[0] if not s.roads_of(0, 0, 0).is_empty() else {}
	if not check(not road.is_empty(), "a road from the home cluster"):
		return
	var path: Array = road["path"]
	var some: Vector2i = path[path.size() / 2]
	var k := Vector2i(floori(some.x / 32.0), floori(some.y / 32.0))
	var ground := g.generate(k.x, k.y).get_cell("ground", some.x - k.x * 32, some.y - k.y * 32)
	check(ground in ["base:dirt", "base:bridge"], "the road on the ground: %s" % ground)


## Across many districts: links one way or another, so roads lead out of a
## cluster into land not yet seen — and some clusters stand alone.
func test_some_clusters_stand_alone_some_lead_on() -> void:
	var g := SurfaceGenerator.new(7, content)
	var s := g.settlements
	var alone := 0
	var linked := 0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if s.villages(0, dx, dy).is_empty():
				continue
			var out := false
			for r: Dictionary in s.roads_of(0, dx, dy):
				out = out or not String(r["to"]).contains("@%d,%d#" % [dx, dy])
			for o: Vector2i in [Vector2i(-1, 0), Vector2i(0, -1)]:
				for r: Dictionary in s.roads_of(0, dx + o.x, dy + o.y):
					out = out or String(r["to"]).contains("@%d,%d#" % [dx, dy])
			if out:
				linked += 1
			else:
				alone += 1
	check(linked >= 2, "clusters with roads out: %d" % linked)
	check(alone >= 1, "clusters alone: %d" % alone)


## A village lives by its place: one by the water fishes (more fishers),
## one by the mountains mines (smiths) — the place is checked again here.
func test_a_village_lives_by_its_place() -> void:
	var seen := {}
	for seed_value in [1, 2, 7]:
		var g := SurfaceGenerator.new(seed_value, content)
		for p: Dictionary in g.settlements.plans_near(Vector2i.ZERO, 1500):
			var way := String(p["way"])
			seen[way] = int(seen.get(way, 0)) + 1
			if way == "fishing":
				var wet := 0
				for i in 8:
					for r: float in [24.0, 48.0]:
						var at: Vector2i = p["centre"] + Vector2i(Vector2.from_angle(i * TAU / 8.0) * r)
						wet += 1 if g.is_wet(at.x, at.y) else 0
				check(wet > 0, "%s fishes by the water" % p["id"])
			var trades := (p["homes"] as Array).map(func(h: Dictionary) -> String: return String(h["dweller"]))
			if way == "fishing" and trades.size() >= 5:
				check(trades.count("base:fisher") >= 1, "%s has a fisher: %s" % [p["id"], trades])
	check(seen.size() >= 3, "ways of life met: %s" % seen)


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
