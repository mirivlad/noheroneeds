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
		# The land stands where the generator puts it (ADR-0061), the same on server and client.
		check(is_equal_approx(view.terrain.cell(cell), view._land.metres_at(cell.x, cell.y)), "same original geography")
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
	check(view.camera_input(wheel), "the wheel zooms (it no longer turns the quick slots)")
	check(view.zoom < 19, "zoom moved")

func test_a_blow_turns_the_doll_and_it_stays_turned() -> void:
	var actor := BillboardActor3D.new()
	var looks := {"body_plan": "base:human_ro_m", "styles": {}, "worn": {}}
	actor.setup(content, content.visual_of("base:human_ro_m"), looks, {})
	view.space.add_child(actor)
	actor.show_actor(Vector3.ZERO, 0.0, 0.1, true)
	actor.show_actor(Vector3(0, 0, 1), 0.0, 0.1, true)  # walked south: faces the viewer
	eq((actor.doll as RoSprite)._row, 0, "facing south after the walk")
	actor.swing(Vector2.RIGHT, "chop", 0.0)
	for i in 5:
		actor.show_actor(Vector3(0, 0, 1), 0.0, 0.1, true)
	eq((actor.doll as RoSprite)._row, 2, "the blow east turned it east, and frames after keep it")
	actor.queue_free()

func test_the_house_one_is_in_is_cut_away() -> void:
	var at := Transform3D(Basis.IDENTITY, Vector3(2.5, 1, 2.5))
	var roof := [Vector2i(2, 2), true]
	var wall := [Vector2i(2, 2), false]
	view._cut = Rect2i(1, 1, 3, 3)
	check(view.cut_transform(at, roof).basis.get_scale().is_zero_approx(), "the roof over one is not drawn")
	check(is_equal_approx(view.cut_transform(at, wall).basis.get_scale().y, 1.0 / 6.0), "the wall stands a sixth high")
	eq(view.cut_transform(at, wall).origin, at.origin, "on its foot")
	eq(view.cut_transform(at, [Vector2i(9, 9), false]), at, "another house stays whole")
	eq(view.cut_transform(at, []), at, "not a house part: as laid")
	view._cut = Rect2i()
	eq(view.cut_transform(at, roof), at, "outdoors again: whole")

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

func test_real_mountain_route_is_levels_cliffs_and_ramps() -> void:
	var at := Vector2i(-231, 816)
	for cy in range(floori((at.y - 26) / 32.0), floori((at.y + 26) / 32.0) + 1):
		for cx in range(floori((at.x - 26) / 32.0), floori((at.x + 26) / 32.0) + 1):
			client.chunks[ServerWorld.chunk_key("surface", cx, cy)] = view._land.generate(cx, cy)
	view.terrain = null
	var low := INF
	var high := -INF
	var steepest := 0.0
	var cliffs := 0
	for y in range(at.y - 24, at.y + 25):
		for x in range(at.x - 24, at.x + 25):
			var cell := Vector2i(x, y)
			var h := view.corner_height(cell)
			low = minf(low, h)
			high = maxf(high, h)
			if view._rock_at(cell):
				cliffs += 1 if view.terrain.cell(cell) - view.terrain.low(cell + Vector2i.ONE) > 2 else 0
				continue
			# a walkable cell's own corners: a ramp at most, never a sheer step
			for d: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN]:
				steepest = maxf(steepest, absf(view.corner_height(cell + d) - h))
	check(high - low > 8, "the mountain rises in levels: %.1f m" % (high - low))
	check(cliffs > 0, "and drops in cliffs on rock cells: %d" % cliffs)
	check(steepest < SurfaceGenerator.LEVEL_METRES, "walkable ground is ramps, not sheer: %.2f m a cell" % steepest)
	var chunk: Chunk = client.chunks[ServerWorld.chunk_key("surface", floori(at.x/32.0), floori(at.y/32.0))]
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

func test_level_ground_and_cliffs() -> void:
	# A corner stands at the walkable cells round it: a level is flat up to its cliff.
	view.terrain = TerrainShape3D.new(view._land, func(p: Vector2i) -> bool: return p.x == 0)
	view.terrain._cells = {Vector2i(-1, -1): 6.0, Vector2i(-1, 0): 6.0, Vector2i(0, -1): 6.0, Vector2i(0, 0): 6.0,
		Vector2i(1, -1): 3.0, Vector2i(1, 0): 3.0}
	check(is_equal_approx(view.terrain.height(Vector2i(0, 0)), 6.0), "the upper level's corner, beside the cliff cell")
	check(is_equal_approx(view.terrain.height(Vector2i(1, 0)), 3.0), "the lower level's corner, on the other side")
	check(is_equal_approx(view.terrain.low(Vector2i(1, 0)), 3.0), "the cliff's face reaches down to the lower level")
	# The cliff cell is flush with the level it bounds and drops sheer to the ground below.
	var cliff := RockCells3D.mesh(Vector2i.ZERO, 6.0, func(_p: Vector2i) -> float: return 3.0,
		func(_p: Vector2i) -> bool: return false, func(p: Vector2i) -> bool: return p.x < 0, view.buildings.stone)
	var bounds := cliff.get_aabb()
	check(is_equal_approx(bounds.end.y, 6.05) and is_equal_approx(bounds.position.y, 3.0), "flush top, face down to the lower level: %s" % bounds)

