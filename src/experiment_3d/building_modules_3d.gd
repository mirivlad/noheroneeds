class_name BuildingModules3D
extends RefCounted
## Cell-sized structural modules with explicit feet, joints and door hinges.
## Geometry is selected per live server part; no decorative replacement house.
var cache := {}
var plaster := _material(Color("d6c5a0"))
var timber := _material(Color("60452e"))
var wood := _material(Color("987548"))
var glass := _material(Color("435d61"))
var stone := _material(Color("817c70"))
var tiles: ShaderMaterial
var rock: ShaderMaterial
var deck: ShaderMaterial

func _init() -> void:
	deck = ShaderMaterial.new()
	deck.shader = load("res://src/experiment_3d/deck.gdshader")
	rock = ShaderMaterial.new()
	rock.shader = load("res://src/experiment_3d/rock.gdshader")
	var image := (load("res://content/base/art/lpc_env/terrain.png") as Texture2D).get_image().get_region(Rect2i(480,96,64,32))
	image.generate_mipmaps()
	rock.set_shader_parameter("rock_texture", ImageTexture.create_from_image(image))
	tiles = ShaderMaterial.new()
	tiles.shader = load("res://src/experiment_3d/roof.gdshader")

static func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = .95
	return m

func _box(mesh: ArrayMesh, size: Vector3, at: Vector3, mat: Material, rotation := 0.0) -> void:
	var box := BoxMesh.new()
	box.size = size
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(box, 0, Transform3D(Basis(Vector3.UP, rotation), at))
	st.set_material(mat)
	st.commit(mesh)

func wall(mask: int, stone_wall := false, style := "") -> Mesh:
	var key := "wall:%d:%s:%s" % [mask, stone_wall, style]
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	var panel := stone if stone_wall else plaster
	for i in 4:
		if mask & (1 << i) == 0: continue
		var angle := i * PI / 2
		var along := Vector3(.25, 0, 0).rotated(Vector3.UP, angle)
		if style == "log":
			for course in 9:
				_box(mesh, Vector3(.53, .21, .29), along + Vector3.UP * (.11 + course * .22), wood, angle)
			continue
		_box(mesh, Vector3(.5, 1.86, .18), along + Vector3.UP * .97, panel, angle)
		if not stone_wall and style != "plaster":
			for h: float in [.12, 1.91]:
				_box(mesh, Vector3(.51, .14, .23), along + Vector3.UP * h, timber, angle)
	_box(mesh, Vector3(.19, 2, .19), Vector3.UP, panel if stone_wall or style == "plaster" else timber)
	cache[key] = mesh
	return mesh

## A fence's cell: a post in its middle, two rails to each side it goes on to
## (`mask` bits: east, north, west, south).
func fence(mask: int) -> Mesh:
	var key := "fence:%d" % mask
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	for i in 4:
		if mask & (1 << i) == 0: continue
		var angle := i * PI / 2
		var along := Vector3(.25, 0, 0).rotated(Vector3.UP, angle)
		for h: float in [.32, .62]:
			_box(mesh, Vector3(.52, .07, .05), along + Vector3.UP * h, wood, angle)
	_box(mesh, Vector3(.1, .78, .1), Vector3.UP * .39, timber)
	cache[key] = mesh
	return mesh

