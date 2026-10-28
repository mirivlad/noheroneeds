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

func wall(mask: int, stone_wall := false) -> Mesh:
	var key := "wall:%d:%s" % [mask, stone_wall]
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	var panel := stone if stone_wall else plaster
	for i in 4:
		if mask & (1 << i) == 0: continue
		var angle := i * PI / 2
		var along := Vector3(.25, 0, 0).rotated(Vector3.UP, angle)
		_box(mesh, Vector3(.5, 1.86, .18), along + Vector3.UP * .97, panel, angle)
		for h: float in [.12, 1.91]:
			_box(mesh, Vector3(.51, .14, .23), along + Vector3.UP * h, timber, angle)
	_box(mesh, Vector3(.19, 2, .19), Vector3.UP, timber)
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

func opening(window: bool, opened: bool) -> Mesh:
	var key := "opening:%s:%s" % [window, opened]
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	for x: float in [-.455, .455]:
		_box(mesh, Vector3(.09, 2, .23), Vector3(x, 1, 0), timber)
	_box(mesh, Vector3(.82, .16, .23), Vector3(0, 1.92, 0), timber)
	if window:
		_box(mesh, Vector3(.82, .75, .18), Vector3(0, .375, 0), plaster)
		_box(mesh, Vector3(.82, .27, .18), Vector3(0, 1.705, 0), plaster)
		_box(mesh, Vector3(.68, .7, .06), Vector3(0, 1.16, -.02), glass)
		for x: float in [-.37, 0, .37]:
			_box(mesh, Vector3(.055, .82, .23), Vector3(x, 1.16, 0), timber)
		for h: float in [.75, 1.56]:
			_box(mesh, Vector3(.82, .07, .28), Vector3(0, h, .015), wood)
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

func roof(cell: Vector2i, footprint: Rect2i, eaves := 15) -> Mesh:
	var local := cell - footprint.position
	var key := "roof:%s:%s:%d" % [local, footprint.size, eaves]
	if cache.has(key): return cache[key]
	var mesh := ArrayMesh.new()
	# Interior roof cells own their adjacent eaves. Missing interior parts
	# leave real holes while the surviving patches retain the same ridge.
	var low := Vector2(cell)
	var high := low + Vector2.ONE
	if cell.x == footprint.position.x + 1 and eaves & 4: low.x = footprint.position.x + .05
	if cell.y == footprint.position.y + 1 and eaves & 2: low.y = footprint.position.y + .05
	if cell.x == footprint.end.x - 2 and eaves & 1: high.x = footprint.end.x - .05
	if cell.y == footprint.end.y - 2 and eaves & 8: high.y = footprint.end.y - .05
	var middle := (footprint.position.x + footprint.size.x * .5)
	var cuts: Array[float] = [low.x]
	if middle > low.x and middle < high.x: cuts.append(middle)
	cuts.append(high.x)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(cuts.size() - 1):
		var a := cuts[i]
		var b := cuts[i + 1]
		var p: Array[Vector3] = [Vector3(a, _roof_height(a, footprint), low.y), Vector3(b, _roof_height(b, footprint), low.y), Vector3(a, _roof_height(a, footprint), high.y), Vector3(b, _roof_height(b, footprint), high.y)]
		var n := (p[2] - p[0]).cross(p[1] - p[0]).normalized()
		for j in [0, 1, 2, 1, 3, 2]:
			st.set_normal(n)
			st.set_uv(Vector2(p[j].x - footprint.position.x, p[j].z - footprint.position.y))
			st.add_vertex(p[j] - Vector3(cell.x + .5, 0, cell.y + .5))
	st.set_material(tiles)
	st.commit(mesh)
	# Timber fascia follows the actual sloping edge; no prefab distortion.
	for z: float in [footprint.position.y + .5, footprint.end.y - .5]:
		if z < low.y or z > high.y: continue
		for i in range(cuts.size() - 1):
			var a := cuts[i]
			var b := cuts[i + 1]
			var y1 := _roof_height(a, footprint)
			var y2 := _roof_height(b, footprint)
			var face := SurfaceTool.new()
			face.begin(Mesh.PRIMITIVE_TRIANGLES)
			var p := [Vector3(a, 0, z), Vector3(b, 0, z), Vector3(a, y1 - .04, z), Vector3(b, y2 - .04, z)]
			for j in ([0, 1, 2, 1, 3, 2] if z < (footprint.position.y + footprint.size.y * .5) else [0, 2, 1, 1, 2, 3]):
				face.set_normal(Vector3.FORWARD if z < (footprint.position.y + footprint.size.y * .5) else Vector3.BACK)
				face.add_vertex(p[j] - Vector3(cell.x + .5, 0, cell.y + .5))
			face.set_material(plaster)
			face.commit(mesh)
	cache[key] = mesh
	return mesh

func _roof_height(x: float, footprint: Rect2i) -> float:
	return .12 + (footprint.size.x * .5 - absf(x - (footprint.position.x + footprint.size.x * .5))) * .52
