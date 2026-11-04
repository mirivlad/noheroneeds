class_name SettlementArchitecture
extends RefCounted
## Parametric, cell-authoritative houses. One seed belongs to one building,
## independent of chunk order or any other building's random draws.

const TYPES := ["cottage", "longhouse", "hall", "wing", "crosswing", "courtyard"]


static func plan(world_seed: int, village: String, building: String, template: Dictionary, tradition: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	var seed_value := hash([world_seed, village, building, "architecture"])
	rng.seed = seed_value
	var profession := String(template.get("dweller", ""))
	var wealth := maxi(rng.randi_range(0, 2), int(template.get("min_wealth", 0)))
	if profession in ["base:smith", "base:trader"]:
		wealth = maxi(wealth, 1)
	var shape := String(TYPES[rng.randi_range(0, TYPES.size() - 1)])
	if wealth == 0:
		shape = "cottage" if rng.randf() < .65 else "longhouse"
	if tradition == "cold":
		shape = "cottage" if wealth < 2 else "wing"
	if shape == "courtyard" and tradition != "dry":
		shape = "crosswing"
	var w := rng.randi_range(5, 6) + wealth
	var h := rng.randi_range(4, 5) + (1 if wealth == 2 else 0)
	if shape == "longhouse":
		w += 2
		h = 4 + wealth / 2
	elif shape == "hall":
		h += 1
	elif shape == "courtyard":
		w = maxi(w, 9)
	var extension := rng.randi_range(2, 3) if shape in ["wing", "crosswing", "courtyard"] else 0
	if extension > 0:
		h = maxi(h, 5)  # one clear circulation row links all wings
	var main := Rect2i(0, extension, w, h)
	var sections: Array[Rect2i] = [main]
	if extension > 0:
		var wing_width := rng.randi_range(3, mini(4, w - 2))
		var x := 0 if rng.randf() < .5 else w - wing_width
		if shape == "crosswing":
			x = (w - wing_width) / 2
		sections.append(Rect2i(x, 0, wing_width, extension + 2))
		if shape == "courtyard":
			sections.append(Rect2i(w - wing_width if x == 0 else 0, 0, wing_width, extension + 2))
	# Every required workstation must fit; optional decoration may be omitted.
	w = maxi(w, (template.get("furniture", []) as Array).size() + 3)
	main.size.x = w
	sections[0] = main
	var occupied := {}
	for section: Rect2i in sections:
		for y in range(section.position.y, section.end.y):
			for x in range(section.position.x, section.end.x):
				occupied[Vector2i(x, y)] = true
	var door := Vector2i(rng.randi_range(1, w - 2), main.end.y - 1)
	var furnishings: Array = []
	var available: Array[Vector2i] = []
	# Keep the doorway's line and the cells south of workstations clear.
	for x in range(1, w - 1):
		if x != door.x:
			available.append(Vector2i(x, main.position.y + (2 if extension > 0 else 1)))
	if rng.randf() < .5:
		available.reverse()
	var furniture: Array = (template.get("furniture", []) as Array).duplicate()
	if wealth == 2:
		furniture.append("base:inn_table")
		furniture.append("base:inn_chair")
	for item: String in furniture:
		if furnishings.size() >= available.size():
			break
		furnishings.append({"cell": available[furnishings.size()], "id": item})
	var pitch := rng.randf_range(.42, .65)
	if tradition in ["mountain", "cold"]:
		pitch = rng.randf_range(.72, .95)
	elif tradition == "dry":
		pitch = 0.0
	var wall_height: float = 2.0
	var windows := {}
	for at: Vector2i in occupied:
		if at == door or not _edge(occupied, at):
			continue
		var facing := _facing(occupied, at)
		# Corners keep solid structural posts.
		var along := Vector2i.RIGHT if facing in ["n", "s"] else Vector2i.DOWN
		if occupied.has(at - along) and occupied.has(at + along) and rng.randf() < (.12 if tradition == "cold" else .32):
			windows[at] = facing
	var storeys := int(template.get("storeys", 1))
	if profession != "" and wealth > 0 and rng.randf() < .7:
		storeys = 2
	var yard := Rect2i(0, -5, w, 5) if profession != "" and wealth > 0 else Rect2i()
	return {"storeys": storeys, "attic": storeys == 2 and wealth == 1, "yard": yard, "id": building, "seed": seed_value, "shape": shape, "tradition": tradition, "profession": profession,
		"wealth": wealth, "size": Vector2i(w, h + extension), "main": main, "sections": sections,
		"occupied": occupied, "door": door, "furniture": furnishings, "windows": windows,
		"pitch": pitch, "wall_height": wall_height, "roof_axis": rng.randi_range(0, 1),
		"eaves": rng.randf_range(.08, .28), "porch": wealth > 0 or tradition in ["cold", "dry"],
		"porch_width": rng.randi_range(2, 3), "window_scale": .65 if tradition == "cold" else 1.0}


static func cells(design: Dictionary, origin: Vector2i, village: String, materials: Dictionary, registry: ContentRegistry) -> Dictionary:
	var out := {}
	var occupied: Dictionary = design["occupied"]
	var door: Vector2i = design["door"]
	var windows: Dictionary = design["windows"]
	var building_id := village + "|" + String(design["id"])
	var wall_material := "base:stone_wall" if String(design["profession"]) == "base:smith" else String(materials["wall"])
	var roof_sections := []
	for index in (design["sections"] as Array).size():
		var section: Rect2i = design["sections"][index]
		roof_sections.append([section.position.x + origin.x, section.position.y + origin.y, section.size.x, section.size.y,
			int(design["roof_axis"]) if index == 0 else 1 - int(design["roof_axis"])])
	for local: Vector2i in occupied:
		var props := {"village": village, "building": building_id, "building_seed": int(design["seed"]),
			"wall_height": float(design["wall_height"])}
		var spec := {"ground": String(materials["floor"]), "cover": "", "structure": "", "props": props}
		if _edge(occupied, local):
			var part := wall_material
			if local == door:
				part = String(materials["door"])
				props["facing"] = "s"
			elif windows.has(local):
				part = String(materials["window"])
				props["facing"] = windows[local]
				props["window_scale"] = float(design["window_scale"])
			spec["structure"] = part
		else:
			var section: Rect2i = design["main"]
			for candidate: Rect2i in design["sections"]:
				if candidate.has_point(local):
					section = candidate
			var world_section := Rect2i(section.position + origin, section.size)
			spec["roof"] = String(materials["roof"])
			props["roof"] = {"section": [world_section.position.x, world_section.position.y, world_section.size.x, world_section.size.y],
				"sections": roof_sections, "pitch": float(design["pitch"]), "axis": int(design["roof_axis"]), "eaves": float(design["eaves"]),
				"gable": "wood" if wall_material == "base:log_wall" else ("stone" if wall_material == "base:stone_wall" else "plaster")}
		out[local + origin] = spec
	for furniture: Dictionary in design["furniture"]:
		var at: Vector2i = furniture["cell"] + origin
		var item := String(furniture["id"])
		out[at]["structure"] = item
		if registry.get_def(item).has("container"):
			out[at]["props"]["store"] = "%s|%d|%d" % [village, at.x, at.y]
	if design["porch"]:
		# A one-cell cantilevered entrance canopy leaves the street unobstructed.
		var width := int(design["porch_width"])
		var from := origin + door + Vector2i(-1, 1)
		for x in width:
			var at := from + Vector2i(x, 0)
			out[at] = {"ground": String(materials.get("road", "base:dirt")), "cover": "", "structure": "", "roof": String(materials["roof"]),
				"props": {"village": village, "building": building_id, "wall_height": float(design["wall_height"]) - .1,
					"roof": {"sections": [[from.x, from.y, width, 1, 1]], "pitch": .15, "eaves": .15}}}
	if int(design.get("storeys", 1)) > 1:
		var upstairs := _upper_design(design)
		for local: Vector2i in upstairs["occupied"]:
			var spec: Dictionary = out[local + origin]
			spec.erase("roof")
			(spec["props"] as Dictionary).erase("roof")
			spec["ceiling"] = "base:wood_ceiling"
			spec["props"]["ceiling"] = {"building": building_id}
		var stair := _stairs(design) + origin
		out[stair]["structure"] = "base:wood_stairs"
		out[stair].erase("ceiling")
		out[stair]["props"].erase("ceiling")
		out[stair]["props"]["facing"] = "n"
		out[stair]["props"]["arrive"] = [stair.x, stair.y - 1]
	var yard: Rect2i = design.get("yard", Rect2i())
	if yard.has_area():
		for y in range(yard.position.y, yard.end.y):
			for x in range(yard.position.x, yard.end.x):
				var at := Vector2i(x, y) + origin
				var edge := x == yard.position.x or x == yard.end.x - 1 or y == yard.position.y or y == yard.end.y - 1
				var part := "base:wood_fence" if edge else ""
				if x == yard.end.x - 2 and y == yard.position.y:
					part = "base:wood_gate"
				out[at] = {"ground": String(materials.get("road", "base:dirt")), "cover": "", "structure": part,
					"props": {"village": village, "building": building_id + "|yard", "facing": "n"}}
		# A real, independently destructible lean-to, with an accessible chest.
		for y in range(-5, -2):
			for x in 3:
				var at := origin + Vector2i(x, y)
				var part := wall_material if x in [0, 2] or y == -5 else "base:chest"
				if x == 1 and y == -3:
					part = String(materials["door"])
				out[at] = {"ground": String(materials["floor"]), "cover": "", "structure": part,
					"roof": String(materials["roof"]), "props": {"village": village, "building": building_id + "|shed",
						"wall_height": 1.6, "facing": "s", "store": building_id + "|shed",
						"roof": {"sections": [[origin.x, origin.y - 5, 3, 3, 0]], "pitch": .25, "eaves": .1}}}
	return out


static func _stairs(design: Dictionary) -> Vector2i:
	var main: Rect2i = design["main"]
	return Vector2i((design["door"] as Vector2i).x, main.end.y - 2)


static func _upper_design(design: Dictionary) -> Dictionary:
	var upper := design.duplicate(true)
	upper["storeys"] = 1
	upper["porch"] = false
	upper["yard"] = Rect2i()
	upper["door"] = Settlements.NONE
	upper["furniture"] = []
	upper["wall_height"] = 1.6 if design["attic"] else 2.0
	# An attic covers the main volume; a full storey includes the wings.
	if design["attic"]:
		upper["sections"] = [design["main"]]
		upper["occupied"] = {}
		var main: Rect2i = design["main"]
		for y in range(main.position.y, main.end.y):
			for x in range(main.position.x, main.end.x):
				upper["occupied"][Vector2i(x, y)] = true
	return upper


static func upper_cells(design: Dictionary, origin: Vector2i, village: String, materials: Dictionary, registry: ContentRegistry) -> Dictionary:
	if int(design.get("storeys", 1)) < 2:
		return {}
	var upper := _upper_design(design)
	var out := cells(upper, origin, village, materials, registry)
	var stair := _stairs(design) + origin
	out[stair]["ground"] = ""
	out[stair]["props"]["stairs_down"] = true
	var main: Rect2i = design["main"]
	var bed := origin + Vector2i(main.position.x + 1, main.position.y + 1)
	if bed.x == stair.x:
		bed.x = origin.x + main.end.x - 2
	out[bed]["structure"] = "base:bed"
	return out


static func _edge(occupied: Dictionary, at: Vector2i) -> bool:
	for direction: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if not occupied.has(at + direction):
			return true
	return false


static func _facing(occupied: Dictionary, at: Vector2i) -> String:
	for pair: Array in [[Vector2i.UP, "n"], [Vector2i.DOWN, "s"], [Vector2i.LEFT, "w"], [Vector2i.RIGHT, "e"]]:
		if not occupied.has(at + pair[0]):
			return String(pair[1])
	return "s"