## A gate across a fence's line (along x): two posts, a leaf of upright boards
## with a brace, swung open about its left post.
func gate(opened: bool) -> Mesh:
	var key := "gate:%s" % opened
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	for x: float in [-.45, .45]:
		_box(mesh, Vector3(.11, .9, .11), Vector3(x, .45, 0), timber)
	var angle := -PI / 2 if opened else 0.0
	var hinge := Vector3(-.39, 0, 0)
	for i in 6:
		var local := Vector3(.065 + i * .13, .4, 0).rotated(Vector3.UP, angle)
		_box(mesh, Vector3(.11, .64, .04), hinge + local, wood, angle)
	for h: float in [.2, .6]:
		_box(mesh, Vector3(.78, .06, .04), hinge + Vector3(.39, h, .04).rotated(Vector3.UP, angle), timber, angle)
	# The brace, corner to corner.
	var brace := Basis(Vector3.UP, angle) * Basis(Vector3.BACK, atan2(.4, .7))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var box := BoxMesh.new()
	box.size = Vector3(.82, .05, .035)
	st.append_from(box, 0, Transform3D(brace, hinge + Vector3(.39, .4, .065).rotated(Vector3.UP, angle)))
	st.set_material(timber)
	st.commit(mesh)
	cache[key] = mesh
	return mesh

## A campfire: logs leaned together in a ring of stones (its flames and smoke
## are particles, Effects3D).
func campfire() -> Mesh:
	if cache.has("campfire"): return cache["campfire"]
	var mesh := ArrayMesh.new()
	for i in 9:  # the ring of stones
		var a := i * TAU / 9.0
		_box(mesh, Vector3(.16, .1 + .03 * (i % 3), .13), Vector3(cos(a) * .4, .05, sin(a) * .4), stone, -a)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 5:  # logs leaned to the middle, a little apart
		var a := i * TAU / 5.0 + .3
		var lean := Basis(Vector3.UP, -a) * Basis(Vector3.BACK, -.9)  # the inner end up
		var log := BoxMesh.new()
		log.size = Vector3(.5, .07, .07)
		st.append_from(log, 0, Transform3D(lean, Vector3(cos(a) * .14, .15, sin(a) * .14)))
	st.set_material(timber)
	st.commit(mesh)
	_box(mesh, Vector3(.3, .03, .3), Vector3.UP * .015, _material(Color("2a2420")))  # ash
	cache["campfire"] = mesh
	return mesh

## A bed (the author, 28.10.2026: it was a cube): a wooden frame on four legs
## with a headboard to the north, a mattress, a pillow, a blanket over its foot.
func bed() -> Mesh:
	if cache.has("bed"): return cache["bed"]
	var mesh := ArrayMesh.new()
	for x: float in [-.38, .38]:
		for z: float in [-.44, .44]:
			_box(mesh, Vector3(.08, .3, .08), Vector3(x, .15, z), timber)
	for x: float in [-.38, .38]:
		_box(mesh, Vector3(.06, .1, .9), Vector3(x, .27, 0), wood)
	_box(mesh, Vector3(.82, .1, .06), Vector3(0, .27, .44), wood)
	_box(mesh, Vector3(.84, .5, .07), Vector3(0, .45, -.45), timber)  # the headboard
	_box(mesh, Vector3(.72, .1, .84), Vector3(0, .35, 0), _material(Color("d8cfb8")))  # the mattress
	_box(mesh, Vector3(.5, .08, .2), Vector3(0, .44, -.3), _material(Color("efe8d8")))  # the pillow
	_box(mesh, Vector3(.76, .06, .52), Vector3(0, .42, .16), _material(Color("8a3a32")))  # the blanket
	cache["bed"] = mesh
	return mesh

## A post of a building: a squared beam with a foot and a head.
func column() -> Mesh:
	if cache.has("column"): return cache["column"]
	var mesh := ArrayMesh.new()
	_box(mesh, Vector3(.34, .12, .34), Vector3.UP * .06, stone)
	_box(mesh, Vector3(.22, 1.8, .22), Vector3.UP * 1.02, timber)
	_box(mesh, Vector3(.32, .1, .32), Vector3.UP * 1.95, wood)
	cache["column"] = mesh
	return mesh


func _cylinder(mesh: ArrayMesh, radius: float, height: float, at: Vector3, mat: Material) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 12
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(cylinder, 0, Transform3D(Basis.IDENTITY, at))
	st.set_material(mat)
	st.commit(mesh)


