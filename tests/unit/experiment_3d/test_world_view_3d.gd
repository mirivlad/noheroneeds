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
		var expected := (float(view._land.land_at(cell.x, cell.y)["height"]) - Geography.SEA) * 14
		check(is_equal_approx(view.corner_height(cell), expected), "same geography + original local detail")
		check(is_equal_approx(view.elevation(Vector2(cell)), expected), "either chunk's corner agrees")
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
