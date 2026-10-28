class_name Effects3D
## Small things given off in the 3D world (presentation only): sparks and smoke
## over a fire, embers of a torch, and short bursts — chips off a blow, dust,
## a splash, blood. Light particles on the CPU, a few centimetres each, facing
## the camera. Speeds in metres a second (a cell is a metre).

static var _dot: QuadMesh
static var _puff: QuadMesh
static var _mist: QuadMesh
static var _glow: QuadMesh
static var _flame: QuadMesh


## A thing that keeps giving off (sparks, smoke, embers); null if unknown.
static func of(kind: String) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	match kind:
		"sparks":
			p.amount = 10
			p.lifetime = 0.9
			p.mesh = _dot_mesh()
			_rise(p, .12, 25.0, .75, 1.5, Vector3(0, .5, 0))
			p.color_ramp = _ramp(Color(1, 0.85, 0.35, 1), Color(1, 0.35, 0.1, 0))
		"embers":
			p.amount = 4
			p.lifetime = 0.7
			p.mesh = _dot_mesh()
			_rise(p, .06, 30.0, .4, .75, Vector3(0, .4, 0))
			p.color_ramp = _ramp(Color(1, 0.8, 0.35, 1), Color(1, 0.3, 0.1, 0))
		"flames":
			p.amount = 16
			p.lifetime = 0.6
			p.mesh = _flame_mesh()
			_rise(p, .12, 12.0, .4, .8, Vector3(0, .6, 0))
			p.scale_amount_min = 0.7
			p.scale_amount_max = 1.2
			p.scale_amount_curve = _shrink()
			p.color_ramp = _ramp3(Color(1, 0.9, 0.5, 0.9), Color(1, 0.55, 0.15, 0.8), Color(0.9, 0.25, 0.05, 0))
		"smoke":
			p.amount = 12
			p.lifetime = 2.6
			p.mesh = _puff_mesh()
			_rise(p, .1, 15.0, .3, .55, Vector3(.12, .2, 0))
			p.scale_amount_min = 0.6
			p.scale_amount_max = 1.0
			p.scale_amount_curve = _grow()
			p.color_ramp = _ramp(Color(0.32, 0.3, 0.3, 0.5), Color(0.55, 0.55, 0.55, 0))
		_:
			p.free()
			return null
	p.preprocess = p.lifetime  # already going when it comes into sight
	return p


## A short burst: "chips" (wood or stone flying off a blow, in `tint`),
## "dust", "splash", "blood". Frees itself when done.
static func burst(kind: String, tint := Color.WHITE) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.mesh = _dot_mesh()
	match kind:
		"chips":
			p.amount = 7
			p.lifetime = 0.45
			_spray(p, 90.0, 1.8, 3.4, Vector3(0, -10, 0))
			p.color_ramp = _ramp(tint, Color(tint, 0))
		"blood":
			p.amount = 8
			p.lifetime = 0.4
			_spray(p, 70.0, 1.5, 3.0, Vector3(0, -11, 0))
			p.color_ramp = _ramp(Color(0.75, 0.08, 0.1), Color(0.5, 0.05, 0.05, 0))
		"dust":
			p.amount = 6
			p.lifetime = 0.5
			p.mesh = _puff_mesh()
			_spray(p, 180.0, .4, .9, Vector3(0, .4, 0))
			p.scale_amount_min = 0.5
			p.scale_amount_max = 0.8
			p.color_ramp = _ramp(Color(0.6, 0.52, 0.4, 0.55), Color(0.6, 0.52, 0.4, 0))
		"splash":
			p.amount = 10
			p.lifetime = 0.5
			_spray(p, 50.0, 1.5, 2.8, Vector3(0, -9, 0))
			p.color_ramp = _ramp(Color(0.75, 0.88, 1.0), Color(0.6, 0.8, 1.0, 0))
		_:
			p.free()
			return null
	p.emitting = true
	p.finished.connect(p.queue_free)
	return p