## Permanent, assembled furniture in the same timber/plaster style as the
## building modules: legs, boards, backs, shelving and cups, not stand-ins.
func furniture(kind: String, decor := 0) -> Mesh:
	var key := "furniture:%s:%d" % [kind, decor % 3]
	if cache.has(key):
		return cache[key]
	var mesh := ArrayMesh.new()
	var board := [wood, _material(Color("86633f")), _material(Color("ad8050"))][decor % 3] as Material
	var metal := _material(Color("b18b4e"))
	if kind == "chair":
		for x: float in [-.21, .21]:
			for z: float in [-.21, .21]:
				_box(mesh, Vector3(.065, .47, .065), Vector3(x, .235, z), timber)
		for x: float in [-.17, 0, .17]:
			_box(mesh, Vector3(.15, .07, .51), Vector3(x, .48, 0), board)
		for x: float in [-.21, .21]:
			_box(mesh, Vector3(.065, .48, .065), Vector3(x, .75, -.21), timber)
		for y: float in [.68, .9]:
			_box(mesh, Vector3(.48, .11, .05), Vector3(0, y, -.21), board)
	elif kind == "table" or kind == "round_table":
		if kind == "table":
			for x: float in [-.52, .52]:
				for z: float in [-.3, .3]:
					_box(mesh, Vector3(.1, .72, .1), Vector3(x, .36, z), timber)
			for z: float in [-.29, 0, .29]:
				_box(mesh, Vector3(1.35, .09, .27), Vector3(0, .76, z), board)
			_box(mesh, Vector3(1.1, .1, .06), Vector3(0, .35, 0), timber)
		else:
			_cylinder(mesh, .59, .09, Vector3(0, .76, 0), board)
			_cylinder(mesh, .12, .68, Vector3(0, .35, 0), timber)
			for turn in 2:
				_box(mesh, Vector3(.85, .1, .12), Vector3.UP * .07, timber, turn * PI / 2)
		_cylinder(mesh, .16, .025, Vector3(.18, .82, .12), _material(Color("d8c79e")))
		_cylinder(mesh, .07, .16, Vector3(-.2, .88, -.16), metal)
	elif kind == "counter":
		for x: float in [-.43, .43]:
			_box(mesh, Vector3(.1, 1, .1), Vector3(x, .5, 0), timber)
		for x: float in [-.36, -.18, 0, .18, .36]:
			_box(mesh, Vector3(.16, .81, .09), Vector3(x, .45, .24), board)
		for y: float in [.2, .65]:
			_box(mesh, Vector3(.87, .06, .49), Vector3(0, y, -.02), board)
		_box(mesh, Vector3(1.02, .11, .72), Vector3.UP * .98, board)
		_box(mesh, Vector3(1.02, .035, .04), Vector3(0, .94, .36), metal)
		for x: float in [-.25, .08]:
			_cylinder(mesh, .065, .16, Vector3(x, 1.11, -.04), metal)
	elif kind == "well":
		for side in 4:
			var angle := side * PI / 2
			_box(mesh, Vector3(.9, .65, .18), Vector3(0, .325, .38).rotated(Vector3.UP, angle), stone, angle)
		_box(mesh, Vector3(.58, .02, .58), Vector3.UP * .12, glass)
		for x: float in [-.38, .38]:
			_box(mesh, Vector3(.1, 1.7, .1), Vector3(x, .85, 0), timber)
		_box(mesh, Vector3(.9, .1, .1), Vector3.UP * 1.65, timber)
		_box(mesh, Vector3(.025, .85, .025), Vector3.UP * 1.2, wood)
		_cylinder(mesh, .12, .19, Vector3(0, .72, 0), metal)
	elif kind == "hay_rack":
		for x: float in [-.38, .38]:
			for z: float in [-.3, .3]:
				_box(mesh, Vector3(.07, .85, .07), Vector3(x, .425, z), timber)
		_box(mesh, Vector3(.68, .3, .48), Vector3.UP * .47, _material(Color("b49a4e")))
		for z: float in [-.3, .3]:
			for x: float in [-.3, -.1, .1, .3]:
				_box(mesh, Vector3(.04, .45, .04), Vector3(x, .55, z), wood)
	elif kind == "shrine":
		_box(mesh, Vector3(.9, .18, .85), Vector3.UP * .09, stone)
		_box(mesh, Vector3(.65, .62, .5), Vector3.UP * .45, stone)
		_box(mesh, Vector3(.95, .14, .8), Vector3.UP * .82, stone)
		_cylinder(mesh, .12, .18, Vector3(0, .98, 0), metal)
	elif kind == "sign":
		_box(mesh, Vector3(.12, 1.9, .12), Vector3(.38, .95, 0), timber)
		_box(mesh, Vector3(.95, .08, .09), Vector3(0, 1.83, 0), timber)
		for x: float in [-.25, .25]:
			_box(mesh, Vector3(.025, .23, .025), Vector3(x, 1.67, 0), metal)
		for y: float in [1.26, 1.47]:
			_box(mesh, Vector3(.74, .19, .09), Vector3(0, y, 0), board)
		_cylinder(mesh, .12, .23, Vector3(0, 1.39, .09), metal)
		_box(mesh, Vector3(.14, .035, .04), Vector3(.13, 1.48, .09), metal)
		_box(mesh, Vector3(.035, .15, .04), Vector3(.2, 1.42, .09), metal)
		_box(mesh, Vector3(.14, .035, .04), Vector3(.13, 1.34, .09), metal)
	cache[key] = mesh
	return mesh

