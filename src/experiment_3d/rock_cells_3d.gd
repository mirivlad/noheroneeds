class_name RockCells3D
extends RefCounted
## A connected surface inside the server's rock footprint. Every rim point
## is a function of world position and occupancy, including across chunks.
const RIM := [Vector2(0, 0), Vector2(.5, 0), Vector2(1, 0), Vector2(1, .5), Vector2(1, 1), Vector2(.5, 1), Vector2(0, 1), Vector2(0, .5)]
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
static var _scree_meshes := {}

static func top(c: Vector2i) -> float:
	return 1.7 + .24 * sin(c.x * .38 + sin(c.y * .21)) + .13 * sin(c.y * .53 + c.x * .16)

static func style_at(c: Vector2i) -> int:
	# Broad geological domains, not independently coloured tiles.
	return clampi(floori(2 + .95 * (sin(c.x * .021) + .65 * sin(c.y * .017) + .3 * sin((c.x + c.y) * .009))), 0, 3)

## cap(corner) gives a shared absolute-in-mesh-space cap when supplied.
## origin_y restores world height for the shared wall-profile calculation.
## Both are presentation data; blocked remains the authoritative cell mask.
static func mesh(cell: Vector2i, base: float, low: Callable, blocked: Callable, flush: Callable, material: Material,
		top_of := Callable(), shelf := Callable(), cap := Callable(), style := 0, origin_y := 0.0) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	append_to(st, cell, base, low, blocked, flush, top_of, shelf, cap, style, origin_y)
	st.set_material(material)
	return st.commit()

## Emit straight into a chunk's surface; avoid creating/uploading a temporary
## ArrayMesh for each rock cell only to copy it into that same surface.
## Returned world-space triangles are also the authoritative picking faces.
static func append_to(st: SurfaceTool, cell: Vector2i, base: float, low: Callable, blocked: Callable, flush: Callable,
		top_of := Callable(), shelf := Callable(), cap := Callable(), style := 0, origin_y := 0.0, offset := Vector3.ZERO) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var occupied := {cell: true}
	for y in range(-1, 2):
		for x in range(-1, 2):
			var at := cell + Vector2i(x, y)
			if at != cell: occupied[at] = bool(blocked.call(at))
	var edge := DIRECTIONS.any(func(d: Vector2i) -> bool: return flush.call(cell + d))
	if shelf.is_valid(): edge = bool(shelf.call(cell))
	var heights: Array[float] = []
	var floors: Array[float] = []
	var inward: Array[Vector2] = []
	for i in 8:
		var at := Vector2(cell) + (RIM[i] as Vector2)
		inward.append(_inward(at, occupied))
		if i % 2 == 0:
			var corner := Vector2i(at)
			heights.append(float(cap.call(corner)) if cap.is_valid() else base + (.05 if edge else top(corner)))
			floors.append(minf(float(low.call(corner)), heights[-1]))
		else:
			heights.append(0)
			floors.append(0)
	for i in [1, 3, 5, 7]:
		var before: int = (i + 7) % 8
		var after: int = (i + 1) % 8
		var at := Vector2(cell) + (RIM[i] as Vector2)
		# Never notch internal cap edges: repeated grooves at every cell
		# boundary made the old continuous mass read as stacked bricks.
		var chip := (.035 + .045 * sin(at.x * .63 + at.y * .51)) * minf(1, inward[i].length())
		heights[i] = lerpf(heights[before], heights[after], .5) - chip
		floors[i] = minf(lerpf(floors[before], floors[after], .5), heights[i])
	var rim: Array[Vector3] = []
	var mean := 0.0
	for i in 8:
		rim.append(_point(cell, RIM[i], heights[i], floors[i], inward[i], origin_y))
		mean += heights[i] / 8
	var middle := Vector3(.09 * sin(cell.y * .79), mean + (-.025 if edge else .10 * sin(cell.x * .61 + cell.y * .37)), .09 * cos(cell.x * .63))
	for i in 8: _triangle(st, middle, rim[i], rim[(i + 1) % 8], style, offset, faces)
	for side in 4:
		var neighbor: Vector2i = cell + DIRECTIONS[side]
		var rock: bool = occupied[neighbor]
		for segment in 2:
			var a := side * 2 + segment
			var b := (a + 1) % 8
			if rock:
				if not top_of.is_valid(): continue
				var corner_a := cell + Vector2i(RIM[side * 2])
				var corner_b := cell + Vector2i(RIM[(side * 2 + 2) % 8])
				var low_a := float(top_of.call(neighbor, corner_a))
				var low_b := float(top_of.call(neighbor, corner_b))
				var from := lerpf(low_a, low_b, segment * .5)
				var to := lerpf(low_a, low_b, (segment + 1) * .5)
				if heights[a] - from <= .02 and heights[b] - to <= .02: continue
				_quad(st, [_point(cell, RIM[a], minf(from, heights[a]), floors[a], inward[a], origin_y),
					_point(cell, RIM[b], minf(to, heights[b]), floors[b], inward[b], origin_y), rim[a], rim[b]], style, offset, faces)
			else:
				# World-height-driven ridges continue around corners. The four
				# bands shape the rock instead of hiding a rectangular box in noise.
				for band: Array in [[0.0, .23], [.23, .52], [.52, .80], [.80, 1.0]]:
					var points := []
					for f: float in band:
						for index: int in [a, b]:
							points.append(_point(cell, RIM[index], lerpf(floors[index], heights[index], f), floors[index], inward[index], origin_y))
					_quad(st, points, style, offset, faces)
	return faces

