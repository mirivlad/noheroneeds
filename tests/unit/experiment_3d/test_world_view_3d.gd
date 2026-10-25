extends TestCase
## Adapter contracts: same land sample, shared edges, feet on triangles,
## camera-relative input, original layered sprites and opaque covers.
var view: WorldView3D
var client: GameClient
var content: ContentRegistry

func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	var net := MemoryTransport.MemoryNetwork.new()
	client = GameClient.new(net.client(), PlayerIdentity.load_or_create(tmp_dir().path_join("owner")), PackedByteArray(), content)
	client.geography = Geography.of(431)
	client.location = "surface"
	view = WorldView3D.new()
	view.setup(content, client)
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	view._land = SurfaceGenerator.new(431, content)

func after_each() -> void:
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame

func test_height_is_original_surface_sampler_and_has_shared_edges() -> void:
	for cell: Vector2i in [Vector2i(0, 0), Vector2i(32, 31), Vector2i(-32, -1), Vector2i(100, 180)]:
		var expected := view.corner_height(cell)
		check(is_equal_approx(view.elevation(Vector2(cell)), expected), "either chunk's corner agrees")
		# The fine detail no longer grows into cliffs with the macro relief.
		var macro := view._land.geography.sample(Geography.HEIGHT, cell.x, cell.y)
		var detail := float(view._land.land_at(cell.x, cell.y)["height"]) - macro
		check(is_equal_approx(view.terrain.natural(cell), macro * TerrainShape3D.RELIEF + detail * TerrainShape3D.GRAIN), "same original geography and grain")
	var at := Vector2(31.25, -32.5)
	var cell := Vector2i(floori(at.x), floori(at.y))
	var a := view.corner_height(cell)
	var b := view.corner_height(cell + Vector2i.RIGHT)
	var c := view.corner_height(cell + Vector2i.DOWN)
	check(is_equal_approx(view.elevation(at), a + .25 * (b - a) + .5 * (c - a)), "foot uses rendered triangle")
	client.z = -1
	eq(view.elevation(at), 0.0, "depth has its own plane, not surface geography")

func test_camera_direction_agrees_with_camera_basis_for_full_rotation() -> void:
	for step in 16:
		view.yaw = step * TAU / 16
		view.eye.position = Vector3(0, 60, 40).rotated(Vector3.UP, -view.yaw)
		view.eye.look_at(Vector3.ZERO)
		var right := view.eye.basis.x
		var down := Vector3(-right.z, 0, right.x)
		for screen: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
			var actual := view.world_direction(screen)
			var expected := right * screen.x + down * screen.y
			check(Vector2(actual).normalized().dot(Vector2(expected.x, expected.z).normalized()) > .9, "discrete movement follows screen at %d" % step)

func test_model_bounds_use_content_mapping_and_no_asset_is_missing() -> void:
	for id: String in view.models.catalog:
		var m := view.models.mesh_for(id, content.get_def(id))
		check(m != null and m.get_surface_count() > 0, "model loaded: " + id)
		check(absf(m.get_aabb().position.y) < .001, "model has its foot at zero: " + id)

func test_camera_settings_survive_reload_and_ordinary_wheel_is_preserved() -> void:
	var settings := GameSettings.new()
	settings.path = tmp_dir().path_join("settings.cfg")
	view.configure_camera(settings)
	view.yaw = 1.2
	view.tilt = 43
	view.zoom = 19
	view._save_camera()
	view.configure_camera(GameSettings.load_from(settings.path))
	eq(view.yaw, 1.2)
	eq(view.tilt, 43.0)
	eq(view.zoom, 19.0)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	check(not view.camera_input(wheel), "ordinary wheel continues to choose hotbar slot")
	wheel.ctrl_pressed = true
	check(view.camera_input(wheel), "Ctrl wheel zooms")
	check(view.zoom < 19, "zoom moved")

func test_lpc_paper_doll_and_equipment_are_reused() -> void:
	var actor := BillboardActor3D.new()
	var looks := {"body_plan": "base:human_m", "styles": CharacterLibrary.STYLE_DEFAULTS.duplicate(), "worn": {"torso": "base:linen_shirt"}}
	actor.setup(content, content.visual_of("base:human_m"), looks, {})
	view.space.add_child(actor)
	check(actor.doll is LpcSprite, "actual LPC animation implementation")
	check(actor.viewport.transparent_bg, "transparent composition")
	actor.doll.hold(view.item_picture("base:axe"), view.item_grip("base:axe"), "base:axe")
	check(actor.doll._held_layers.size() > 0, "real axe animation layers")
	actor.show_actor(Vector3(3, 2, 1), 0, .05, true)
	eq(actor.position, Vector3(3, 2, 1))
	actor.show_actor(Vector3(4, 2, 1), PI / 2, .05, true)
	eq(actor.doll._dir, 0, "world east seen north from rotated camera")
	# Remote entities only get a new target on snapshots. Their smoothed
	# movement must keep the walk cycle playing between those snapshots.
	for i in 10:
		actor.show_actor(Vector3(10, 2, 1), 0, .016, false)
	check(actor.doll._walk > .1, "remote walk continues between snapshots")

