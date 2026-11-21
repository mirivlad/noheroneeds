class_name SettlementTerrainLayout
extends RefCounted
## Fit parcels separately, then join their entrances with three-cell streets.
## The search stays inside the settlement's existing discovery reach.

const STEP := 4
const RADIUS := 140
const ROW_WORDS := (RADIUS * 2 + 33) / 32
var _land: Callable
var _cache := {}
var _grid := AStarGrid2D.new()
var _nodes: Array[Vector2i] = []
var _plots: Array[Rect2i] = []
var _streets: Array[Rect2i] = []
var _root := Vector2i.ZERO
var _centre := Vector2i.ZERO
var _cancel: Callable
var _bounds: Rect2i
var _reserved := PackedInt64Array()
var _dry_rows := PackedInt64Array()
var _wet_rows := PackedInt64Array()


static func make(chosen: Array, fields: Array, pen: Dictionary, land: Callable, centre: Vector2i, seed_value: int, cancel := Callable()) -> Dictionary:
	var planner := SettlementTerrainLayout.new()
	planner._land = land
	planner._centre = centre
	planner._cancel = cancel
	return planner._make(chosen, fields, pen, seed_value)


func _sample(at: Vector2i) -> Dictionary:
	if not _cache.has(at): _cache[at] = _land.call(at.x, at.y)
	return _cache[at]


func _walkable(at: Vector2i) -> bool:
	var sample := _sample(at)
	return sample.what == "land" or (sample.what == "rock" and sample.get("cliff", false))


## A bit represents a cell in a 32-cell row. Search the same candidate
## sites in the same order; a tested cell need not sample relief twice.
func _row_mask(first: int, end: int, word: int) -> int:
	return ((1 << mini(32, end - word * 32)) - 1) ^ ((1 << maxi(0, first - word * 32)) - 1)


func _reserve(rect: Rect2i) -> void:
	var clipped := _bounds.intersection(rect)
	if not clipped.has_area(): return
	var first := clipped.position - _bounds.position + Vector2i.ONE
	var end := first + clipped.size
	for y in range(first.y, end.y):
		for word in range(first.x >> 5, ((end.x - 1) >> 5) + 1):
			_reserved[y * ROW_WORDS + word] |= _row_mask(first.x, end.x, word)


func _clear(rect: Rect2i) -> bool:
	if _cancelled() or not _bounds.encloses(rect): return false
	var first := rect.position - _bounds.position + Vector2i.ONE
	var end := first + rect.size
	for y in range(first.y, end.y):
		for word in range(first.x >> 5, ((end.x - 1) >> 5) + 1):
			var slot := y * ROW_WORDS + word
			if _reserved[slot] & _row_mask(first.x, end.x, word) != 0: return false
	# Reject quickly before checking for narrow streams across the whole site.
	for at: Vector2i in [rect.position, rect.end - Vector2i.ONE, Vector2i(rect.position.x, rect.end.y - 1), Vector2i(rect.end.x - 1, rect.position.y), rect.get_center()]:
		if _sample(at).what != "land": return false
	for y in range(first.y - 1, end.y + 1):
		for word in range((first.x - 1) >> 5, (end.x >> 5) + 1):
			var slot := y * ROW_WORDS + word
			var mask := _row_mask(first.x - 1, end.x + 1, word)
			if _wet_rows[slot] & mask != 0: return false
			var unseen := mask & ~_dry_rows[slot]
			if unseen == 0: continue
			for x in range(maxi(first.x - 1, word * 32), mini(end.x + 1, (word + 1) * 32)):
				var bit := 1 << (x & 31)
				if unseen & bit == 0: continue
				if _sample(_bounds.position + Vector2i(x - 1, y - 1)).what != "land":
					_wet_rows[slot] |= bit
					return false
				_dry_rows[slot] |= bit
	return true


func _corridor(at: Vector2i) -> bool:
	for y in range(at.y - 1, at.y + 2):
		for x in range(at.x - 1, at.x + 2):
			if not _walkable(Vector2i(x, y)): return false
	return true


func _prepare(seed_value: int) -> void:
	var first := Vector2i(floori(float(_centre.x - RADIUS) / STEP), floori(float(_centre.y - RADIUS) / STEP))
	_grid.region = Rect2i(first, Vector2i(RADIUS * 2 / STEP + 1, RADIUS * 2 / STEP + 1))
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_grid.update()
	var candidates := []
	for y in range(first.y, _grid.region.end.y):
		if _cancelled(): return
		for x in range(first.x, _grid.region.end.x):
			var id := Vector2i(x, y)
			var at := id * STEP
			# The full width is validated on the chosen paths below; avoid
			# sampling nine cells at every unused point of the search region.
			var sample := _sample(at)
			var dry: bool = sample.what == "land"
			var clear: bool = dry or (sample.what == "rock" and sample.get("cliff", false))
			_grid.set_point_solid(id, not clear)
			if clear:
				_grid.set_point_weight_scale(id, 3.0 if dry else 8.0)
				candidates.append({"id": id, "score": Vector2(at - _centre).length() + float(absi(hash([seed_value, id])) % 1000) / 1000.0})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score < b.score)
	for candidate: Dictionary in candidates: _nodes.append(candidate.id)


