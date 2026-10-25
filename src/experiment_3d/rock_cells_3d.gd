class_name RockCells3D
extends RefCounted
## Continuous rock mass, clipped to exactly the server's blocked cells.
## Shared corners remove brick seams; exposed faces keep a chipped profile.
static func top(c: Vector2i) -> float:
	return 1.65 + .28 * sin(c.x * 1.37 + sin(c.y * 1.91))

static func mesh(cell: Vector2i, base: Callable, blocked: Callable, material: Material) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p: Array[Vector3] = []
	for d: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
		var c := cell + d
		p.append(Vector3(d.x - .5, float(base.call(c)) + top(c), d.y - .5))
	_quad(st, [p[0], p[1], p[2], p[3]])
	var directions := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
	var edges := [[0, 1], [1, 3], [3, 2], [2, 0]]
	for i in 4:
		if blocked.call(cell + directions[i]): continue
		var a := p[edges[i][0]]
		var b := p[edges[i][1]]
		var floor_a := a - Vector3.UP * top(cell + Vector2i(roundi(a.x + .5), roundi(a.z + .5)))
		var floor_b := b - Vector3.UP * top(cell + Vector2i(roundi(b.x + .5), roundi(b.z + .5)))
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
