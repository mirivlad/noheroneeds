class_name SettlementLayout
extends RefCounted
## Streets are public cells first; complete building plots are fitted beside
## them. Every entrance has a short, clear walk to its street. No visual-only turn.

static func make(chosen: Array, kind: String, seed_value: int, land: Callable, centre: Vector2i, shore_normal := Vector2.RIGHT) -> Dictionary:
	var span := maxi(80, chosen.size() * 8)
	var arterial := Rect2i(-span * 2 / 3, 0, span, 3)
	var streets: Array[Rect2i] = [arterial]
	var square := Rect2i()
	match kind:
		"square":
			square = Rect2i(-5, -25, 10, 10)
			streets.append_array([Rect2i(-14, -34, 29, 3), Rect2i(-14, -10, 29, 3), Rect2i(-14, -34, 3, 37), Rect2i(12, -34, 3, 37), Rect2i(-1, -20, 3, 23)])
		"crossroads":
			streets.append_array([Rect2i(-20, -42, 3, 78), Rect2i(16, -30, 3, 33)])
		"bend":
			streets.append_array([Rect2i(-35, -23, 3, 26), Rect2i(-35, -23, 37, 3), Rect2i(-1, -43, 3, 23)])
		"shore":
			if absf(shore_normal.x) >= absf(shore_normal.y):
				streets.append(Rect2i(-16, -44, 3, 80))
			else:
				streets.append_array([Rect2i(-50, -25, 88, 3), Rect2i(-42, -25, 3, 28)])
		"terraces":
			streets.append_array([Rect2i(-38, -25, 61, 3), Rect2i(-38, -48, 46, 3), Rect2i(-38, -48, 3, 51), Rect2i(20, -25, 3, 28)])
	var terrain_cache := {}
	var sample_land := land
	if land.is_valid():
		sample_land = func(x: int, y: int) -> Dictionary:
			var at := Vector2i(x, y)
			if not terrain_cache.has(at): terrain_cache[at] = land.call(x, y)
			return terrain_cache[at]
	var buildings := []
	var plots: Array[Rect2i] = []
	var street_usage := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for template: Dictionary in chosen:
		var best := {}
		var score := INF
		for street_index in streets.size():
			var street: Rect2i = streets[street_index]
			var horizontal := street.size.x > street.size.y
			var length := street.size.x if horizontal else street.size.y
			for distance in range(2, length - 2, 2):
				for side: int in [-1, 1]:
					var design: Dictionary = template["architecture"].duplicate()
					design["turns"] = (0 if side < 0 else 2) if horizontal else (3 if side < 0 else 1)
					var door := SettlementArchitecture.local_cell(design, design["door"])
					var step := Vector2i(street.position.x + distance, street.position.y - 2 if side < 0 else street.end.y + 1) if horizontal else Vector2i(street.position.x - 2 if side < 0 else street.end.x + 1, street.position.y + distance)
					var origin := step - door
					var body := SettlementArchitecture.local_rect(design, Rect2i(Vector2i.ZERO, design["size"]))
					body.position += origin
					var plot := body
					var yard: Rect2i = design["yard"]
					if yard.has_area():
						yard = SettlementArchitecture.local_rect(design, yard)
						yard.position += origin
						plot = plot.merge(yard)
					if plots.any(func(p: Rect2i) -> bool: return p.grow(2).intersects(plot)):
						continue
					if Rect2i(-160, 0, 320, 3).grow(1).intersects(plot) or streets.any(func(s: Rect2i) -> bool: return s.grow(1).intersects(plot)) or (square.has_area() and square.grow(2).intersects(plot)):
						continue
					var focus := square.get_center() if kind == "square" else Vector2i.ZERO
					var value := Vector2(step - focus).length() * .03 + rng.randf() * 1.5 + float(street_usage.get(street_index, 0)) * .8
					if street_index == 0 and kind in ["square", "bend", "shore", "terraces"]: value += 1.5
					if value >= score: continue
					var terrain := _terrain_cost(plot, sample_land, centre)
					if terrain == INF: continue
					value += terrain
					if value >= score: continue
					score = value
					var built := template.duplicate()
					built["architecture"] = design
					built["size"] = [body.size.x, body.size.y]
					best = {"template": built, "rect": body, "plot": plot, "street": street_index}
		if best.is_empty():
			# An unsuitable parcel never becomes a house on water or a road.
			continue
		buildings.append(best)
		street_usage[best["street"]] = int(street_usage.get(best["street"], 0)) + 1
		plots.append(best["plot"])
	var bounds := arterial
	for plot: Rect2i in plots: bounds = bounds.merge(plot)
	for street: Rect2i in streets: bounds = bounds.merge(street)
	if not square.has_area(): square = Rect2i(bounds.end.x + 3, -8, 10, 10)
	var yard := Rect2i(maxi(bounds.end.x, square.end.x) + 5, -12, 25, 14)
	# Keep the wagon transit line free across the entire settlement; branches
	# serve houses but are never used to squeeze a cart through a doorway.
	streets[0] = Rect2i(bounds.position.x - 3, 0, yard.end.x - bounds.position.x + 4, 3)
	return {"buildings": buildings, "streets": streets, "square": square, "yard": yard,
		"low": bounds.end.y + 5, "left": bounds.position.x, "half": yard.end.x + 1}


static func _terrain_cost(plot: Rect2i, land: Callable, centre: Vector2i) -> float:
	if not land.is_valid(): return 0.0
	var low := INF
	var high := -INF
	for offset: Vector2i in [plot.position, Vector2i(plot.end.x - 1, plot.position.y), plot.end - Vector2i.ONE, Vector2i(plot.position.x, plot.end.y - 1), plot.get_center()]:
		var at := offset + centre
		var sample: Dictionary = land.call(at.x, at.y)
		if String(sample.get("what", "")) != "land": return INF
		var height := float(sample.get("height", 0.0))
		low = minf(low, height)
		high = maxf(high, height)
	return (high - low) * 30.0
