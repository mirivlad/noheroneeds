class_name TerrainShape3D
extends RefCounted
## Presentation units: 1 cell = 1 metre, LPC human approximately 1.5 m.
## Geography is the existing coarse relief; its fine grain stays small.
## Calibrated against the seed-431 mountain route; see quality evidence.
const RELIEF := 72.0
const GRAIN := 4.0
var land: SurfaceGenerator
var heights := {}
var pads := {}
var extra_pads: Array = []

func _init(source: SurfaceGenerator) -> void:
	land = source

func natural(c: Vector2i) -> float:
	var macro := land.geography.sample(Geography.HEIGHT, c.x, c.y)
	return (macro - Geography.SEA) * RELIEF + (float(land.land_at(c.x, c.y)["height"]) - macro) * GRAIN

func water(c: Vector2i) -> float:
	var h := float(land.land_at(c.x, c.y)["height"])
	var lake := land.geography.lake_level_at(c.x, c.y)
	if h < Geography.SEA: return 0
	if h < lake: return (lake - Geography.SEA) * RELIEF
	# Rivers keep their original course and descend with the original valley.
	return natural(c) - .12

func height(c: Vector2i) -> float:
	if heights.has(c): return heights[c]
	var h := natural(c)
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
	for c: Vector2i in pads.keys():
		if Vector2(c * 32 - around).length() > radius + 64: pads.erase(c)
