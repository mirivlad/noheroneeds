extends "res://tools/experiment_3d/check_interior_cutaway.gd"
## Run only against a separate disposable profile: this fixture adds a real
## third floor to the inn, after the ordinary paired captures are complete.

func shot(name: String, rect: Rect2i, angle: float) -> void:
	await super.shot(name, rect, angle)
	if name == "outside-restored":
		await check_stack(rect)

func check_stack(rect: Rect2i) -> void:
	var settlements := world.generator.settlements
	var district := settlements._district_of(0, settlements.home_plan()["centre"])
	var plans := settlements.inns.of_cluster(0, district.x, district.y).filter(func(p: Dictionary) -> bool: return p["site"] == "inn")
	var plan: Dictionary = plans[0]
	var lower := world.levels.level(plan["id"], 1)
	var top := world.levels.level(plan["id"], 2)
	verify(top == "", "separate stack fixture starts without the extra floor")
	if top != "": return
	top = world.levels.create_level(plan["id"], 2)
	var touched := {}
	for cell: Vector2i in plan["upper"]:
		var source := world.chunk(lower, cell.x >> 5, cell.y >> 5)
		var upper := world.chunk(top, cell.x >> 5, cell.y >> 5)
		upper.meta["building_z"] = 2
		for layer: String in ["ground", "cover", "structure", "roof"]:
			var value := source.get_cell(layer, cell.x & 31, cell.y & 31)
			if layer == "ground" and value == "": value = "base:wood_floor"
			upper.set_cell(layer, cell.x & 31, cell.y & 31, value)
		upper.set_props(cell.x & 31, cell.y & 31, source.get_props(cell.x & 31, cell.y & 31).duplicate(true))
		source.set_cell("roof", cell.x & 31, cell.y & 31, "")
		source.set_cell("ceiling", cell.x & 31, cell.y & 31, "base:wood_ceiling")
		touched[ServerWorld.chunk_key(lower, cell.x >> 5, cell.y >> 5)] = true
		touched[ServerWorld.chunk_key(top, cell.x >> 5, cell.y >> 5)] = true
	var bed: Dictionary = plan["beds"][0]
	var stairs := Vector2i(int(bed["x"]), int(bed["y"])) + Vector2i(0, 2)
	var landing := stairs + Vector2i.DOWN
	var source := world.chunk(lower, stairs.x >> 5, stairs.y >> 5)
	source.set_cell("structure", stairs.x & 31, stairs.y & 31, "base:wood_stairs")
	var props := source.get_props(stairs.x & 31, stairs.y & 31).duplicate(true)
	props["arrive"] = [landing.x, landing.y]
	source.set_props(stairs.x & 31, stairs.y & 31, props)
	var upper := world.chunk(top, stairs.x >> 5, stairs.y >> 5)
	upper.set_cell("ground", stairs.x & 31, stairs.y & 31, "")
	upper.set_cell("structure", stairs.x & 31, stairs.y & 31, "")
	props = upper.get_props(stairs.x & 31, stairs.y & 31).duplicate(true)
	props["stairs_down"] = true
	upper.set_props(stairs.x & 31, stairs.y & 31, props)
	for key: String in touched: world._changed(key)
	var ground_stair := Vector2i.MAX
	for cell: Vector2i in plan["cells"]:
		if plan["cells"][cell].get("structure", "") == "base:wood_stairs": ground_stair = cell
	await move_to(ground_stair + Vector2i.DOWN)
	var result := await request({"type": "climb", "location": "surface", "x": ground_stair.x, "y": ground_stair.y, "dir": "up"})
	verify(result.get("ok", false), "enter the stack through the original real stairs")
	await move_to(stairs + Vector2i.UP)
	result = await request({"type": "climb", "location": lower, "x": stairs.x, "y": stairs.y, "dir": "up"})
	verify(result.get("ok", false), "climb the fixture's real stair to the third floor")
	if not result.get("ok", false): return
	await move_to(landing)
	await super.shot("third-se", rect, -.6)
	await super.shot("third-nw", rect, .6 + PI / 2)
	verify(g.client.z == 2, "character is on the actual third floor")
	var received := g.client.chunk_at(lower, landing.x, landing.y)
	verify(received != null and received.meta.get("exterior", false), "middle floor arrives as architecture only")
	verify(g.client.cell_at(lower, Vector2i(int(bed["x"]), int(bed["y"])), "structure") == "", "middle floor bed remains private")
	verify(not view._part_hidden(landing, "cover", lower), "the middle floor ceiling is kept beneath the current floor")
	verify(view._part_hidden(landing, "cover", top), "the current roof is hidden")
	var found_lower := false
	for key: String in view._geometry:
		if key.get_slice("|", 0) == lower and (view._geometry[key] as Node3D).visible: found_lower = true
	verify(found_lower, "middle floor is actually drawn below the current floor")
	var found_street := false
	for key: String in view._geometry:
		if key.get_slice("|", 0) == "surface" and (view._geometry[key] as Node3D).visible: found_street = true
	verify(found_street, "street terrain is actually drawn below both upper floors")
