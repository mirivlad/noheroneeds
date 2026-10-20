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
