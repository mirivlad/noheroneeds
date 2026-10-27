class_name TerrainShape3D
extends RefCounted
## Presentation units: 1 cell = 1 metre, LPC human approximately 1.5 m.
## The land stands where the generator says (SurfaceGenerator.metres_at,
## ADR-0061): rolling low land, rugged land in flat levels with cliffs (rock
## cells) between them and passes. A corner stands at the height of the walkable
## cells around it, so a level is flat up to its cliff and the cliff drops sheer.
var land: SurfaceGenerator
## Whether a cell is solid rock now (a cliff or a crag; dug out it is walkable).
var solid: Callable
## How far a cell's ground sinks under the land (a hanging bridge's sag), metres.
var sag: Callable
var heights := {}
var pads := {}
var extra_pads: Array = []
var _cells := {}

func _init(source: SurfaceGenerator, is_solid := Callable()) -> void:
	land = source
	solid = is_solid

## The ground of a cell, metres.
func cell(c: Vector2i) -> float:
	if not _cells.has(c):
		_cells[c] = land.metres_at(c.x, c.y)
	return float(_cells[c]) - (float(sag.call(c)) if sag.is_valid() else 0.0)

## The ground under the middle of a rectangle (a settlement's homes stand level).
func natural(c: Vector2i) -> float:
	return cell(c)

func water(c: Vector2i) -> float:
	var h := float(land.land_at(c.x, c.y)["height"])
	var lake := land.geography.lake_level_at(c.x, c.y)
	if h < Geography.SEA: return 0
	if h < lake: return (lake - Geography.SEA) * SurfaceGenerator.RELIEF_METRES
	# A river runs at its banks' foot: never above the lowest dry cell beside it.
	var bank := INF
	for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if not land.land_at(c.x + d.x, c.y + d.y)["what"] in ["water", "deep", "shallows"]:
			bank = minf(bank, cell(c + d))
	return minf(cell(c), bank) - .12

## The four cells round a corner (the corner is the top left one of cell c).
func _around(c: Vector2i) -> Array[Vector2i]:
	return [c - Vector2i.ONE, c - Vector2i(0, 1), c - Vector2i(1, 0), c]

## The lowest walkable ground at a corner: where a cliff's face reaches down to.
func low(c: Vector2i) -> float:
	var out := INF
	for a: Vector2i in _around(c):
		if not _solid(a):
			out = minf(out, cell(a))
	return out if out != INF else height(c)

func _solid(c: Vector2i) -> bool:
	return solid.is_valid() and bool(solid.call(c))

func height(c: Vector2i) -> float:
	if heights.has(c): return heights[c]
	var sum := 0.0
	var n := 0
	var top := -INF
	for a: Vector2i in _around(c):
		top = maxf(top, cell(a))
		if not _solid(a):
			sum += cell(a)
			n += 1
	var h := sum / n if n > 0 else top
	var chunk := Vector2i(floori(c.x / 32.0), floori(c.y / 32.0))
	if not pads.has(chunk):
		var list := []
		for p: Dictionary in land.settlements.plans_touching(chunk.x, chunk.y):
			for home: Dictionary in p.get("homes", []):
				var rect: Rect2i = home["rect"]
				list.append([Rect2(rect), natural(Vector2i(rect.get_center())) + .04])
		pads[chunk] = list
	for pad: Array in pads[chunk] + extra_pads:
		var r: Rect2 = pad[0]
		var distance := Vector2(c).distance_to(Vector2(c).clamp(r.position, r.end))
		if distance < 2:
			h = lerpf(h, float(pad[1]), 1 - smoothstep(0, 2, distance))
	# A corner shared with water is a shared shoreline, never an abrupt lip.
	var wet := 0
	var level := 0.0
	for d: Vector2i in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.UP, -Vector2i.ONE]:
		var sample := land.land_at(c.x + d.x, c.y + d.y)
		if sample["what"] in ["water", "deep", "shallows"]:
			level += water(c + d)
			wet += 1
	if wet > 0: h = level / wet
	heights[c] = h
	return h

func prune(around: Vector2i, radius: int) -> void:
	for c: Vector2i in heights.keys():
		if absi(c.x - around.x) > radius or absi(c.y - around.y) > radius:
			heights.erase(c)
	for c: Vector2i in _cells.keys():
		if absi(c.x - around.x) > radius or absi(c.y - around.y) > radius:
			_cells.erase(c)
	for c: Vector2i in pads.keys():
		if Vector2(c * 32 - around).length() > radius + 64: pads.erase(c)