## A forge (it was a barrel): a stone furnace with a glowing mouth to the south
## and a chimney (its smoke and light are the content's).
func forge() -> Mesh:
	if cache.has("forge"): return cache["forge"]
	var mesh := ArrayMesh.new()
	_box(mesh, Vector3(.9, .7, .85), Vector3.UP * .35, stone)
	_box(mesh, Vector3(.95, .08, .9), Vector3.UP * .74, _material(Color("6e6a62")))
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color("ff8a2a")
	glow.emission_enabled = true
	glow.emission = Color("ff6a10")
	glow.emission_energy_multiplier = 2.0
	_box(mesh, Vector3(.4, .26, .06), Vector3(0, .3, .41), glow)  # the mouth, aglow
	_box(mesh, Vector3(.3, .7, .3), Vector3(.2, 1.12, -.2), stone)  # the chimney
	cache["forge"] = mesh
	return mesh

## A stump (the author, 28.10.2026: they lay like logs): a short trunk of bark
## standing up, its cut lighter on top with a ring, a root or three at its foot.
func stump() -> Mesh:
	if cache.has("stump"): return cache["stump"]
	var mesh := ArrayMesh.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = .2
	trunk.bottom_radius = .24
	trunk.height = .34
	trunk.radial_segments = 8
	trunk.rings = 1
	trunk.cap_top = false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(trunk, 0, Transform3D(Basis.IDENTITY, Vector3.UP * .17))
	st.set_material(timber)
	st.commit(mesh)
	var cut := CylinderMesh.new()
	cut.top_radius = .2
	cut.bottom_radius = .2
	cut.height = .02
	cut.radial_segments = 8
	var top := SurfaceTool.new()
	top.begin(Mesh.PRIMITIVE_TRIANGLES)
	top.append_from(cut, 0, Transform3D(Basis.IDENTITY, Vector3.UP * .335))
	top.set_material(_material(Color("c9a46c")))
	top.commit(mesh)
	_box(mesh, Vector3(.24, .03, .24), Vector3.UP * .35, _material(Color("a8804e")), PI / 8)  # the ring
	for i in 3:
		var a := i * TAU / 3.0 + .4
		_box(mesh, Vector3(.22, .08, .09), Vector3(cos(a) * .25, .04, sin(a) * .25), timber, -a)
	cache["stump"] = mesh
	return mesh

