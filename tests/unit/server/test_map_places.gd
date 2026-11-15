extends TestCase

class NoMapGeneration extends Settlements:
	var map_searches := 0
	func plans_near(_at: Vector2i, _radius: int) -> Array:
		map_searches += 1
		return []

func test_map_request_does_not_plan_unexplored_districts() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := ServerWorld.open(tmp_dir().path_join("map.db"), content, {"seed": 4})
	var plans := NoMapGeneration.new(4, content, func(_x: int, _y: int) -> bool: return false, 8)
	plans._kinds.clear()
	world.generator.settlements = plans
	world.present["map-reader"] = {"pos": Vector2i.ZERO, "location": "surface"}
	world._places("map-reader")
	eq(plans.map_searches, 0, "map labels must not start procedural settlement generation")
	world.present.clear()
	world.close()

func _fire_chunk() -> Chunk:
	var c := Chunk.new()
	c.set_cell("ground", 2, 3, "base:dirt")
	c.set_cell("structure", 2, 3, "base:campfire")
	c.set_props(2, 3, {"village": "base:village@0,0#0"})
	return c

func test_seen_place_names_survive_reopening_and_stay_private() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("known.db")
	var world := ServerWorld.open(path, content, {"seed": 4})
	world._remember_map_chunk(2, -1, _fire_chunk())
	world.present["reader"] = {"pos": Vector2i.ZERO, "location": "surface"}
	world.present["other"] = {"pos": Vector2i.ZERO, "location": "surface"}
	world.explore("reader", "surface", 2, -1)
	var expected := [{"name": world.chronicles.village_name("base:village@0,0#0"), "x": 66, "y": -29}]
	eq(world._places("reader").places, expected, "actual fire position and seeded name")
	eq(world._places("other").places, [], "other players' discoveries are not disclosed")
	world.present.clear()
	world.close()
	world = ServerWorld.open(path, content)
	world.generator = null
	world.present["reader"] = {"pos": Vector2i.ZERO, "location": "surface"}
	eq(world._places("reader").places, expected, "saved labels need no generator after reopening")
	world.present.clear()
	world.close()

func test_stored_tiles_refill_missing_label_cache_without_loading_the_world() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("old-cache.db")
	var world := ServerWorld.open(path, content, {"seed": 4})
	var key := ServerWorld.chunk_key("surface", 2, -1)
	world._chunks[key] = _fire_chunk()
	world.mark_chunk_dirty("surface", 2, -1)
	world.explore("reader", "surface", 2, -1)
	world.close()
	world = ServerWorld.open(path, content)
	world.generator = null
	world.present["reader"] = {"pos": Vector2i.ZERO, "location": "surface"}
	eq(world._places("reader").places, [], "the old chunk has no label index yet")
	var loads := world.sync_loads
	check(not world.map_tile("surface", 2, -1).is_empty(), "the old stored tile arrives")
	eq(world._places("reader").places.size(), 1, "labels refill from the stored fire's properties")
	eq(world.sync_loads, loads, "no simulation chunks or creatures are loaded")
	check(not world._chunks.has(key), "the old chunk stays outside the active world")
	world.present.clear()
	world.close()

func test_public_house_label_matches_its_real_door_and_closed_state() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := ServerWorld.open(tmp_dir().path_join("inn.db"), content, {"seed": 4})
	var inns := world.generator.settlements.inns
	var template: Dictionary = inns.templates.filter(func(t: Dictionary) -> bool: return t.site == "inn")[0]
	var plan := inns._layout("inn@0,0,0", template, Vector2i(5, 5), "base:village@0,0#0")
	var c := Chunk.new()
	c.meta["hospitality"] = plan.id
	for at: Vector2i in plan.cells:
		if at.x < 0 or at.y < 0 or at.x >= Chunk.SIZE or at.y >= Chunk.SIZE: continue
		var cell: Dictionary = plan.cells[at]
		c.set_cell("structure", at.x, at.y, cell.get("structure", ""))
		c.set_props(at.x, at.y, cell.get("props", {}))
	world._remember_map_chunk(0, 0, c)
	world.explore("reader", "surface", 0, 0)
	world.present["reader"] = {"pos": Vector2i.ZERO, "location": "surface"}
	var expected := {"name": "Постоялый двор «%s»" % plan.name, "x": plan.door.x, "y": plan.door.y, "kind": "inn"}
	eq(world._places("reader").places, [expected], "same title and door as the generated public house")
	world.hospitality.state(plan.id)["closed"] = true
	expected.name += " (закрыто)"
	eq(world._places("reader").places, [expected], "a closed house is labelled without regenerating its plan")
	world.present.clear()
	world.close()
