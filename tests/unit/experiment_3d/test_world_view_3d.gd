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

func test_caravan_renders_a_sitting_driver_horse_and_turning_wheels() -> void:
	var looks := {"body_plan": "base:human_ro_m", "styles": {}, "worn": {}}
	client.entities = {
		"driver": {"kind": "creature", "creature": "base:villager", "appearance": looks,
			"profession": "base:trader", "horse": "horse", "caravan_heading": [1, 0], "x": 0, "y": 0},
		"horse": {"kind": "creature", "creature": "base:horse", "caravan_driver": "driver",
			"x": 2 * Movement.UNIT, "y": 0}}
	view._update_actors(1, .1)
	var driver := view._actors["driver"] as BillboardActor3D
	var horse := view._actors["horse"] as BillboardActor3D
	check(driver.cart != null and driver.cart.visible, "the imported Blender cart is shown")
	var wheels := driver.cart.find_children("Wheel*", "Node3D", true, false)
	eq(wheels.size(), 4, "all four wheels are separate nodes")
	eq((driver.doll as RoSprite)._once, "sit", "the driver sits on the bench")
	check(horse.doll is LpcSprite, "the actual horse uses its LPC sprite")
	client.entities["driver"]["x"] = Movement.UNIT
	client.entities["horse"]["x"] = 3 * Movement.UNIT
	view._update_actors(1, .1)
	check(driver.wheel_angle > 0, "the wheels turn when the wagon moves")
	check(absf((wheels[0] as Node3D).rotation.x) > .01, "the model's wheel rotates")
	client.entities["driver"]["asleep"] = true
	view._update_actors(1, .1)
	eq((driver.doll as RoSprite)._once, "dead", "leaving the seated pose does not cancel sleep")
	eq(driver.picture.position, Vector3.ZERO, "the sleeping trader is on the ground beside the cart")
	client.entities["driver"]["asleep"] = false
	client.entities["driver"]["horse"] = ""
	view._update_actors(1, .1)
	check(not driver.cart.visible, "the cart is hidden when the horse is lost")
	eq((driver.doll as RoSprite)._once, "", "the trader gets up")

func test_pack_caravan_shows_panniers_and_a_walking_trader() -> void:
	var looks := {"body_plan": "base:human_ro_m", "styles": {}, "worn": {}}
	client.entities = {
		"driver": {"kind": "creature", "creature": "base:villager", "appearance": looks,
			"profession": "base:trader", "horse": "horse", "caravan_type": "pack", "caravan_heading": [1, 0], "x": 0, "y": 0},
		"horse": {"kind": "creature", "creature": "base:horse", "caravan_driver": "driver", "pack": true,
			"x": -roundi(CreatureSim.PACK_HORSE_DISTANCE * Movement.UNIT), "y": 0}}
	view._update_actors(1, .1)
	var driver := view._actors["driver"] as BillboardActor3D
	var horse := view._actors["horse"] as BillboardActor3D
	check(driver.cart == null, "a pack caravan has no wagon")
	eq((driver.doll as RoSprite)._once, "", "the trader walks rather than sitting")
	check(horse.packs != null and horse.packs.visible, "the horse carries the Blender panniers")
	client.entities["horse"]["caravan_driver"] = ""
	client.entities["horse"]["pack"] = false
	view._update_actors(1, .1)
	check(not horse.packs.visible, "the panniers disappear when the horse is released")

func test_sleeping_sprite_keeps_its_perspective_when_the_camera_turns() -> void:
	var looks := {"body_plan": "base:human_ro_m", "styles": {}, "worn": {}}
	client.entities = {"sleeper": {"kind": "creature", "creature": "base:villager", "appearance": looks,
		"asleep": true, "face": [1, 0], "x": 0, "y": 0}}
	for turn in 4:
		view.yaw = turn * PI / 2
		view._update_actors(1, .1)
		var actor := view._actors["sleeper"] as BillboardActor3D
		eq(actor.picture.billboard, BaseMaterial3D.BILLBOARD_ENABLED, "the already projected body faces the camera")
		eq(actor.picture.rotation, Vector3.ZERO, "no second projection onto the ground")
		eq(actor.picture.position, Vector3.ZERO, "ground sleepers are not lifted onto an imaginary bed")
		eq((actor.doll as RoSprite)._row, RoSprite.ROW_OF_OCTANT[posmod(-turn * 2, 8)], "lying direction follows camera yaw")
	client.entities["sleeper"]["asleep"] = false
	view._update_actors(1, .1)
	eq((view._actors["sleeper"].doll as RoSprite)._once, "", "waking restores the ordinary pose")

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
			# From the west the tree's crown hangs before the door; it is pointed
			# at only over its own cell (the author, 28.10.2026: crowns hid the
			# small things round them), so the door is the door from any side.
			eq(hit.get("cell"), cell, "the cell under the 3D ray at yaw %f" % yaw)
			eq(hit.get("id"), target[1], "what is pointed at")

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
			if view._ground_is(cell, "chasm"):
				continue  # not walked (ADR-0064)
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