func opening(window: bool, opened: bool, aperture := 1.0) -> Mesh:
	aperture = clampf(aperture, .4, 1.0)
	var key := "opening:%s:%s:%f" % [window, opened, aperture]
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	for x: float in [-.455, .455]:
		_box(mesh, Vector3(.09, 2, .23), Vector3(x, 1, 0), timber)
	_box(mesh, Vector3(.82, .16, .23), Vector3(0, 1.92, 0), timber)
	if window:
		var bottom := 1.16 - .41 * aperture
		var top := 1.16 + .41 * aperture
		_box(mesh, Vector3(.82, bottom, .18), Vector3(0, bottom * .5, 0), plaster)
		_box(mesh, Vector3(.82, 1.84 - top, .18), Vector3(0, (1.84 + top) * .5, 0), plaster)
		if aperture < 1.0:
			var infill := .41 * (1.0 - aperture)
			for sign_x: float in [-1, 1]:
				_box(mesh, Vector3(infill, .82 * aperture, .18), Vector3(sign_x * (.41 - infill * .5), 1.16, 0), plaster)
		_box(mesh, Vector3(.68 * aperture, .7 * aperture, .06), Vector3(0, 1.16, -.02), glass)
		for x: float in [-.37, 0, .37]:
			_box(mesh, Vector3(.055, .82 * aperture, .23), Vector3(x * aperture, 1.16, 0), timber)
		for h: float in [bottom, top]:
			_box(mesh, Vector3(.82 * aperture, .07, .28), Vector3(0, h, .015), wood)
	else:
		# Rotate the entire leaf about its left jamb, never about its centre.
		var angle := -PI / 2 if opened else 0.0
		var hinge := Vector3(-.39, 0, 0)
		for i in 5:
			var local := Vector3(.08 + i * .16, .88, 0).rotated(Vector3.UP, angle)
			_box(mesh, Vector3(.155, 1.76, .075), hinge + local, wood, angle)
		for h: float in [.25, 1.48]:
			_box(mesh, Vector3(.78, .08, .045), hinge + Vector3(.4, h, .06).rotated(Vector3.UP, angle), timber, angle)
		_box(mesh, Vector3(.1, .035, .05), hinge + Vector3(.68, .9, .09).rotated(Vector3.UP, angle), stone, angle)
	cache[key] = mesh
	return mesh

func floor_mesh() -> Mesh:
	if cache.has("floor"): return cache["floor"]
	var mesh := ArrayMesh.new()
	for i in 5:
		_box(mesh, Vector3(.196, .12, 1), Vector3(-.4 + i * .2, -.06, 0), wood)
	cache["floor"] = mesh
	return mesh

