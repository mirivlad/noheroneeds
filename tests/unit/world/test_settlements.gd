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
		var occupied: Dictionary = h["architecture"]["occupied"]
		for local: Vector2i in occupied:
			var at := r.position + local
			if SettlementArchitecture._edge(occupied, local):
				check(content.get_def(cell.call(at, "structure")).get("role", "") in ["wall", "window", "door"], "a real wall around the footprint at %s" % at)
			else:
				check(cell.call(at, "roof") != "" or cell.call(at, "ceiling") != "" or cell.call(at, "structure") == "base:wood_stairs", "every indoor cell has a roof, ceiling or stair opening at %s" % at)
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


func test_square_and_parking_are_part_of_the_generated_plan() -> void:
	var g := SurfaceGenerator.new(12345, content)
	var p := _home_plan(g)
	var square: Rect2i = p["square"]
	var cells: Dictionary = p["cells"]
	check(square.has_point(p["fire"]), "the fire is on the public ground")
	check((p["market_sites"] as Array).size() > 0, "the plan reserves space for a future market")
	for site: Rect2i in p["market_sites"]:
		check(square.encloses(site) and not site.has_point(p["fire"]), "the market space is on the square and away from the fire")
		for y in range(site.position.y, site.end.y):
			for x in range(site.position.x, site.end.x):
				var at := Vector2i(x, y)
				eq(String((cells[at] as Dictionary).get("structure", "")), "", "the future market is not obstructed")
	eq((p["parking"] as Array).size(), 3, "two parking places and a reserve are planned")
	for at: Vector2i in p["parking"]:
		check((p["parking_yard"] as Rect2i).has_point(at) or (p["parking_reserve"] as Rect2i).has_point(at), "the parking candidate is in a planned yard")
		eq(String((cells[at] as Dictionary).get("structure", "")), "", "the parking cell is clear")
		check(at.distance_to(p["fire"] as Vector2i) > 5, "the parking cell is away from the fire")
	var chunks := {}
	for y in range(square.position.y, square.end.y):
		for x in range(square.position.x, square.end.x):
			var at := Vector2i(x, y)
			if not cells.has(at) or not (cells[at] as Dictionary).has("ground"):
				continue
			var key := Vector2i(at.x >> 5, at.y >> 5)
			if not chunks.has(key):
				chunks[key] = g.generate(key.x, key.y)
			var chunk: Chunk = chunks[key]
			eq(chunk.get_cell("ground", posmod(at.x, 32), posmod(at.y, 32)), String(p["road"]), "the square is materialized as road ground")
	var start: Vector2i = p["ends"][0]
	var reached := {start: true}
	var queue: Array[Vector2i] = [start]
	var i := 0
	while i < queue.size():
		var at := queue[i]
		i += 1
		for direction: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next := at + direction
			if reached.has(next) or not cells.has(next):
				continue
			var spec: Dictionary = cells[next]
			if spec.get("ground", "") != p["road"] or spec.get("structure", "") != "":
				continue
			reached[next] = true
			queue.append(next)
	for home: Dictionary in p["homes"]:
		check(reached.has((home["door"] as Vector2i) + Vector2i.DOWN), "each doorstep joins the square")
	for at: Vector2i in p["parking"]:
		check(reached.has(at), "every parking place joins the square and streets")