func _mask(rect: Rect2i) -> Array[Vector2i]:
	var changed: Array[Vector2i] = []
	var grown := rect.grow(2)
	for y in range(floori(float(grown.position.y) / STEP), ceili(float(grown.end.y) / STEP)):
		for x in range(floori(float(grown.position.x) / STEP), ceili(float(grown.end.x) / STEP)):
			var id := Vector2i(x, y)
			if _grid.region.has_point(id) and grown.has_point(id * STEP) and not _grid.is_point_solid(id):
				_grid.set_point_solid(id)
				changed.append(id)
	return changed


func _path(gate: Vector2i, plot: Rect2i) -> Array[Vector2i]:
	var masked: Array[Vector2i] = []
	if plot.has_area(): masked = _mask(plot)
	var result: Array[Vector2i] = []
	var start := gate / STEP
	for attempt in 8:
		if _cancelled(): break
		if _grid.is_point_solid(start): break
		var ids := _grid.get_id_path(start, _root / STEP)
		if ids.is_empty(): break
		var path: Array[Vector2i] = [gate]
		for i in range(1, ids.size()):
			var end: Vector2i = ids[i] * STEP
			var at := path[-1]
			while at != end:
				at += Vector2i(signi(end.x - at.x), signi(end.y - at.y))
				path.append(at)
		var bad := Vector2i(1 << 30, 0)
		for at: Vector2i in path:
			if not _corridor(at):
				bad = Vector2i(roundi(float(at.x) / STEP), roundi(float(at.y) / STEP))
				break
		if bad.x == 1 << 30:
			result = path
			break
		if bad == start or bad == _root / STEP: break
		_grid.set_point_solid(bad)
	for id: Vector2i in masked: _grid.set_point_solid(id, false)
	return result


func _street(path: Array[Vector2i]) -> void:
	if path.is_empty(): return
	var begin := path[0]
	var direction := Vector2i.ZERO
	for i in range(1, path.size()):
		var next := path[i] - path[i - 1]
		if direction != Vector2i.ZERO and next != direction:
			_add_street(Rect2i(begin.min(path[i - 1]) - Vector2i.ONE, (begin - path[i - 1]).abs() + Vector2i(3, 3)))
			begin = path[i - 1]
		direction = next
	_add_street(Rect2i(begin.min(path[-1]) - Vector2i.ONE, (begin - path[-1]).abs() + Vector2i(3, 3)))
	for at: Vector2i in path:
		if posmod(at.x, STEP) == 0 and posmod(at.y, STEP) == 0:
			_grid.set_point_weight_scale(at / STEP, 1.0)


func _add_street(rect: Rect2i) -> void:
	_streets.append(rect)
	_reserve(rect.grow(1))


func _add_plot(rect: Rect2i) -> void:
	_plots.append(rect)
	_reserve(rect.grow(2))


func _rect(size: Vector2i, bottom: bool) -> Rect2i:
	for id: Vector2i in _nodes:
		if _grid.is_point_solid(id): continue
		var gate := id * STEP
		var rect := Rect2i(gate + Vector2i(-size.x / 2, -size.y - 3 if bottom else 3), size)
		if not _clear(rect): continue
		var path := _path(gate, rect)
		if path.is_empty(): continue
		var end := Vector2i(gate.x, rect.end.y - 1 if bottom else rect.position.y)
		var at := gate
		while at != end:
			path.push_front(at)
			at.y += signi(end.y - at.y)
		path.push_front(end)
		_mask(rect)
		_add_plot(rect)
		_street(path)
		return rect
	return Rect2i()


func _building(template: Dictionary, index: int, seed_value: int) -> Dictionary:
	var original: Dictionary = template.architecture
	var turns := absi(hash([seed_value, index])) % 4
	var variants := []
	for direction in 4:
		var design := original.duplicate()
		design.turns = (turns + direction) % 4
		var body := SettlementArchitecture.local_rect(design, Rect2i(Vector2i.ZERO, design.size))
		var plot := body
		if (design.yard as Rect2i).has_area(): plot = plot.merge(SettlementArchitecture.local_rect(design, design.yard))
		variants.append({"design": design, "body": body, "plot": plot,
			"door": SettlementArchitecture.local_cell(design, design.door),
			"outward": ContentRegistry.FACINGS[SettlementArchitecture.facing(design)]})
	for id: Vector2i in _nodes:
		if _grid.is_point_solid(id): continue
		var gate := id * STEP
		for variant: Dictionary in variants:
			var design: Dictionary = variant.design
			var origin: Vector2i = gate - (variant.outward as Vector2i) * 3 - (variant.door as Vector2i)
			var body: Rect2i = variant.body
			body.position += origin
			var plot: Rect2i = variant.plot
			plot.position += origin
			if not _clear(plot): continue
			var path := _path(gate, plot)
			if path.is_empty(): continue
			_mask(plot)
			_add_plot(plot)
			_street(path)
			var built := template.duplicate()
			built.architecture = design
			built.size = [body.size.x, body.size.y]
			return {"template": built, "rect": Rect2i(body.position - _centre, body.size)}
	return {}


