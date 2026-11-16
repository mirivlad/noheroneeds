class_name MineralMeshes3D
extends RefCounted
## Original, bounded resource silhouettes. Geometry and veins are presentation;
## definitions still decide obstruction, tool, yield and depletion.
const VARIANTS := 6
const IDS := ["base:boulder", "base:pebbles", "base:iron_outcrop", "base:copper_outcrop", "base:silver_outcrop", "base:gold_outcrop"]
const ORE_COLORS := {"iron": "b78257", "copper": "78ad99", "silver": "d1d7ce", "gold": "cdb261"}
var _materials := {}
var _rng := RandomNumberGenerator.new()

static func supports(id: String) -> bool:
	return id in IDS

static func variant_at(id: String, cell: Vector2i) -> int:
	return posmod(hash([id, cell.x, cell.y, 3803]), VARIANTS)

func build(id: String, variant: int) -> ArrayMesh:
	_rng.seed = hash(["mineral-shape", variant, 1289])
	var mesh := ArrayMesh.new()
	var stone := SurfaceTool.new()
	stone.begin(Mesh.PRIMITIVE_TRIANGLES)
	var veins := SurfaceTool.new()
	veins.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ore := id.trim_prefix("base:").trim_suffix("_outcrop")
	var mineral := ORE_COLORS.has(ore)
	if id == "base:pebbles":
		for i in 4:
			var angle := i * 2.4 + variant
			var centre := Vector3(cos(angle), 0, sin(angle)) * (.12 + .035 * i)
			_rock(stone, veins, centre, .11 + .02 * (i % 3), .13 + .03 * (i % 2), "")
	else:
		var width: float = [.40, .34, .44, .37, .42, .31][variant]
		var height: float = [.48, .72, .36, .61, .43, .79][variant]
		_rock(stone, veins, Vector3.ZERO, width, height, ore if mineral else "")
	stone.set_material(_material("stone"))
	stone.commit(mesh)
	if mineral:
		veins.set_material(_material(ore))
		veins.commit(mesh)
	return mesh

func _rock(st: SurfaceTool, veins: SurfaceTool, at: Vector3, radius: float, height: float, ore: String) -> void:
	var rings: Array = []
	var color := Color("a5a59a") if ore == "" else Color("9fa397")
	for band in 3:
		var row: Array[Vector3] = []
		for side in 8:
			var angle := side * TAU / 8 + .1 * band
			var r: float = radius * _rng.randf_range(.83, 1.0) * [.88, 1.0, .65][band]
			var y: float = height * [0.0, .35, .78][band] + (0.0 if band == 0 else height * _rng.randf_range(-.05, .05))
			row.append(at + Vector3(cos(angle) * r + band * .018, y, sin(angle) * r * .83))
		rings.append(row)
	var tip := at + Vector3(radius * .13, height, -.04)
	for side in 8:
		var next := (side + 1) % 8
		for band in 2:
			var a: Vector3 = rings[band][side]
			var b: Vector3 = rings[band][next]
			var c: Vector3 = rings[band + 1][side]
			var d: Vector3 = rings[band + 1][next]
			_triangle(st, a, c, b, color.lightened(_rng.randf_range(-.06, .07)))
			_triangle(st, b, c, d, color.lightened(_rng.randf_range(-.06, .07)))
			if ore != "":
				_vein(veins, a, c, b, Color(ORE_COLORS[ore]), side, band)
				_vein(veins, b, c, d, Color(ORE_COLORS[ore]), side + 1, band)
		_triangle(st, rings[2][side], tip, rings[2][next], color.lightened(.06))
		if ore != "": _vein(veins, rings[2][side], tip, rings[2][next], Color(ORE_COLORS[ore]), side, 2)

func _vein(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color, side: int, band: int) -> void:
	if (side + band) % 3 == 0: return
	var normal := (b - a).cross(c - a).normalized() * .003
	# A narrow broken vein follows the stone's facets, rather than painting
	# the whole outcrop a saturated metal colour or emitting light.
	var start := a.lerp(c, .12) + normal
	var end := b.lerp(c, .16) + normal
	var edge := c.lerp((a + b) * .5, .32) + normal
	_triangle(st, start, end, edge, color)

func _triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	a.y = maxf(0, a.y)
	b.y = maxf(0, b.y)
	c.y = maxf(0, c.y)
	st.set_normal((b - a).cross(c - a).normalized())
	st.set_color(color.srgb_to_linear())
	for p: Vector3 in [a, c, b]: st.add_vertex(p)  # Godot's front face is clockwise.

func _material(kind: String) -> StandardMaterial3D:
	if _materials.has(kind): return _materials[kind]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = .96 if kind == "stone" else .64
	m.metallic = .18 if kind in ["silver", "gold"] else 0.0
	_materials[kind] = m
	return m
