class_name PlantMeshes3D
extends RefCounted
## Small authored silhouettes, cached by ModelLibrary3D. No world data or RNG is changed.
const SPECIES := ["tall_grass", "clover", "reeds", "cattail", "wheat_crop", "carrot_crop"]
const VARIANTS := 6
const SHRUBS := ["base:bush", "base:berry_bush", "base:dry_bush"]
const SHRUB_VARIANTS := 4
var _st: SurfaceTool
var _rng := RandomNumberGenerator.new()

static func supports(id: String) -> bool:
	return (id.trim_prefix("base:") in SPECIES and id.begins_with("base:")) or id in SHRUBS

static func variant_at(id: String, cell: Vector2i) -> int:
	return posmod(hash(["shrub" if id in SHRUBS else id, cell.x, cell.y, 7183]), SHRUB_VARIANTS if id in SHRUBS else VARIANTS)

func build(id: String, variant: int) -> ArrayMesh:
	_rng.seed = hash(["shrub" if id in SHRUBS else id, variant, 9421])
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if id in SHRUBS:
		shrub(id, variant)
		_st.generate_normals()
		return _st.commit()
	var species := id.trim_prefix("base:")
	var count := 5 + variant % 3
	if species == "clover": count = 9 + variant
	if species == "carrot_crop": count = 8
	for i in count:
		var angle := _rng.randf_range(0, TAU)
		var spread := .07 if species == "carrot_crop" else (.12 if species in ["reeds", "cattail"] else .26)
		var radius := sqrt(_rng.randf()) * spread
		var foot := Vector3(cos(angle), 0, sin(angle)) * radius
		var h := _rng.randf_range(.8, 1.15)
		var direction := Vector3(cos(angle), 0, sin(angle))
		match species:
			"tall_grass":
				blade(foot, direction, .32 * h, .045, Color("708548"))
				if i % 2 == 0:
					var tip := foot + Vector3.UP * (.48 * h) + direction * .06
					stem(foot, tip, .009, Color("899151"))
					seed_head(tip, direction, .085, Color("b3a976"))
			"clover":
				var tip := foot + Vector3.UP * (.13 * h)
				stem(foot, tip, .007, Color("5d7943"))
				for leaflet in 3:
					var d := direction.rotated(Vector3.UP, leaflet * TAU / 3)
					leaf(tip, d * .095 + Vector3.UP * .025, .065, Color("608345"))
				if i % 4 == 0: flower(tip + Vector3.UP * .06, Color("b795ac"))
			"reeds", "cattail":
				var tip := foot + Vector3.UP * (.76 * h) + direction * .045
				stem(foot, tip, .013, Color("6e834f"))
				blade(foot, direction, .63 * h, .035, Color("667e48"))
				blade(foot, -direction, .48 * h, .03, Color("81905b"))
				if species == "cattail":
					stem(tip - Vector3.UP * .14, tip + Vector3.UP * .035, .032, Color("70503a"))
				else:
					for branch in 4:
						var end := tip + direction.rotated(Vector3.UP, branch * 2.4) * .09 + Vector3.UP * (.035 * branch)
						stem(tip - Vector3.UP * .04, end, .009, Color("b2aa7d"))
			"wheat_crop":
				var tip := foot + Vector3.UP * (.52 * h) + direction * .035
				stem(foot, tip, .012, Color("ad9b58"))
				blade(foot, direction, .29 * h, .028, Color("8d9350"))
				seed_head(tip, direction, .15, Color("c3ad68"))
			"carrot_crop":
				var tip := foot + Vector3.UP * (.28 * h) + direction * .19
				stem(foot, tip, .008, Color("5e8244"))
				for pair in 4:
					var at := foot.lerp(tip, .25 + pair * .18)
					var side := direction.rotated(Vector3.UP, PI / 2) * (.065 - pair * .009)
					leaf(at, side + Vector3.UP * .028, .018, Color("608648"))
					leaf(at, -side + Vector3.UP * .028, .018, Color("73934e"))
	_st.generate_normals()
	return _st.commit()

