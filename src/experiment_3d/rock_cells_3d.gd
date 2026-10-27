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
## cell beside it on its level (then the rock is that level's edge, no crag).
static func mesh(cell: Vector2i, base: float, low: Callable, blocked: Callable, flush: Callable, material: Material) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var directions := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
	var edge := directions.any(func(d: Vector2i) -> bool: return flush.call(cell + d))
	var p: Array[Vector3] = []
	for d: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
		var c := cell + d
		p.append(Vector3(d.x - .5, base + (.05 if edge else top(c)), d.y - .5))
	_quad(st, [p[0], p[1], p[2], p[3]])
	var edges := [[0, 1], [1, 3], [3, 2], [2, 0]]
	var corners := [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	for i in 4:
		if blocked.call(cell + directions[i]): continue
		var a := p[edges[i][0]]
		var b := p[edges[i][1]]
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