func roof(cell: Vector2i, footprint: Rect2i, eaves := 15, options := {}) -> Mesh:
	if not (options.get("sections", []) as Array).is_empty():
		return _compound_roof(cell, eaves, options)
	var local := cell - footprint.position
	var axis := int(options.get("axis", 0))
	var pitch := float(options.get("pitch", .52))
	var overhang := float(options.get("eaves", .45))
	var kind := String(options.get("material", "tile"))
	var key := "roof:%s:%s:%d:%d:%f:%f:%s" % [local, footprint.size, eaves, axis, pitch, overhang, kind]
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	var low := Vector2(cell)
	var high := low + Vector2.ONE
	if cell.x == footprint.position.x + 1 and eaves & 4: low.x = footprint.position.x + .5 - overhang
	if cell.y == footprint.position.y + 1 and eaves & 2: low.y = footprint.position.y + .5 - overhang
	if cell.x == footprint.end.x - 2 and eaves & 1: high.x = footprint.end.x - .5 + overhang
	if cell.y == footprint.end.y - 2 and eaves & 8: high.y = footprint.end.y - .5 + overhang
	var middle := float(footprint.position[axis]) + float(footprint.size[axis]) * .5
	var cuts: Array[float] = [low[axis]]
	if middle > low[axis] and middle < high[axis]: cuts.append(middle)
	cuts.append(high[axis])
	var across := 1 - axis
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(cuts.size() - 1):
		var a := cuts[i]
		var b := cuts[i + 1]
		var points := [_roof_point(a, low[across], footprint, pitch, axis), _roof_point(b, low[across], footprint, pitch, axis),
			_roof_point(a, high[across], footprint, pitch, axis), _roof_point(b, high[across], footprint, pitch, axis)]
		var normal: Vector3 = (points[2] - points[0]).cross(points[1] - points[0]).normalized()
		if axis == 1: normal = -normal
		for j in ([0, 1, 2, 1, 3, 2] if axis == 0 else [0, 2, 1, 1, 2, 3]):
			st.set_normal(normal)
			st.set_uv(Vector2(points[j].x - footprint.position.x, points[j].z - footprint.position.y))
			st.add_vertex(points[j] - Vector3(cell.x + .5, 0, cell.y + .5))
	st.set_material(_roof_material(kind))
	st.commit(mesh)
	for edge: float in [footprint.position[across] + .5, footprint.end[across] - .5]:
		if edge < low[across] or edge > high[across]: continue
		for i in range(cuts.size() - 1):
			var top_a := _roof_point(cuts[i], edge, footprint, pitch, axis)
			var top_b := _roof_point(cuts[i + 1], edge, footprint, pitch, axis)
			var bottom_a := Vector3(top_a.x, 0, top_a.z)
			var bottom_b := Vector3(top_b.x, 0, top_b.z)
			var points := [bottom_a, bottom_b, top_a, top_b]
			var face := SurfaceTool.new()
			face.begin(Mesh.PRIMITIVE_TRIANGLES)
			var near_edge := edge < footprint.position[across] + footprint.size[across] * .5
			var reverse := (axis == 0 and not near_edge) or (axis == 1 and near_edge)
			var normal := (Vector3.FORWARD if near_edge else Vector3.BACK) if axis == 0 else (Vector3.LEFT if near_edge else Vector3.RIGHT)
			for j in ([0, 2, 1, 1, 2, 3] if reverse else [0, 1, 2, 1, 3, 2]):
				face.set_normal(normal)
				face.add_vertex(points[j] - Vector3(cell.x + .5, 0, cell.y + .5))
			face.set_material(plaster)
			face.commit(mesh)
	cache[key] = mesh
	return mesh

func _roof_point(along: float, across: float, footprint: Rect2i, pitch: float, axis: int) -> Vector3:
	var height := _roof_height(along, footprint, pitch, axis)
	return Vector3(along, height, across) if axis == 0 else Vector3(across, height, along)

func _roof_height(along: float, footprint: Rect2i, pitch := .52, axis := 0) -> float:
	var middle := footprint.position[axis] + footprint.size[axis] * .5
	return .12 + (footprint.size[axis] * .5 - absf(along - middle)) * pitch

func _roof_material(kind: String) -> Material:
	if kind == "tile": return tiles
	var key := "roof-material:" + kind
	if cache.has(key): return cache[key]
	var material := tiles.duplicate() as ShaderMaterial
	material.set_shader_parameter("roof_kind", {"thatch": 1, "wood": 2, "stone": 3, "flat": 4}.get(kind, 0))
	cache[key] = material
	return material