func _approaches() -> Array:
	var bounds := Rect2i(_root, Vector2i.ONE)
	for plot: Rect2i in _plots: bounds = bounds.merge(plot)
	for street: Rect2i in _streets: bounds = bounds.merge(street)
	var result := []
	for direction: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var target := bounds.get_center()
		if direction.x != 0: target.x = bounds.position.x - 16 if direction.x < 0 else bounds.end.x + 16
		if direction.y != 0: target.y = bounds.position.y - 16 if direction.y < 0 else bounds.end.y + 16
		var candidates := []
		for id: Vector2i in _nodes:
			if posmod(id.x, 2) != 0 or posmod(id.y, 2) != 0 or _grid.is_point_solid(id): continue
			var at := id * STEP
			if bounds.grow(9).has_point(at): continue
			if (direction.x != 0 and signi(at.x - bounds.get_center().x) != direction.x) or (direction.y != 0 and signi(at.y - bounds.get_center().y) != direction.y): continue
			candidates.append({"at": at, "distance": Vector2(at - target).length_squared()})
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
		for candidate: Dictionary in candidates.slice(0, 8):
			var path := _path(candidate.at, Rect2i())
			if path.is_empty(): continue
			path.reverse()
			var relative: Array[Vector2i] = []
			for at: Vector2i in path: relative.append(at - _centre)
			result.append(relative)
			break
	return result


func _make(chosen: Array, fields: Array, pen: Dictionary, seed_value: int) -> Dictionary:
	_bounds = Rect2i(_centre - Vector2i.ONE * RADIUS, Vector2i.ONE * RADIUS * 2)
	var words := (RADIUS * 2 + 2) * ROW_WORDS
	_reserved.resize(words)
	_dry_rows.resize(words)
	_wet_rows.resize(words)
	_prepare(seed_value)
	if _cancelled(): return {}
	var yard := Rect2i()
	for id: Vector2i in _nodes:
		# Match the inter-village route grid so its first point is in the lane.
		if posmod(id.x, 2) != 0 or posmod(id.y, 2) != 0: continue
		var candidate := Rect2i(id * STEP - Vector2i(12, 13), Vector2i(25, 14))
		if _clear(candidate) and _corridor(id * STEP + Vector2i(0, STEP)):
			yard = candidate
			_root = id * STEP
			break
	if not yard.has_area(): return {}
	_add_plot(yard)
	_mask(yard)
	for id: Vector2i in _nodes:
		var at := id * STEP
		if at.y >= yard.position.y + 11 and at.y <= yard.end.y + 1 and at.x >= yard.position.x + 10 and at.x <= yard.position.x + 14:
			_grid.set_point_solid(id, false)
	_street([_root])
	var square := _rect(Vector2i(10, 10), true)
	if not square.has_area(): return {}
	var reserve := _rect(Vector2i(13, 14), true)
	if not reserve.has_area(): return {}
	var buildings := []
	for index in chosen.size():
		var building := _building(chosen[index], index, seed_value)
		if building.is_empty(): return {}
		buildings.append(building)
	var fitted_fields := []
	for field: Dictionary in fields:
		var rect := _rect(field.rect.size, false)
		if not rect.has_area(): return {}
		var fitted := field.duplicate()
		fitted.rect = Rect2i(rect.position - _centre, rect.size)
		fitted_fields.append(fitted)
	var fitted_pen := pen.duplicate()
	if not pen.is_empty():
		var rect := _rect(pen.rect.size, false)
		if not rect.has_area(): return {}
		fitted_pen.rect = Rect2i(rect.position - _centre, rect.size)
	var streets: Array[Rect2i] = []
	for street: Rect2i in _streets: streets.append(Rect2i(street.position - _centre, street.size))
	return {"buildings": buildings, "streets": streets, "fields": fitted_fields, "pen": fitted_pen,
		"square": Rect2i(square.position - _centre, square.size), "yard": Rect2i(yard.position - _centre, yard.size),
		"reserve": Rect2i(reserve.position - _centre, reserve.size), "root": _root - _centre,
		"approaches": _approaches(), "adaptive": true, "complete": true, "half": RADIUS + 1}


func _cancelled() -> bool:
	return _cancel.is_valid() and _cancel.call()
