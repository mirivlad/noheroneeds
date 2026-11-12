extends TestCase

func test_both_ends_remain_attached_under_wagon_rotation_and_inclination() -> void:
	var wagon := Node3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(wagon)
	wagon.position = Vector3(12,3,8)
	wagon.rotation.y = .7
	var harness := CaravanHarness3D.new()
	wagon.add_child(harness)
	harness.setup(wagon)
	for end: Vector3 in [Vector3(8,4,5),Vector3(15,5,10),Vector3(10,4,14)]:
		var start := wagon.to_global(Vector3(.43,.53,-.25))
		var beam := harness.shafts[0]
		harness._place(beam,start,end,.10)
		var a := beam.to_global(Vector3(0,0,.5))
		var b := beam.to_global(Vector3(0,0,-.5))
		check(a.distance_to(start)<.001 and b.distance_to(end)<.001,"the actual box ends meet the wagon and moving horse")
		check(is_equal_approx(beam.global_basis.x.length(),.1) and is_equal_approx(beam.global_basis.y.length(),.1),"shaft thickness survives rotation")
	wagon.free()