func test_crags_stand_up_and_only_a_levels_edge_is_flush() -> void:
	# The server's is_cliff decides: the edge of a level is drawn flush, any
	# other rock (a crag, a peak) stands up, so walking looks as it is.
	var flush := func(_p: Vector2i) -> bool: return true
	var none := func(_p: Vector2i) -> bool: return false
	var ground := func(_p: Vector2i) -> float: return 0.0
	var crag := RockCells3D.mesh(Vector2i.ZERO, 0.0, ground, none, flush, view.buildings.stone,
		Callable(), func(_c: Vector2i) -> bool: return false)
	check(crag.get_aabb().end.y > 1.0, "a crag beside level ground stands up: %s" % crag.get_aabb())
	var edge := RockCells3D.mesh(Vector2i.ZERO, 0.0, ground, none, flush, view.buildings.stone,
		Callable(), func(_c: Vector2i) -> bool: return true)
	check(is_equal_approx(edge.get_aabb().end.y, .05), "only the edge of a level is flush: %s" % edge.get_aabb())
	# The real world: a cliff of the small planet 431 and a crag with level
	# ground beside it (both found by the generator, not chosen by the test).
	var plan := WorldPlan.generate(431, "small", "temperate", content)
	view._land = SurfaceGenerator.new(plan.seed_value, content, plan)
	view.terrain = null
	view.terrain = view._new_terrain()
	var cliff := Vector2i(1533, -1378)
	var crag_cell := Vector2i(1526, -1294)
	check(view._rock_cliff(cliff), "the cliff is a level's edge")
	check(is_equal_approx(view._rock_top(cliff, Vector2i.ZERO) - view.terrain.cell(cliff), .05),
		"and is drawn flush with its level")
	check(not view._rock_cliff(crag_cell), "the crag is no level's edge")
	check(view._rock_top(crag_cell, Vector2i.ZERO) - view.terrain.cell(crag_cell) > 1.0,
		"so it is drawn standing up, not as walkable ground: %.2f m" % (view._rock_top(crag_cell, Vector2i.ZERO) - view.terrain.cell(crag_cell)))


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

func test_upstairs_opening_without_floor_has_visible_pickable_stairs() -> void:
	client.location = "upper"
	client.z = 1
	var c := Chunk.new()
	c.set_props(2, 2, {"stairs_down": true})
	client.chunks["upper|0|0"] = c
	view._queued["upper|0|0"] = true
	view._begin_chunk(Vector2i.ZERO)
	for i in 3: view._build_row()
	check(view._job["count"] > 0, "the open stairwell is rendered despite having no floor")
	check(view._job["targets"].any(func(t: Dictionary) -> bool: return t.get("cell") == Vector2i(2, 2) and t.get("kind") == "ground"), "ordinary interaction can pick the way down")

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

func test_chasm_walls_and_a_hanging_bridge() -> void:
	# A chasm three cells across (x 4..6) at row y 2, a bridge over it along x.
	var c := Chunk.new()
	for y in 5:
		for x in 11:
			c.set_cell("ground", x, y, "base:grass")
	for y in 5:
		for x in range(4, 7):
			c.set_cell("ground", x, y, "base:hanging_bridge" if y == 2 else "base:chasm")
	client.chunks[ServerWorld.chunk_key("surface", 0, 0)] = c
	view.terrain = null
	var edge := view.chasm_mesh(Vector2i(4, 1), 0.0)
	eq(edge.get_surface_count(), 2, "at the edge: a rock wall toward the land, and the dark bottom")
	eq(view.chasm_mesh(Vector2i(5, 1), 0.0).get_surface_count(), 1, "in the middle: only the bottom")
	check(edge.get_aabb().size.y >= WorldView3D.CHASM_DEPTH, "deep: %s" % edge.get_aabb())
	var span := view.hanging_bridge_mesh(Vector2i(5, 2))
	eq(span.get_surface_count(), 2, "planks and ropes")
	check(span.get_aabb().size.x > .9 and span.get_aabb().size.z < 1.0, "it runs along x")
	var head := view.hanging_bridge_mesh(Vector2i(4, 2))
	check(head.get_aabb().size.y > span.get_aabb().size.y, "posts where it meets the land")
	var at := Vector2(5.5, 2.5)
	check(is_equal_approx(view.elevation(at), view.surface_elevation(at) + WorldView3D.DECK), "feet on its deck")
	check(view._hollow(Vector2i(5, 2)) and view._hollow(Vector2i(5, 0)) and not view._hollow(Vector2i(3, 2)), "the chasm runs under the bridge")

