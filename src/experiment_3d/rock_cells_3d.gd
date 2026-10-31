class_name RockCells3D
extends RefCounted
## Continuous rock mass, clipped to exactly the server's blocked cells.
## Shared corners remove brick seams; exposed faces keep a chipped profile.
## On the surface a cliff (rock at the edge of a level, ADR-0061) is flush with
## the level it bounds and drops sheer to the ground below; a crag with no such
## level beside it stands up out of its ground.
static func top(c: Vector2i) -> float:
	return 1.65 + .28 * sin(c.x * 1.37 + sin(c.y * 1.91))

## base: the cell's ground, relative to the mesh; low(corner): the lowest walkable
## ground at a corner, relative; blocked(cell): rock there; flush(cell): a walkable
## cell beside it on its level (then the rock is that level's edge, no crag);
## top_of(rock cell, corner): a rock neighbour's top at a shared corner, relative —
## where it stands lower (a cliff's steps, an edge by a crag) the face between
## goes down to it, never a gap one sees through. shelf(cell): this rock really is
## the edge of a level (SurfaceGenerator.is_cliff), so its top lies flush; without
## it every rock with a walkable neighbour at its level was drawn flush, and a
## solid crag one cannot walk on looked like level, walkable ground. A rock cell
## that is no shelf stands up as a crag, clearly not a way through.
static func mesh(cell: Vector2i, base: float, low: Callable, blocked: Callable, flush: Callable, material: Material,
		top_of := Callable(), shelf := Callable()) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var directions := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
	var edge := directions.any(func(d: Vector2i) -> bool: return flush.call(cell + d))
	# Where the caller knows whether this rock truly is a level's edge (the
	# server's is_cliff), that alone decides: a crag that merely stands beside
	# level ground must look like the solid it is.
	if shelf.is_valid():
		edge = bool(shelf.call(cell))
	var p: Array[Vector3] = []
	for d: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
		var c := cell + d
		p.append(Vector3(d.x - .5, base + (.05 if edge else top(c)), d.y - .5))
	_quad(st, [p[0], p[1], p[2], p[3]])
	var edges := [[0, 1], [1, 3], [3, 2], [2, 0]]
	var corners := [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	for i in 4:
		var a := p[edges[i][0]]
		var b := p[edges[i][1]]
		if blocked.call(cell + directions[i]):
			if top_of.is_valid():
				var ta := minf(float(top_of.call(cell + directions[i], cell + corners[edges[i][0]])), a.y)
				var tb := minf(float(top_of.call(cell + directions[i], cell + corners[edges[i][1]])), b.y)
				if a.y - ta > .02 or b.y - tb > .02:
					_quad(st, [Vector3(a.x, ta, a.z), Vector3(b.x, tb, b.z), a, b])
			continue
		var floor_a := Vector3(a.x, minf(float(low.call(cell + corners[edges[i][0]])), a.y), a.z)
		var floor_b := Vector3(b.x, minf(float(low.call(cell + corners[edges[i][1]])), b.y), b.z)
		var middle_a := floor_a.lerp(a, .56)
		var middle_b := floor_b.lerp(b, .56)
		# Recess into the blocked cell, never create an invisible obstruction.
		var inset := Vector3(-directions[i].x, 0, -directions[i].y) * .10
		middle_a += inset
		middle_b += inset
		_quad(st, [floor_a, floor_b, middle_a, middle_b])
		_quad(st, [middle_a, middle_b, a, b])
	st.set_material(material)
	return st.commit()

static func _quad(st: SurfaceTool, p: Array) -> void:
	for face: Array in [[0, 1, 2], [1, 3, 2]]:
		var n: Vector3 = (p[face[2]] - p[face[0]]).cross(p[face[1]] - p[face[0]]).normalized()
		for i: int in face:
			st.set_normal(n)
			st.set_uv(Vector2(p[i].x + p[i].z, p[i].y))
			st.add_vertex(p[i])