func shrub(id: String, variant: int) -> void:
	var dry := id == "base:dry_bush"
	var width: float = [.30, .38, .27, .34][variant]
	var height: float = [.54, .42, .70, .60][variant]
	for branch in 5:
		var angle := branch * TAU / 5 + _rng.randf_range(-.3, .3)
		var direction := Vector3(cos(angle), 0, sin(angle))
		var tip := direction * width * .7 + Vector3.UP * height * _rng.randf_range(.65, 1.0)
		stem(Vector3.ZERO, tip, .018, Color("75614b"))
		for twig in 3:
			var along := direction.rotated(Vector3.UP, (twig - 1) * .8)
			var end := tip + along * .11 + Vector3.UP * (twig * .045)
			stem(tip * .7, end, .009, Color("806a50"))
			if dry:
				leaf(end * .85, along * .08, .035, Color("96866b"))
			else:
				# Overlapping flattened leaf fans give four bush silhouettes,
				# with visible branches and an uneven edge rather than a sphere.
				for cluster in 7:
					var fan := along.rotated(Vector3.UP, cluster * 2.4)
					var centre := end + fan * .055 + Vector3.UP * _rng.randf_range(-.04, .04)
					leaf(centre, fan * .14 + Vector3.UP * .035, .105, Color("5b7949") if cluster % 2 else Color("718953"))
	if not dry:
		# Fill the centre as well as branch tips: from above a bush has a
		# layered crown, not a ring of leaves around an empty stem basket.
		for i in 24:
			var angle := _rng.randf_range(0, TAU)
			var direction := Vector3(cos(angle), 0, sin(angle))
			var centre := direction * _rng.randf_range(0, width * .3) + Vector3.UP * height * _rng.randf_range(.45, .9)
			leaf(centre, direction * .17 + Vector3.UP * .025, .12, Color("6b864e"))
	# Generate fruit separately, after the foliage: the bare and fruitful bush
	# have exactly the same branches, leaves, size, variant and orientation.
	if id == "base:berry_bush":
		for i in 22:
			var angle := i * 2.4
			var at := Vector3(cos(angle), 0, sin(angle)) * width * .91 + Vector3.UP * height * (.55 + .35 * (i % 3) / 2.0)
			berry(at, .035, Color("a54748"))

func berry(at: Vector3, radius: float, color: Color) -> void:
	var top := at + Vector3.UP * radius
	var bottom := at - Vector3.UP * radius
	for i in 5:
		var a := at + Vector3(cos(i * TAU / 5), 0, sin(i * TAU / 5)) * radius
		var b := at + Vector3(cos((i + 1) * TAU / 5), 0, sin((i + 1) * TAU / 5)) * radius
		triangle(top, a, b, color.lightened(.08))
		triangle(bottom, b, a, color)

func decoration(variant: int) -> ArrayMesh:
	_rng.seed = 719 + variant
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 9:
		var angle := _rng.randf_range(0, TAU)
		var direction := Vector3(cos(angle), 0, sin(angle))
		blade(direction * _rng.randf_range(0, .2), direction, _rng.randf_range(.07, .13), .027, Color("748750"))
	_st.generate_normals()
	return _st.commit()

func blade(foot: Vector3, direction: Vector3, height: float, width: float, color: Color) -> void:
	var side := direction.rotated(Vector3.UP, PI / 2) * width
	var middle := foot + Vector3.UP * height * .6 + direction * height * .12
	var tip := foot + Vector3.UP * height * .82 + direction * height * .5
	triangle(foot - side * .35, middle - side * .65, middle + side * .65, color)
	triangle(foot - side * .35, middle + side * .65, foot + side * .35, color)
	triangle(middle - side * .65, tip, middle + side * .65, color.lightened(.07))

func leaf(at: Vector3, along: Vector3, width: float, color: Color) -> void:
	var side := Vector3(-along.z, 0, along.x).normalized() * width * .5
	var middle := at + along * .5 + Vector3.UP * .008
	triangle(at, middle - side, at + along, color)
	triangle(at, at + along, middle + side, color.lightened(.06))

func stem(a: Vector3, b: Vector3, radius: float, color: Color) -> void:
	var direction := (b - a).normalized()
	var u := direction.cross(Vector3.RIGHT if absf(direction.y) > .9 else Vector3.UP).normalized() * radius
	var v := direction.cross(u)
	for i in 4:
		var p := u * cos(i * TAU / 4) + v * sin(i * TAU / 4)
		var q := u * cos((i + 1) * TAU / 4) + v * sin((i + 1) * TAU / 4)
		triangle(a + p, b + p, a + q, color)
		triangle(a + q, b + p, b + q, color)
	triangle(b + u, b + v, b - u, color)
	triangle(b - u, b + v, b - v, color)

func seed_head(at: Vector3, direction: Vector3, height: float, color: Color) -> void:
	for i in 5:
		var p := at + Vector3.UP * height * i / 5.0
		var side := direction * .028 * (1.0 - i * .12)
		leaf(p, side + Vector3.UP * height * .38, .028, color)
		leaf(p, -side + Vector3.UP * height * .38, .028, color)

func flower(at: Vector3, color: Color) -> void:
	for i in 5:
		var direction := Vector3(cos(i * TAU / 5), .25, sin(i * TAU / 5))
		leaf(at, direction * .035, .04, color)

func triangle(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	# Palette swatches are sRGB; spatial shader vertex colours are linear.
	_st.set_color(color.srgb_to_linear())
	for p: Vector3 in [a, b, c]: _st.add_vertex(Vector3(p.x, maxf(0, p.y), p.z))
