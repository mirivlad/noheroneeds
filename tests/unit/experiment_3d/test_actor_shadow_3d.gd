extends TestCase

func test_shadow_follows_the_supporting_slope_at_every_vertex() -> void:
	var shadow := ActorShadow3D.new()
	shadow.fit(BodySize.parse("horse", {"half":[.6,.3]}, PackedStringArray()))
	var at := Vector3(12, 8, 17)
	var sample := func(p: Vector2) -> float: return 8.0 + (p.x-12)*.5 - (p.y-17)*.25
	for size: float in [1.0,.6]:
		for heading: Vector2 in [Vector2.DOWN,Vector2.RIGHT,Vector2(1,1).normalized()]:
			shadow.follow(at,heading,size,sample)
			var vertices: PackedVector3Array = shadow.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			eq(vertices.size(),72,"the footprint is a bounded triangle fan")
			for v: Vector3 in vertices:
				var world: Vector3 = at+v*size
				check(is_equal_approx(world.y,float(sample.call(Vector2(world.x,world.z)))+.055),"shadow follows slope including young-body scaling")
	shadow.free()

func test_shadow_changes_with_body_size_and_world_heading() -> void:
	var shadow := ActorShadow3D.new()
	shadow.fit(BodySize.HUMAN)
	var human := shadow.radii
	shadow.fit(BodySize.parse("horse", {"half":[.6,.3]}, PackedStringArray()))
	check(shadow.radii.x>human.x and shadow.radii.y>human.y,"a horse has a larger footprint than a person")
	shadow.follow(Vector3.ZERO,Vector2.DOWN,1,func(_p: Vector2) -> float: return 0)
	var first := shadow.mesh.get_aabb().size
	shadow.follow(Vector3.ZERO,Vector2.RIGHT,1,func(_p: Vector2) -> float: return 0)
	var turned := shadow.mesh.get_aabb().size
	check(is_equal_approx(first.x,turned.z) and is_equal_approx(first.z,turned.x),"the ellipse turns in the ground plane, independently of camera yaw")
	eq(shadow.cast_shadow,GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"the contact mark does not cast another shadow")
	shadow.free()