func test_natural_rock_shared_edges_and_no_brick_gaps() -> void:
	var c := Vector2i(5,8)
	var none := func(_p: Vector2i) -> bool: return false
	var ground := func(_p: Vector2i) -> float: return 0.0
	var a := RockCells3D.mesh(c, 0.0, ground, none, none, view.buildings.stone)
	var b := RockCells3D.mesh(c+Vector2i.RIGHT, 0.0, ground, none, none, view.buildings.stone)
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

func test_decks_clear_the_substrate_and_bridge_feet_match_top_triangles() -> void:
	var c := Chunk.new()
	c.set_cell("ground",0,0,"base:bridge")
	client.chunks["surface|0|0"] = c
	var at := Vector2(.25,.25)
	check(absf(view.elevation(at)-view.surface_elevation(at)-.18)<.0001,"bridge feet stand above water level")
	var mesh := view.bridge_mesh(Vector2i.ZERO)
	var vertices := mesh.get_faces()
	for i in [0,1,2,3,4,5]:
		var p := vertices[i]
		var expected := view.corner_height(Vector2i(roundi(p.x+.5),roundi(p.z+.5)))
		check(absf(p.y+view.surface_elevation(Vector2(.5,.5))-expected)<.0001,"deck top has the same original terrain vertices")
	view._queued["surface|0|0"] = true
	view._begin_chunk(Vector2i.ZERO)
	for i in 32: view._build_row()
	var root:Node = view._geometry["surface|0|0"]
	var ground := root.get_child(0) as MeshInstance3D
	for p:Vector3 in ground.mesh.get_faces():
		check(p.y < view.corner_height(Vector2i(roundi(p.x),roundi(p.z)))-.13,"substrate is below decking, no coplanar green stripes")

func test_one_hurt_shows_a_bar_and_the_damage() -> void:
	var actor := BillboardActor3D.new()
	actor.setup(content, content.visual_of("base:human_ro_m"), {"body_plan": "base:human_ro_m"}, {})
	view.space.add_child(actor)
	view._health_bar(actor, 3, 10)
	var bar := actor.get_node_or_null("Health") as Sprite3D
	check(bar != null, "a bar over one hurt")
	eq(int(bar.get_meta("filled")), 4, "three tenths of fourteen, rounded")
	check(bar.texture.get_image().get_pixel(0, 0).is_equal_approx(Color8(216, 63, 51)), "its left part red")
	view._health_bar(actor, 10, 10)
	check(bar.is_queued_for_deletion(), "whole again: no bar")
	var labels := view.space.get_children().filter(func(n: Node) -> bool: return n is Label3D).size()
	view.popup_at(Vector2(32, 32), "−3", Color.RED)
	eq(view.space.get_children().filter(func(n: Node) -> bool: return n is Label3D).size(), labels + 1, "the damage floats up")
	view.burst_at(Vector2(32, 32), "blood")
	check(view.space.get_children().any(func(n: Node) -> bool: return n is CPUParticles3D and n.one_shot), "and blood flies")
	actor.queue_free()

func test_fires_give_off_and_bursts_end() -> void:
	for kind: String in ["sparks", "embers", "smoke"]:
		var p := Effects3D.of(kind)
		check(p != null and not p.one_shot, "%s keeps coming" % kind)
		p.free()
	for kind: String in ["chips", "blood", "dust", "splash"]:
		var p := Effects3D.burst(kind, Color.BROWN)
		check(p != null and p.one_shot and p.emitting, "%s is a burst" % kind)
		p.free()
	check(Effects3D.of("nothing") == null and Effects3D.burst("nothing") == null, "unknown: nothing")

func test_crops_grow_by_the_clock() -> void:
	var wheat := content.get_def("base:wheat_crop")
	client.world_time = 100.0 * Daylight.HOUR_MS
	eq(view._crop_stage(wheat, client.world_time, Vector2i(5, 5)), 0, "just sown")
	eq(view._crop_stage(wheat, client.world_time - 60.0 * Daylight.HOUR_MS, Vector2i(5, 5)), 3, "ripe after its hours")

func test_life_over_the_land() -> void:
	var at := PackedVector3Array([Vector3(1, 0, 1), Vector3(5, 2, 3)])
	for kind: String in ["fireflies", "mist", "drift", "leaves"]:
		var p := Effects3D.ambient(kind, at)
		check(p != null and p.emission_points.size() == 2 and p.emission_points[1].y > 2.0, "%s over its cells, lifted" % kind)
		p.free()
	check(Effects3D.ambient("fireflies", PackedVector3Array()) == null, "nowhere: nothing")
	check(Effects3D.ambient("nothing", at) == null, "unknown: nothing")