static func _inward(at: Vector2, occupied: Dictionary) -> Vector2:
	var direction := Vector2.ZERO
	var count := 0
	for y in range(floori(at.y - .001), floori(at.y + .001) + 1):
		for x in range(floori(at.x - .001), floori(at.x + .001) + 1):
			if occupied.get(Vector2i(x, y), false):
				direction += Vector2(x + .5, y + .5) - at
				count += 1
	var corner := is_equal_approx(at.x, roundf(at.x)) and is_equal_approx(at.y, roundf(at.y))
	return direction.normalized() * (1.55 if count == 1 and corner else 1.0)

static func _point(cell: Vector2i, at: Vector2, height: float, floor_y: float, inward: Vector2, origin_y: float) -> Vector3:
	var world := Vector2(cell) + at
	var h := height + origin_y
	var recess := .17 + .065 * sin(world.x * .51 + world.y * .43 + h * .63) + .045 * sin(h * 1.7 + world.x * .27 - world.y * .36)
	var shift := inward * recess * smoothstep(0, .22, height - floor_y)
	return Vector3(at.x - .5 + shift.x, height, at.y - .5 + shift.y)

static func _triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, style: int, offset := Vector3.ZERO, faces: Variant = null) -> void:
	var normal := (c - a).cross(b - a)
	if normal.length_squared() < .0000000001: return
	st.set_normal(normal.normalized())
	st.set_color(Color(style / 3.0, 0, 0, 1))  # shader data, not an sRGB colour
	for p: Vector3 in [a, b, c]:
		st.set_uv(Vector2(p.x + p.z, p.y))
		var world := p + offset
		st.add_vertex(world)
		if faces != null: faces.append(world)

static func _quad(st: SurfaceTool, p: Array, style: int, offset := Vector3.ZERO, faces: Variant = null) -> void:
	_triangle(st, p[0], p[1], p[2], style, offset, faces)
	_triangle(st, p[1], p[3], p[2], style, offset, faces)

static func scree(variant: int) -> Mesh:
	if _scree_meshes.has(variant): return _scree_meshes[variant]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 3:
		var angle := i * 2.4 + variant
		var at := Vector3(cos(angle), 0, sin(angle)) * (.08 + .02 * i)
		var radius := .045 + .012 * ((i + variant) % 3)
		var points: Array[Vector3] = []
		for j in 5:
			points.append(at + Vector3(cos(j * TAU / 5), -.015, sin(j * TAU / 5)) * Vector3(radius, 1, radius))
		var tip := at + Vector3(.01, radius * 1.25, -.008)
		for j in 5: _triangle(st, points[j], tip, points[(j + 1) % 5], 3)
	_scree_meshes[variant] = st.commit()
	return _scree_meshes[variant]