func test_rock_steps_have_faces_between() -> void:
	# Two rock cells side by side, the east one a metre lower: the face between
	# them goes down to it (no gap one sees through).
	var rock := func(p: Vector2i) -> bool: return p == Vector2i(1, 0)
	var flush := func(p: Vector2i) -> bool: return p.y != 0
	var lower := func(_n: Vector2i, _c: Vector2i) -> float: return -0.95
	var with_step := RockCells3D.mesh(Vector2i.ZERO, 0.0, func(_p: Vector2i) -> float: return 0.0, rock, flush, view.buildings.stone, lower)
	var without := RockCells3D.mesh(Vector2i.ZERO, 0.0, func(_p: Vector2i) -> float: return 0.0, rock, flush, view.buildings.stone)
	check(with_step.get_faces().size() > without.get_faces().size(), "a face down to the lower rock beside")
	var level := func(_n: Vector2i, _c: Vector2i) -> float: return 0.05
	var flat := RockCells3D.mesh(Vector2i.ZERO, 0.0, func(_p: Vector2i) -> float: return 0.0, rock, flush, view.buildings.stone, level)
	eq(flat.get_faces().size(), without.get_faces().size(), "none where they stand level")

func test_a_things_pick_box_keeps_to_its_cell() -> void:
	# A tree's crown 3 m wide over the next cells: pointed at only over its own.
	var crown := AABB(Vector3(3.5 - 1.6, 0, 7.5 - 1.6), Vector3(3.2, 4.4, 3.2))
	var box := WorldView3D.pick_box(crown, Vector2i(3, 7))
	check(box.position.x >= 3.0 and box.end.x <= 4.0 and box.position.z >= 7.0 and box.end.z <= 8.0, "within its cell: %s" % box)
	check(is_equal_approx(box.size.y, 4.4), "as tall as it is")
	var post := WorldView3D.pick_box(AABB(Vector3(3.48, 0, 7.48), Vector3(.04, 1, .04)), Vector2i(3, 7))
	check(post.size.x >= .33 and post.size.z >= .33, "a thin thing wide enough to point at")
	var pebble := WorldView3D.pick_box(AABB(Vector3(3.4, 0, 7.4), Vector3(.2, .05, .2)), Vector2i(3, 7))
	check(pebble.size.y >= .25, "a flat thing high enough")

func test_inside_a_house_one_points_past_what_is_cut_away() -> void:
	view._cut = Rect2i(1, 1, 4, 4)
	var roof := {"kind": "part", "layer": "roof", "id": "base:thatch_roof", "cell": Vector2i(2, 2)}
	check(view._cut_off(roof, Vector3(2.5, 2.5, 2.5)), "its roof is passed through")
	var wall := {"kind": "part", "layer": "structure", "id": "base:wood_wall", "cell": Vector2i(1, 2)}
	var floor_y := view._floor_at(Vector2(1.5, 2.5))
	check(view._cut_off(wall, Vector3(1.5, floor_y + 1.5, 2.5)), "a wall above its cut is passed through")
	check(not view._cut_off(wall, Vector3(1.5, floor_y + .1, 2.5)), "its low sixth is still there")
	var chest := {"kind": "part", "layer": "structure", "id": "base:chest", "cell": Vector2i(2, 3)}
	check(not view._cut_off(chest, Vector3(2.5, floor_y + .4, 3.5)), "a chest inside is pointed at")
	var far_roof := {"kind": "part", "layer": "roof", "id": "base:thatch_roof", "cell": Vector2i(9, 9)}
	check(not view._cut_off(far_roof, Vector3(9.5, 2.5, 9.5)), "another house's roof is still a roof")
	view._cut = Rect2i()

func test_a_beings_figure_is_its_picture() -> void:
	var hare := view._figure(content.visual_of("base:hare"))
	check(hare.y > 0.5, "a hare is pointed at by its picture, taller than its body's 0.5 m: %s" % hare)
	check(hare.y < 2.0, "but not its whole frame: %s" % hare)
	var man := view._figure(content.visual_of("base:human_ro_m"))
	check(man.y > 1.2 and man.y < 2.2, "a person about his height: %s" % man)
