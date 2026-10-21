class_name Effects
## Small things given off on the screen (presentation only): sparks and smoke
## over a fire, embers of a torch, and short bursts — chips off a blow, dust,
## a splash. Light particles on the CPU: a handful each, a world pixel big.

static var _puff: GradientTexture2D


## A thing that keeps giving off (sparks, smoke, embers); null if unknown.
static func of(kind: String) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.z_index = 6  # over what stands round it
	p.local_coords = false
	match kind:
		"sparks":
			p.amount = 10
			p.lifetime = 0.9
			_rise(p, 3.0, 25.0, 12.0, 24.0, Vector2(0, -8))
			p.color_ramp = _ramp(Color(1, 0.85, 0.35, 1), Color(1, 0.35, 0.1, 0))
		"embers":
			p.amount = 4
			p.lifetime = 0.7
			_rise(p, 1.5, 30.0, 6.0, 12.0, Vector2(0, -6))
			p.color_ramp = _ramp(Color(1, 0.8, 0.35, 1), Color(1, 0.3, 0.1, 0))
		"smoke":
			p.amount = 12
			p.lifetime = 2.6
			p.texture = soft()
			_rise(p, 2.0, 15.0, 5.0, 9.0, Vector2(2, -3))
			p.scale_amount_min = 0.25
			p.scale_amount_max = 0.45
			p.scale_amount_curve = _grow()
			p.color_ramp = _ramp(Color(0.32, 0.3, 0.3, 0.5), Color(0.55, 0.55, 0.55, 0))
		_:
			p.free()
			return null
	p.preprocess = p.lifetime  # already going when it comes into sight
	return p


## A short burst at a point: "chips" (wood or stone flying off a blow, in
## `tint`), "dust", "splash", "blood". Frees itself when done.
static func burst(kind: String, tint := Color.WHITE) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.z_index = 6
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	match kind:
		"chips":
			p.amount = 7
			p.lifetime = 0.45
			_spray(p, 90.0, 30.0, 55.0, Vector2(0, 160))
			p.color_ramp = _ramp(tint, Color(tint, 0))
		"blood":
			p.amount = 8
			p.lifetime = 0.4
			_spray(p, 70.0, 25.0, 50.0, Vector2(0, 180))
			p.color_ramp = _ramp(Color(0.75, 0.08, 0.1), Color(0.5, 0.05, 0.05, 0))
		"dust":
			p.amount = 6
			p.lifetime = 0.5
			p.texture = soft()
			_spray(p, 180.0, 6.0, 14.0, Vector2(0, -6))
			p.scale_amount_min = 0.12
			p.scale_amount_max = 0.2
			p.color_ramp = _ramp(Color(0.6, 0.52, 0.4, 0.55), Color(0.6, 0.52, 0.4, 0))
		"splash":
			p.amount = 10
			p.lifetime = 0.5
			_spray(p, 50.0, 25.0, 45.0, Vector2(0, 150))
			p.color_ramp = _ramp(Color(0.75, 0.88, 1.0), Color(0.6, 0.8, 1.0, 0))
		_:
			p.free()
			return null
	p.emitting = true
	p.finished.connect(p.queue_free)
	return p


static func _rise(p: CPUParticles2D, radius: float, spread: float, v0: float, v1: float, gravity: Vector2) -> void:
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = radius
	p.direction = Vector2.UP
	p.spread = spread
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.gravity = gravity


static func _spray(p: CPUParticles2D, spread: float, v0: float, v1: float, gravity: Vector2) -> void:
	p.direction = Vector2.UP
	p.spread = spread
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.gravity = gravity


static func _ramp(a: Color, b: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, a)
	g.set_color(1, b)
	return g


static func _grow() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0.5))
	c.add_point(Vector2(1, 1.0))
	return c


## A soft round puff, 16 px (smoke, dust).
static func soft() -> GradientTexture2D:
	if _puff == null:
		_puff = GradientTexture2D.new()
		_puff.fill = GradientTexture2D.FILL_RADIAL
		_puff.fill_from = Vector2(0.5, 0.5)
		_puff.fill_to = Vector2(1.0, 0.5)
		_puff.width = 16
		_puff.height = 16
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_puff.gradient = g
	return _puff