## Life over the land at `points` (each a cell's foot): "fireflies" blinking
## about chest high, "mist" lying low, "drift" (snow blown along the ground),
## "leaves" falling from a crown. Null if unknown or nowhere.
static func ambient(kind: String, points: PackedVector3Array) -> CPUParticles3D:
	if points.is_empty():
		return null
	var p := CPUParticles3D.new()
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINTS
	p.mesh = _dot_mesh()
	var lift := Vector3.ZERO
	match kind:
		"fireflies":
			p.amount = clampi(points.size() / 2, 1, 32)
			p.lifetime = 3.0
			p.mesh = _glow_mesh()
			lift = Vector3(0, .9, 0)
			_spray(p, 180.0, .1, .3, Vector3.ZERO)
			p.color_ramp = _ramp3(Color(0.92, 1.0, 0.6, 0), Color(0.92, 1.0, 0.6, 1), Color(0.85, 1.0, 0.45, 0))
		"mist":
			p.amount = clampi(points.size(), 1, 24)
			p.lifetime = 8.0
			p.mesh = _mist_mesh()
			lift = Vector3(0, .3, 0)
			_spray(p, 10.0, .1, .25, Vector3.ZERO)
			p.direction = Vector3.RIGHT
			p.color_ramp = _ramp3(Color(0.82, 0.88, 0.85, 0), Color(0.82, 0.88, 0.85, 0.22), Color(0.82, 0.88, 0.85, 0))
		"drift":
			p.amount = clampi(points.size(), 1, 24)
			p.lifetime = 1.6
			lift = Vector3(0, .08, 0)
			_spray(p, 8.0, 1.6, 2.4, Vector3.ZERO)
			p.direction = Vector3.RIGHT
			p.color_ramp = _ramp(Color(1, 1, 1, 0.6), Color(1, 1, 1, 0))
		"leaves":
			p.amount = clampi(points.size() * 2, 1, 24)
			p.lifetime = 2.5
			lift = Vector3(0, 2.6, 0)
			_spray(p, 60.0, .2, .4, Vector3(.2, -.8, 0))
			p.direction = Vector3.DOWN
			p.color_ramp = _ramp3(Color(0.95, 0.6, 0.15, 0.9), Color(0.95, 0.5, 0.15, 0.9), Color(0.9, 0.45, 0.15, 0))
		_:
			p.free()
			return null
	var lifted := PackedVector3Array()
	for at: Vector3 in points:
		lifted.append(at + lift)
	p.emission_points = lifted
	p.preprocess = p.lifetime
	return p


static func _rise(p: CPUParticles3D, radius: float, spread: float, v0: float, v1: float, gravity: Vector3) -> void:
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = radius
	p.direction = Vector3.UP
	p.spread = spread
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.gravity = gravity


static func _spray(p: CPUParticles3D, spread: float, v0: float, v1: float, gravity: Vector3) -> void:
	p.direction = Vector3.UP
	p.spread = spread
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.gravity = gravity


static func _ramp(a: Color, b: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, a)
	g.set_color(1, b)
	return g


static func _ramp3(a: Color, b: Color, c: Color) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([a, b, c])
	return g


static func _shrink() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 1.0))
	c.add_point(Vector2(1, 0.3))
	return c


static func _grow() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0.5))
	c.add_point(Vector2(1, 1.0))
	return c


## A square fleck, 6 cm, unlit, coloured by the particle.
static func _dot_mesh() -> QuadMesh:
	if _dot == null:
		_dot = _quad(.06, null)
	return _dot


## A soft round puff, 40 cm (smoke, dust).
static func _puff_mesh() -> QuadMesh:
	if _puff == null:
		var t := GradientTexture2D.new()
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 32
		t.height = 32
		t.gradient = _ramp(Color(1, 1, 1, 1), Color(1, 1, 1, 0))
		_puff = _quad(.4, t)
	return _puff


## A wide soft patch, 2.5 m (mist lying on a bog).
static func _mist_mesh() -> QuadMesh:
	if _mist == null:
		_mist = _quad(2.5, (_puff_mesh().material as StandardMaterial3D).albedo_texture)
	return _mist


## A small glowing point, 25 cm of soft light added to what is behind (fireflies).
static func _glow_mesh() -> QuadMesh:
	if _glow == null:
		_glow = _quad(.25, (_puff_mesh().material as StandardMaterial3D).albedo_texture)
		(_glow.material as StandardMaterial3D).blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return _glow


## A tongue of flame: a soft patch of light added to what is behind, 30 cm.
static func _flame_mesh() -> QuadMesh:
	if _flame == null:
		_flame = _quad(.3, (_puff_mesh().material as StandardMaterial3D).albedo_texture)
		(_flame.material as StandardMaterial3D).blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return _flame


static func _quad(size: float, texture: Texture2D) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = texture
	q.material = m
	return q