func test_settlement_plan_and_player_changes_survive_reopening() -> void:
	var path := tmp_dir().path_join("settlement.db")
	var world := ServerWorld.open(path, content, {"seed": 12345})
	if not check(world != null, "a new world opens"):
		return
	var plan := world.generator.settlements.home_plan()
	var cells: Dictionary = plan["cells"]
	var samples: Array = [plan["fire"], plan["parking"][0], plan["parking"][2]]
	for home: Dictionary in plan["homes"]:
		for local: Vector2i in home["architecture"]["occupied"]:
			samples.append((home["rect"] as Rect2i).position + local)
	var roof_cell := Settlements.NONE
	for at: Vector2i in samples:
		var chunk := world.chunk("surface", at.x >> 5, at.y >> 5)
		var spec: Dictionary = cells[at]
		for layer: String in ["ground", "structure", "roof"]:
			if spec.has(layer):
				eq(chunk.get_cell(layer, at.x & 31, at.y & 31), String(spec[layer]), "generated %s matches its plan at %s" % [layer, at])
		if spec.get("roof", "") != "":
			roof_cell = at
		if spec.has("props"):
			eq(chunk.get_props(at.x & 31, at.y & 31), spec["props"], "architecture parameters match the materialized cell")
	check(roof_cell != Settlements.NONE, "a generated roof can be edited")
	var roof_chunk := world.chunk("surface", roof_cell.x >> 5, roof_cell.y >> 5)
	roof_chunk.set_cell("roof", roof_cell.x & 31, roof_cell.y & 31, "")
	world._changed(ServerWorld.chunk_key("surface", roof_cell.x >> 5, roof_cell.y >> 5))
	var edited: Vector2i = plan["parking"][0]
	var changed := world.chunk("surface", edited.x >> 5, edited.y >> 5)
	changed.set_cell("structure", edited.x & 31, edited.y & 31, "base:wood_fence")
	world._changed(ServerWorld.chunk_key("surface", edited.x >> 5, edited.y >> 5))
	world.close()
	world = ServerWorld.open(path, content)
	if not check(world != null, "the same world reopens"):
		return
	var restored := world.generator.settlements.plan_by_id(String(plan["id"]))
	eq(restored["cells"], cells, "the reconstructed plan is stable")
	eq(restored["parking"], plan["parking"], "all parking locations are stable")
	eq(world.part_at("surface", edited.x, edited.y), "base:wood_fence", "a player change in a generated chunk survives")
	eq(world._part_at("surface", roof_cell.x, roof_cell.y, "roof"), "", "a removed roof stays removed after reopening")
	world.close()


func test_malformed_settlements_are_content_errors() -> void:
	var good: Dictionary = content.get_def("base:village").duplicate(true)
	good["id"] = "test:v"
	for bad: Dictionary in [{"houses": [3]}, {"cluster_chance": 2}, {"villages": [3, 1]}, {"tradition": "moon"}, {"ways": [{"id": "x", "near": "moon"}]},
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
					var here_land := g.land_at(at.x, at.y)
					var land := String(here_land["what"])
					# a cliff is cut through: the road is a pass (ADR-0061); crags are gone round
					var crag := land == "rock" and not g.is_cliff(at.x, at.y, float(here_land["height"]))
					if not check(land != "deep" and not crag, "road %s through %s at %s" % [r["id"], land, at]):
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


func test_settlement_scales_have_distinct_housing_and_public_buildings() -> void:
	var settlements := Settlements.new(431, content, func(_x: int, _y: int) -> bool: return false, 8)
	var seen := {}
	var definition := content.get_def("base:village")
	for index in 24:
		var layout := settlements._layout(0, 10, index, definition, "scale-%d" % index)
		var plan := settlements._place(layout, Vector2i(300, 300), "scale-%d" % index, definition)
		check(Rect2i(Vector2i(300, 300) - Vector2i.ONE * Settlements.REACH, Vector2i.ONE * Settlements.REACH * 2).encloses(plan["bounds"]), "chunk discovery covers the entire town footprint")
		var scale := String(plan["scale"])
		seen[scale] = true
		var count := (plan["homes"] as Array).size()
		if scale == "hamlet":
			check(count >= 2 and count <= 3, "a hamlet is a small group of homes")
		elif scale == "trading_town":
			check(count >= 8 and count <= 12, "a trading town has more housing")
		else:
			check(count >= 4 and count <= 7, "a village is the intermediate scale")
		for building: Dictionary in plan["buildings"]:
			var door: Vector2i = building["door"]
			check(not content.get_def(String(plan["cells"][door + Vector2i.DOWN].get("structure", ""))).get("solid", false), "each public building also opens onto a clear street")
		var ids := (plan["buildings"] as Array).map(func(b: Dictionary) -> String: return String(b["building_id"]).get_slice(":", 0))
		check(ids.has("barn"), "even a hamlet has an actual barn")
		if scale == "trading_town":
			check(ids.has("warehouse") and ids.has("guardhouse"), "a town has additional civic buildings")
		elif scale == "village":
			check(ids.has("stable") and ids.has("workshop") and ids.has("elder") and ids.has("shrine"), "a village has household and civic spaces")
	eq(seen.size(), 3, "all three scales are generated")
