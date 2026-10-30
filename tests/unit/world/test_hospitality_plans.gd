extends TestCase

func test_lodging_content_has_three_distinct_layouts_and_existing_food() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var generator := SurfaceGenerator.new(431, content)
	var inns := generator.settlements.inns
	eq(inns.templates.size(), 3)
	var rooms := {}
	for template: Dictionary in inns.templates:
		var plan := inns._layout("layout-" + String(template["id"]), template, Vector2i(3, 3), "village")
		check(plan["seats"].size() >= 2, "tables have places for visitors")
		check(plan["beds"].any(func(b: Dictionary) -> bool: return b["kind"] == "shared"), "shared sleeping places")
		check(plan["beds"].any(func(b: Dictionary) -> bool: return b["kind"] == "private"), "private rooms")
		rooms[plan["beds"].size()] = true
		var hall := _room(plan["cells"], plan["seats"][0], content)
		for at: Vector2i in plan["cells"]:
			if content.get_def(String(plan["cells"][at].get("structure", ""))).get("bed", false):
				check(not hall.has(at), "even the owner's bed is behind walls and a door, outside the dining hall")
		for bed: Dictionary in plan["beds"]:
			var cells: Dictionary = plan["cells"] if bed["z"] == 0 else plan["upper"]
			var region := _room(cells, Vector2i(bed["x"], bed["y"]), content)
			var neighbours := []
			for cell: Vector2i in region:
				for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
					neighbours.append(cell + d)
			check(neighbours.any(func(at: Vector2i) -> bool: return content.get_def(String(cells.get(at, {}).get("structure", ""))).get("openable", false)), "each bedroom has an actual door")
			if bed["kind"] == "private":
				eq(plan["beds"].filter(func(b: Dictionary) -> bool: return b["z"] == bed["z"] and region.has(Vector2i(b["x"], b["y"]))).size(), 1, "a private room contains only its own guest bed")
		if template["site"] == "inn":
			check(not plan["upper"].is_empty(), "roadside rooms upstairs")
	check(rooms.size() >= 3, "different capacities, not one repeated floorplan")
	for meal: Dictionary in inns.services["menu"]:
		check(not content.get_def(String(meal["item"])).get("food", {}).is_empty(), "reuse food effects")

func _room(cells: Dictionary, start: Vector2i, content: ContentRegistry) -> Dictionary:
	var seen := {start: true}
	var queue := [start]
	while not queue.is_empty():
		var at: Vector2i = queue.pop_back()
		for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next := at + d
			if seen.has(next) or not cells.has(next):
				continue
			var part := String(cells[next].get("structure", ""))
			if part != "" and (content.get_def(part).get("solid", true) or content.get_def(part).get("openable", false)):
				continue
			seen[next] = true
			queue.append(next)
	return seen

func test_public_houses_are_deterministic_clear_of_roads_and_fit_one_chunk() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var a := SurfaceGenerator.new(431, content)
	var b := SurfaceGenerator.new(431, content)
	var district := a.settlements._district_of(0, a.settlements.home_plan()["centre"])
	var plans := a.settlements.inns.of_cluster(0, district.x, district.y)
	check(not plans.is_empty(), "the starting cluster has public life")
	eq(plans, b.settlements.inns.of_cluster(0, district.x, district.y), "same seed, same plans")
	for plan: Dictionary in plans:
		var rect: Rect2i = plan["rect"]
		eq(Vector2i(rect.position.x >> 5, rect.position.y >> 5), Vector2i((rect.end.x - 1) >> 5, (rect.end.y - 1) >> 5), "no half-building in an old neighbour chunk")
		for road: Dictionary in a.settlements.roads_of(0, district.x, district.y):
			check(not road["path"].any(func(p: Vector2i) -> bool: return rect.has_point(p)), "the road stays open")
			for cell: Vector2i in road["cells"]:
				check(not plan["cells"].has(cell), "access paths preserve the original road and bridges")
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				check(not a.is_unfit(x, y), "dry passable building site")
	# Request chunks in reverse order: planning and road overlays must not depend on visits.
	var chunks := {}
	for plan: Dictionary in plans:
		var cell: Vector2i = plan["host"]
		var key := Vector2i(cell.x >> 5, cell.y >> 5)
		chunks[key] = ChunkCodec.encode(a.generate(key.x, key.y))
	var keys: Array = chunks.keys()
	keys.reverse()
	for key: Vector2i in keys:
		eq(ChunkCodec.encode(b.generate(key.x, key.y)), chunks[key], "generation order does not change chunk bytes")
