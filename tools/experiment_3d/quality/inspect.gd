extends SceneTree
func _initialize() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var land := SurfaceGenerator.new(431, content)
	var plan := land.settlements.home_plan()
	var village: Vector2i = plan["fire"]
	var best := Vector2i.ZERO
	var score := -INF
	var road_count := 0
	var roads := {}
	var shape := TerrainShape3D.new(land)
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			for road: Dictionary in land.settlements.roads_of(0, dx, dy):
				for cell: Vector2i in road.get("cells", {}):
					road_count += 1
					roads[cell] = true
					var h := float(land.land_at(cell.x, cell.y)["height"])
					var range_h := absf(float(land.land_at(cell.x + 16, cell.y)["height"]) - float(land.land_at(cell.x - 16, cell.y)["height"])) + absf(float(land.land_at(cell.x, cell.y + 16)["height"]) - float(land.land_at(cell.x, cell.y - 16)["height"]))
					var value := h + range_h * 3
					if h > .3 and value > score:
						score = value
						best = cell
	var areas := {}
	for name: String in {"village": village, "mountain_road": best}:
		var at: Vector2i = {"village": village, "mountain_road": best}[name]
		var low := INF
		var high := -INF
		var max_edge := 0.0
		var new_low := INF
		var new_high := -INF
		var new_edge := 0.0
		var road_edge := 0.0
		var area_roads := 0
		for y in range(at.y - 24, at.y + 25):
			for x in range(at.x - 24, at.x + 25):
				var h := float(land.land_at(x, y)["height"])
				var c := Vector2i(x,y)
				var height := shape.height(c)
				new_low = minf(new_low,height)
				new_high = maxf(new_high,height)
				var grade := maxf(absf(height-shape.height(c+Vector2i.RIGHT)),absf(height-shape.height(c+Vector2i.DOWN)))
				new_edge = maxf(new_edge,grade)
				if roads.has(c):
					road_edge = maxf(road_edge,grade)
					area_roads += 1
				low = minf(low, h)
				high = maxf(high, h)
				max_edge = maxf(max_edge, absf(h - float(land.land_at(x + 1, y)["height"])))
		areas[name] = {"cell": [at.x, at.y], "height_min": low, "height_max": high, "old_vertical_span": (high - low) * 14, "max_edge_normalized": max_edge, "new_vertical_span":new_high-new_low,"max_new_edge_m":new_edge,"max_road_edge_m":road_edge,"road_cells_in_area":area_roads,"geographic_height": land.geography.sample(Geography.HEIGHT, at.x, at.y)}
	var library := ModelLibrary3D.new()
	var models := {}
	for id: String in ["base:wood_wall", "base:wood_door", "base:wood_window", "base:thatch_roof"]:
		var entry: Dictionary = library.catalog[id]
		var root := (load("res://assets/experiment_3d/" + String(entry["path"])) as PackedScene).instantiate() as Node3D
		var parts: Array = []
		library._collect(root, Transform3D.IDENTITY, parts)
		var bounds: AABB = parts[0][1] * (parts[0][0] as Mesh).get_aabb()
		for part: Array in parts:
			bounds = bounds.merge((part[1] as Transform3D) * (part[0] as Mesh).get_aabb())
		models[id] = {"source_bounds": str(bounds), "catalog_size": entry["size"]}
		root.free()
	var result := {"seed":431,"areas":areas,"road_cells_inspected":road_count,"models":models,"homes":str(plan.get("homes",[]))}
	var out := "/tmp/nhn-3d-quality-audit-final.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
	FileAccess.open(out, FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print(JSON.stringify(result))
	quit()