func test_ray_uses_viewports_actual_world_and_content_cells_after_rotation() -> void:
	var chunk := Chunk.new()
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			chunk.set_cell("ground", x, y, "base:grass")
	chunk.set_cell("cover", 10, 10, "base:oak")
	chunk.set_cell("structure", 13, 10, "base:wood_door")
	client.chunks[ServerWorld.chunk_key("surface", 0, 0)] = chunk
	client.changed_chunks = ["*"]
	client.position = Vector2i(12, 15) * Movement.UNIT
	client.previous_position = client.position
	client.has_position = true
	client.character_id = "own-ray-test"
	for i in 120:
		view.update_view(1, .016)
		if view._geometry.size() > 0 and view.pending_chunks() == 0:
			break
	await (Engine.get_main_loop() as SceneTree).physics_frame
	await (Engine.get_main_loop() as SceneTree).physics_frame
	for yaw: float in [0.0, .6, PI / 2, PI]:
		view.yaw = yaw
		view.update_view(1, .016)
		for target: Array in [[Vector2i(10, 10), "base:oak", 2.0], [Vector2i(13, 10), "base:wood_door", 1.0]]:
			var cell: Vector2i = target[0]
			var at := Vector2(cell) + Vector2.ONE * .5
			var p := Vector3(at.x, view.elevation(at) + float(target[2]), at.y)
			var pixel := view.screen_point(view.eye.unproject_position(p))
			var hit := view.pick_target(pixel)
			# From the west the tree stands in front of the door. Picking
			# must obey depth instead of allowing actions through its crown.
			var occluded: bool = is_equal_approx(yaw, PI / 2) and target[1] == "base:wood_door"
			eq(hit.get("cell"), Vector2i(10, 10) if occluded else cell, "visible cell under 3D ray at yaw %f" % yaw)
			eq(hit.get("id"), "base:oak" if occluded else target[1], "frontmost content under ray")

func test_real_mountain_route_is_volumetric_and_walkable_without_visual_cliffs() -> void:
	var at := Vector2i(-231, 816)
	var low := INF
	var high := -INF
	var max_step := 0.0
	for y in range(at.y - 24, at.y + 25):
		for x in range(at.x - 24, at.x + 25):
			var h := view.corner_height(Vector2i(x,y))
			low = minf(low,h)
			high = maxf(high,h)
			max_step = maxf(max_step, absf(h - view.corner_height(Vector2i(x+1,y))))
	check(high - low > 25, "real mountain spans over 25 human-scale metres, old span was 5.84")
	check(max_step < 1, "passable underlying triangles are ramps, not vertical cliffs")
	var chunk := view._land.generate(floori(at.x/32.0), floori(at.y/32.0))
	eq(chunk.get_cell("ground", posmod(at.x,32), posmod(at.y,32)), "base:dirt", "actual original mountain road")
	eq(chunk.get_cell("structure", posmod(at.x,32), posmod(at.y,32)), "", "road has no server rock obstruction")

func test_house_platform_joints_and_door_hinge() -> void:
	var rect: Rect2i = view._land.settlements.home_plan()["homes"][0]["rect"]
	var h := view.corner_height(rect.position)
	for corner: Vector2i in [rect.position, rect.end, Vector2i(rect.position.x,rect.end.y), Vector2i(rect.end.x,rect.position.y)]:
		check(is_equal_approx(view.corner_height(corner),h), "level house foundation including chunk boundary")
	var corner := view.buildings.wall(9).get_aabb()
	check(corner.size.x >= .5 and corner.size.z >= .5, "corner has two connected arms")
	var closed := view.buildings.opening(false,false).get_aabb()
	var opened := view.buildings.opening(false,true).get_aabb()
	check(closed.size.x > .9 and closed.size.z < .3, "closed leaf lies inside frame")
	check(opened.end.z > .7 and opened.position.x < -.4, "open leaf rotates around left jamb")

func test_roof_patches_share_ridge_and_preserve_removed_cell() -> void:
	var rect := Rect2i(0,0,5,4)
	var a := view.buildings.roof(Vector2i(1,1),rect)
	var b := view.buildings.roof(Vector2i(2,1),rect)
	for mesh:Mesh in [a,b,view.buildings.roof(Vector2i(2,2),rect)]:
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var vertices:PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals:PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for i in range(0,vertices.size(),3):
				var normal := (vertices[i+2]-vertices[i]).cross(vertices[i+1]-vertices[i]).normalized()
				check(normal.dot(normals[i])>.99,"roof/gable winding faces outward at both ends")
	check(a.get_aabb().end.x <= .5001, "patch stops at next live roof cell")
	check(b.get_aabb().position.x >= -.5001, "neighbor begins at shared edge")
	check(view.buildings._roof_height(2,rect) == view.buildings._roof_height(3,rect), "symmetrical stable ridge")
	# Roof is instantiated per server tile, so deleting one cannot be filled
	# by a grouped prefab over its surviving neighbours.
	var c := Chunk.new()
	c.set_cell("ground",1,1,"base:wood_floor")
	c.set_cell("roof",1,1,"base:thatch_roof")
	client.chunks[ServerWorld.chunk_key("surface",0,0)] = c
	eq(view._cell_layer(Vector2i(2,1),"roof"),"", "removed roof stays absent in source adapter")

func test_natural_rock_shared_edges_and_no_brick_gaps() -> void:
	var c := Vector2i(5,8)
	var a := RockCells3D.mesh(c, func(_p:Vector2i)->float:return 0, func(_p:Vector2i)->bool:return false, view.buildings.stone)
	var b := RockCells3D.mesh(c+Vector2i.RIGHT, func(_p:Vector2i)->float:return 0, func(_p:Vector2i)->bool:return false, view.buildings.stone)
	check(a.get_aabb().size.x == 1 and b.get_aabb().size.x == 1, "blocked rock occupies exact cell width")
	check(RockCells3D.top(c) != RockCells3D.top(c+Vector2i.RIGHT), "natural uneven cap")
	var va := a.get_faces()
	var vb := b.get_faces()
	var shared := 0
	for v:Vector3 in va:
		if absf(v.x-.5) < .001:
			for w:Vector3 in vb:
				if (v - (w+Vector3.RIGHT)).length() < .001: shared += 1
	check(shared >= 2,"adjacent caps share exact world vertices")