## All adjoining modules sample the same upper envelope at shared vertices.
## This joins intersecting gables without cracks or a roof over missing rooms.
func _compound_roof(cell: Vector2i, eaves: int, options: Dictionary) -> Mesh:
	var sections: Array = options["sections"]
	var relative := []
	for section: Array in sections:
		relative.append([int(section[0]) - cell.x, int(section[1]) - cell.y, section[2], section[3], section[4]])
	var pitch := float(options.get("pitch", .52))
	var width := float(options.get("eaves", .2))
	var kind := String(options.get("material", "thatch"))
	var gable := String(options.get("gable", "plaster"))
	var key := "compound:%s:%d:%f:%f:%s:%s" % [relative, eaves, pitch, width, kind, gable]
	if cache.has(key): return cache[key]
	var low := Vector2(cell)
	var high := low + Vector2.ONE
	if eaves & 4: low.x -= .5 + width
	if eaves & 2: low.y -= .5 + width
	if eaves & 1: high.x += .5 + width
	if eaves & 8: high.y += .5 + width
	var cuts := [[low.x, high.x], [low.y, high.y]]
	for section: Array in sections:
		var axis := int(section[4])
		var ridge := float(section[axis]) + float(section[axis + 2]) * .5
		if ridge > low[axis] and ridge < high[axis] and ridge not in cuts[axis]:
			cuts[axis].append(ridge)
	(cuts[0] as Array).sort()
	(cuts[1] as Array).sort()
	var mesh := ArrayMesh.new()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var origin := Vector3(cell.x + .5, 0, cell.y + .5)
	for x in (cuts[0] as Array).size() - 1:
		for z in (cuts[1] as Array).size() - 1:
			var points: Array[Vector3] = []
			for point: Vector2 in [Vector2(cuts[0][x], cuts[1][z]), Vector2(cuts[0][x + 1], cuts[1][z]),
					Vector2(cuts[0][x], cuts[1][z + 1]), Vector2(cuts[0][x + 1], cuts[1][z + 1])]:
				points.append(Vector3(point.x, _roof_envelope(point, sections, pitch), point.y))
			for triangle: Array in [[0, 1, 2], [1, 3, 2]]:
				var normal := (points[triangle[2]] - points[triangle[0]]).cross(points[triangle[1]] - points[triangle[0]]).normalized()
				for index: int in triangle:
					surface.set_normal(normal)
					surface.set_uv(Vector2(points[index].x, points[index].z))
					surface.add_vertex(points[index] - origin)
	surface.set_material(_roof_material(kind))
	surface.commit(mesh)
	var fascia := SurfaceTool.new()
	fascia.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := 0
	for side in 4:
		if eaves & (1 << side) == 0: continue
		var axis := 1 if side in [0, 2] else 0
		var edge := (high.x if side == 0 else low.x) if axis == 1 else (low.y if side == 1 else high.y)
		for index in (cuts[axis] as Array).size() - 1:
			var a := Vector2(edge, cuts[axis][index]) if axis == 1 else Vector2(cuts[axis][index], edge)
			var b := Vector2(edge, cuts[axis][index + 1]) if axis == 1 else Vector2(cuts[axis][index + 1], edge)
			var points := [Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y),
				Vector3(a.x, _roof_envelope(a, sections, pitch), a.y), Vector3(b.x, _roof_envelope(b, sections, pitch), b.y)]
			var reverse := side in [2, 3]
			var normal: Vector3 = [Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT, Vector3.BACK][side]
			for j in ([0, 2, 1, 1, 2, 3] if reverse else [0, 1, 2, 1, 3, 2]):
				fascia.set_normal(normal)
				fascia.add_vertex(points[j] - origin)
			faces += 1
	if faces > 0:
		fascia.set_material(wood if gable == "wood" else (stone if gable == "stone" else plaster))
		fascia.commit(mesh)
	cache[key] = mesh
	return mesh

func _roof_envelope(point: Vector2, sections: Array, pitch: float) -> float:
	var height := .12
	for section: Array in sections:
		if point.x < float(section[0]) or point.x > float(section[0]) + float(section[2]) or point.y < float(section[1]) or point.y > float(section[1]) + float(section[3]):
			continue
		var axis := int(section[4])
		var span := float(section[axis + 2])
		var middle := float(section[axis]) + span * .5
		height = maxf(height, .12 + (span * .5 - absf(point[axis] - middle)) * pitch)
	return height
