class_name WorldView3D
extends WorldView
## A presentation adapter for the same client chunks, content IDs and units.
## Physics bodies below are for mouse picking only. Movement still uses Terrain.
const RADIUS := 2
const BUILD_BUDGET_US := 4500
const STOREY := 2.0
var viewport := SubViewport.new()
var space := Node3D.new()
var eye := Camera3D.new()
var sun := DirectionalLight3D.new()
var environment := WorldEnvironment.new()
var panel := SubViewportContainer.new()
var models := ModelLibrary3D.new()
var yaw := 0.0
var tilt := 55.0
var zoom := 25.0
var camera_settings: GameSettings
var _location := ""
var _geometry := {}
var _queued := {}
var _job := {}
var _actors := {}
var _height_cache := {}
var _height_around := Vector2i(1 << 30, 0)
var _land: SurfaceGenerator
var _cursor := {}
var _ghost_root := Node3D.new()
var _last_build_ms := 0.0
var _follow := Vector3.ZERO
var _following := false
var _rotate := false
var _report_frames := 0
var _delta_sum := 0.0
var _max_delta := 0.0

func setup(registry: ContentRegistry, game_client: GameClient) -> void:
	content = registry
	client = game_client
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.stretch = true
	layer.add_child(panel)
	panel.add_child(viewport)
	viewport.own_world_3d = true
	viewport.handle_input_locally = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.add_child(space)
	space.add_child(eye)
	space.add_child(sun)
	space.add_child(environment)
	space.add_child(_ghost_root)
	eye.projection = Camera3D.PROJECTION_ORTHOGONAL
	eye.near = .05
	eye.far = 400
	eye.current = true
	sun.rotation_degrees = Vector3(-58, -28, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 75
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("b9c7ce")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c5d4e0")
	env.ambient_light_energy = .3
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment = env

func _ready() -> void:
	_resize()
	get_viewport().size_changed.connect(_resize)

func _resize() -> void:
	panel.size = get_viewport_rect().size

func configure_camera(settings: GameSettings) -> void:
	camera_settings = settings
	yaw = float(settings.values.get("experiment_3d_yaw", 0.0))
	tilt = clampf(float(settings.values.get("experiment_3d_tilt", 55)), 25, 78)
	zoom = clampf(float(settings.values.get("experiment_3d_zoom", 25)), 12, 48)

func camera_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_MIDDLE:
			_rotate = b.pressed
			if not _rotate:
				_save_camera()
			return true
		if b.ctrl_pressed and b.pressed and b.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom = clampf(zoom * (.9 if b.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 12, 48)
			_save_camera()
			return true
	if event is InputEventMouseMotion and _rotate:
		var m := event as InputEventMouseMotion
		if m.button_mask & MOUSE_BUTTON_MASK_MIDDLE == 0:
			_rotate = false
			_save_camera()
			return false
		if m.shift_pressed:
			tilt = clampf(tilt + m.relative.y * .25, 25, 78)
		else:
			yaw = fposmod(yaw - m.relative.x * .008, TAU)
		return true
	return false

func _save_camera() -> void:
	if camera_settings:
		camera_settings.values["experiment_3d_yaw"] = yaw
		camera_settings.values["experiment_3d_tilt"] = tilt
		camera_settings.values["experiment_3d_zoom"] = zoom
		camera_settings.save()

func world_direction(screen: Vector2i) -> Vector2i:
	var d := Vector2(screen).rotated(yaw)
	# The existing transport accepts the eight discrete directions.
	return Vector2i(0 if absf(d.x) < .38 else signi(int(signf(d.x))), 0 if absf(d.y) < .38 else signi(int(signf(d.y))))

func update_view(alpha: float, delta: float) -> void:
	if client.geography and _land == null:
		# Call the ORIGINAL surface sampler, never a new world generator.
		_land = SurfaceGenerator.new(client.geography.world_seed, content)
	if client.location != _location:
		_location = client.location
		_clear_geometry()
		_following = false
	var changed := client.changed_chunks.duplicate()
	client.changed_chunks.clear()
	if changed.has("*"):
		_clear_geometry()
	for key: String in changed:
		_queued[key] = true
	# Floor division matters west and north of the origin.
	var around := Vector2i(floori(float(client.position.x) / Movement.UNIT / Chunk.SIZE), floori(float(client.position.y) / Movement.UNIT / Chunk.SIZE))
	if around != _height_around:
		_height_around = around
		for cell: Vector2i in _height_cache.keys():
			if absi(cell.x - around.x * Chunk.SIZE) > (RADIUS + 2) * Chunk.SIZE or absi(cell.y - around.y * Chunk.SIZE) > (RADIUS + 2) * Chunk.SIZE:
				_height_cache.erase(cell)
	for key: String in client.chunks:
		var k := key.split("|")
		if k[0] == client.location and absi(int(k[1]) - around.x) <= RADIUS and absi(int(k[2]) - around.y) <= RADIUS:
			if not _geometry.has(key) and _job.get("key", "") != key:
				_queued[key] = true
	for key: String in _geometry.keys():
		var k := key.split("|")
		if k[0] != client.location or absi(int(k[1]) - around.x) > RADIUS or absi(int(k[2]) - around.y) > RADIUS:
			(_geometry[key] as Node).queue_free()
			_geometry.erase(key)
	var start := Time.get_ticks_usec()
	while Time.get_ticks_usec() - start < BUILD_BUDGET_US:
		if _job.is_empty():
			_begin_chunk(around)
			if _job.is_empty():
				break
		_build_row()
	_last_build_ms = (Time.get_ticks_usec() - start) / 1000.0
	_update_actors(alpha, delta)
	if client.has_position:
		var p := own_pixel_position(alpha) / CELL
		var target := Vector3(p.x, elevation(p) + (0 if client.z < 0 else client.z * STOREY), p.y)
		_follow = target if not _following else _follow.lerp(target, 1.0 - exp(-delta * 9))
		_following = true
		eye.size = zoom
		var offset := Vector3(0, sin(deg_to_rad(tilt)), cos(deg_to_rad(tilt))).rotated(Vector3.UP, -yaw) * 65
		eye.position = _follow + offset
		eye.look_at(_follow, Vector3.UP)
	var daylight := Daylight.sun(client.world_time) if client.z >= 0 else 0.0
	sun.light_energy = .12 + daylight * .55 if client.z >= 0 else 0.0
	environment.environment.ambient_light_energy = .2 + daylight * .15 if client.z >= 0 else .28
	environment.environment.background_color = Color("b9c7ce") * (.35 + daylight * .65) if client.z >= 0 else Color("181b27")
	_report_frames += 1
	_delta_sum += delta
	_max_delta = maxf(_max_delta, delta)
	if _report_frames == 300:
		print("EXPERIMENT_3D " + JSON.stringify({"location": client.location, "fps": _report_frames / _delta_sum, "worst_frame_ms": _max_delta * 1000, "chunks": _geometry.size(), "objects": object_count(), "build_ms": _last_build_ms, "renderer": RenderingServer.get_current_rendering_method(), "adapter": RenderingServer.get_video_adapter_name()}))
		_report_frames = 0
		_delta_sum = 0
		_max_delta = 0

func _clear_geometry() -> void:
	for node: Node in _geometry.values():
		node.queue_free()
	_geometry.clear()
	_queued.clear()
	if not _job.is_empty():
		(_job["root"] as Node).queue_free()
	_job.clear()
	_height_cache.clear()

func elevation(p: Vector2) -> float:
	if client.z < 0 or _land == null:
		return 0.0
	var c := Vector2i(floori(p.x), floori(p.y))
	var f := p - Vector2(c)
	var a := corner_height(c)
	var b := corner_height(c + Vector2i.RIGHT)
	var d := corner_height(c + Vector2i.DOWN)
	var e := corner_height(c + Vector2i.ONE)
	# Exactly the same two triangles as the ground mesh (no hovering).
	return a + (b - a) * f.x + (d - a) * f.y if f.x + f.y <= 1 else e + (d - e) * (1 - f.x) + (b - e) * (1 - f.y)

func corner_height(c: Vector2i) -> float:
	if client.z < 0 or _land == null:
		return 0.0
	if not _height_cache.has(c):
		var h := float(_land.land_at(c.x, c.y)["height"])
		_height_cache[c] = (h - Geography.SEA) * 14.0
	return float(_height_cache[c])

func _begin_chunk(around: Vector2i) -> void:
	var best := ""
	var distance := INF
	for key: String in _queued:
		var k := key.split("|")
		if k.size() != 3 or k[0] != client.location or not client.chunks.has(key):
			continue
		var at := Vector2i(int(k[1]), int(k[2]))
		var d := Vector2(at - around).length_squared()
		if absi(at.x - around.x) <= RADIUS and absi(at.y - around.y) <= RADIUS and d < distance:
			best = key
			distance = d
	if best == "":
		_queued.clear()
		return
	_queued.erase(best)
	var k := best.split("|")
	var root := Node3D.new()
	space.add_child(root)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_job = {"key": best, "chunk": client.chunks[best], "origin": Vector2i(int(k[1]), int(k[2])) * Chunk.SIZE, "row": 0, "root": root, "ground": st, "faces": PackedVector3Array(), "targets": [], "instances": {}, "count": 0}

func _build_row() -> void:
	var c: Chunk = _job["chunk"]
	var y: int = _job["row"]
	var origin: Vector2i = _job["origin"]
	for x in Chunk.SIZE:
		var cell := origin + Vector2i(x, y)
		var ground := c.get_cell("ground", x, y)
		if ground == "":
			continue
		var level := 0.0 if client.z < 0 else client.z * STOREY
		var points: Array[Vector3] = []
		for d: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
			var at := cell + d
			points.append(Vector3(at.x, corner_height(at) + level, at.y))
		var rock := c.get_cell("structure", x, y)
		if client.z < 0 and x > 0 and x < Chunk.SIZE - 1 and y > 0 and y < Chunk.SIZE - 1 and content.get_def(rock).get("role") == "rock":
			var interior := true
			for offset: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				interior = interior and content.get_def(c.get_cell("structure", x + offset.x, y + offset.y)).get("role") == "rock"
			if interior:
				# Only exposed rock needs a detailed model. A solid cap still
				# covers every blocked cell; opening a neighbor rebuilds the chunk.
				for i in points.size():
					points[i].y += 1.8
				_quad(points, Color("636976"), {"kind": "part", "id": rock, "layer": "structure", "cell": cell, "location": client.location})
				_job["count"] += 1
				continue
		var color := ground_color(ground)
		_quad(points, color, {"kind": "ground", "id": ground, "cell": cell, "location": client.location})
		if models.catalog.has(ground) and not content.get_def(c.get_cell("structure", x, y)).get("role") == "rock":
			_add_object(cell, ground, "ground", {})
		for layer: String in ["cover", "structure", "ceiling", "roof"]:
			var id := c.get_cell(layer, x, y)
			if id != "":
				_add_object(cell, id, layer, c.get_props(x, y))
		if c.get_props(x, y).get("stairs_down", false):
			_add_object(cell, "base:stairs_down", "transition", {})
	_job["row"] = y + 1
	if y + 1 == Chunk.SIZE:
		_finish_chunk()

func ground_color(id: String) -> Color:
	var colors := {"base:grass": "739956", "base:grass_dry": "a8a065", "base:dirt": "aa8a65", "base:forest_floor": "657752", "base:moss": "688365", "base:sand": "d4c39b", "base:snow": "e0e6e4", "base:mud": "7c7661", "base:gravel": "92928b", "base:farmland": "725844", "base:water": "4a8eac", "base:shallows": "7baba9", "base:deep_water": "356b8d", "base:stone_floor": "797d83", "base:cave_floor": "737278"}
	var base := Color(String(colors.get(id, "93947b")))
	return base

func _quad(p: Array[Vector3], color: Color, target: Dictionary) -> void:
	var st: SurfaceTool = _job["ground"]
	var normal := (p[2] - p[0]).cross(p[1] - p[0]).normalized()
	for i in [0, 1, 2, 1, 3, 2]:
		st.set_color(color)
		st.set_normal(normal)
		st.add_vertex(p[i])
	# ConcavePolygon ray triangles use the same winding as rendered geometry.
	for i in [0, 1, 2, 1, 3, 2]:
		_job["faces"].append(p[i])
	_job["targets"].append(target)
	_job["targets"].append(target)

func _add_object(cell: Vector2i, id: String, layer: String, props: Dictionary) -> void:
	var d := content.get_def(id)
	var model_id := "base:surface_rock" if id == "base:rock" and client.z >= 0 else id
	var mesh := models.mesh_for(model_id, d)
	var at := Vector2(cell) + Vector2.ONE * .5
	var lift := (0.0 if client.z < 0 else client.z * STOREY) + (STOREY if layer in ["ceiling", "roof"] else 0.0)
	var position3 := Vector3(at.x, elevation(at) + lift, at.y)
	if not models.catalog.has(model_id):
		position3.y -= mesh.get_aabb().position.y
	if layer == "ground":
		position3.y -= .1  # Imported floor's upper face meets the foot plane.
	var basis := Basis.IDENTITY
	var facing := String(props.get("facing", "s"))
	var rotation := {"s": 0.0, "w": PI / 2, "n": PI, "e": -PI / 2}
	if not props.has("facing") and d.get("role") in ["wall", "window", "fence"]:
		var vertical := 0
		var horizontal := 0
		for offset: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var neighbor := content.get_def(_cell_layer(cell + offset, "structure"))
			if neighbor.get("role") in ["wall", "window", "door", "fence"]:
				if offset.x == 0:
					vertical += 1
				else:
					horizontal += 1
		if vertical > horizontal:
			facing = "e"
	if layer != "cover":
		basis = Basis(Vector3.UP, float(rotation.get(facing, 0.0)))
	if layer == "roof":
		var roof := _roof_area(cell)
		if cell != roof.position:
			return
		at = Vector2(roof.position) + Vector2(roof.size) * .5
		position3 = Vector3(at.x, elevation(at) + lift, at.y)
		basis = Basis.from_scale(Vector3(roof.size.x + .3, maxf(1, roof.size.x * .4), roof.size.y + .3))
	if d.get("openable", false) and props.get("open", false):
		basis = basis.rotated(Vector3.UP, PI / 2)
	var t := Transform3D(basis, position3)
	var entries: Array = _job["instances"].get_or_add(model_id, [])
	entries.append(t)
	_job["count"] += 1
	var target := {"kind": "part", "id": id, "layer": layer, "cell": cell, "location": client.location}
	if layer == "transition":
		target = {"kind": "ground", "id": ground_at(client.location, cell), "cell": cell, "location": client.location}
	if layer == "ground":
		target = {"kind": "ground", "id": id, "cell": cell, "location": client.location}
	if layer == "roof":
		target["roof_group"] = true
	# Picking boxes are independent of movement. No physics-driven walking.
	var bounds: AABB = t * mesh.get_aabb()
	_add_box_faces(bounds, target)
	var ore := id.trim_prefix("base:").trim_suffix("_ore_rock")
	if id.ends_with("_ore_rock") and ore in ["iron", "copper", "silver", "gold"]:
		var nugget_id := "base:" + ore + "_outcrop"
		var nuggets: Array = _job["instances"].get_or_add(nugget_id, [])
		nuggets.append(Transform3D(Basis.from_scale(Vector3.ONE * .6), position3 + Vector3.UP * 1.65))
	if d.has("light"):
		var light := OmniLight3D.new()
		light.position = position3 + Vector3.UP
		light.light_color = Color("ffbb72")
		light.light_energy = 1.4
		light.omni_range = 6
		(_job["root"] as Node).add_child(light)

func _roof_area(from: Vector2i) -> Rect2i:
	var pending: Array[Vector2i] = [from]
	var seen := {from: true}
	var low := from
	var high := from
	while not pending.is_empty() and seen.size() <= 256:
		var at: Vector2i = pending.pop_back()
		low = low.min(at)
		high = high.max(at)
		for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next := at + d
			if not seen.has(next) and _cell_layer(next, "roof") == _cell_layer(from, "roof"):
				seen[next] = true
				pending.append(next)
	var size := high - low + Vector2i.ONE
	# A removed tile must leave a hole. Only complete rectangles share a roof.
	return Rect2i(low, size) if seen.size() == size.x * size.y and seen.size() <= 256 else Rect2i(from, Vector2i.ONE)

func _add_box_faces(box: AABB, target: Dictionary) -> void:
	for face: Array in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		for i in [0, 1, 2, 0, 2, 3]:
			_job["faces"].append(box.get_endpoint(face[i]))
		_job["targets"].append(target)
		_job["targets"].append(target)

func _finish_chunk() -> void:
	var root: Node3D = _job["root"]
	var st: SurfaceTool = _job["ground"]
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(material)
	var mesh := MeshInstance3D.new()
	mesh.mesh = st.commit()
	root.add_child(mesh)
	for id: String in _job["instances"]:
		var transforms: Array = _job["instances"][id]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = models.mesh_for(id, content.get_def(id))
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		root.add_child(node)
	if not (_job["faces"] as PackedVector3Array).is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(_job["faces"])
		var collider := CollisionShape3D.new()
		collider.shape = shape
		var body := StaticBody3D.new()
		body.add_child(collider)
		body.set_meta("targets", _job["targets"])
		root.add_child(body)
	root.set_meta("count", _job["count"])
	var key: String = _job["key"]
	if _geometry.has(key):
		(_geometry[key] as Node).queue_free()
	_geometry[key] = root
	_job = {}

func object_count() -> int:
	var count := 0
	for root: Node in _geometry.values():
		count += int(root.get_meta("count", 0))
	return count

func sprite_count() -> int:
	return _actors.size()

func pending_chunks() -> int:
	return _queued.size() + (0 if _job.is_empty() else 1)

func _update_actors(alpha: float, delta: float) -> void:
	var entities := client.entities.duplicate()
	if client.has_position:
		entities[client.character_id] = client.own.merged({"kind": "character", "x": client.position.x, "y": client.position.y}, true)
	var seen := {}
	for id: String in entities:
		var e: Dictionary = entities[id]
		var kind := String(e.get("kind", ""))
		if kind not in ["character", "creature", "item"]:
			continue
		var p := Vector2(float(e.get("x", 0)), float(e.get("y", 0))) / Movement.UNIT
		if id == client.character_id:
			p = own_pixel_position(alpha) / CELL
		seen[id] = true
		var at := Vector3(p.x, elevation(p) + (0 if client.z < 0 else int(e.get("z", client.z)) * STOREY), p.y)
		if kind == "item":
			_update_item(id, e, at)
			continue
		var looks: Dictionary = e.get("appearance", {})
		if kind == "creature" and looks.is_empty():
			looks = {"body_plan": String(e.get("creature", ""))}
		var actor := _actors.get(id) as BillboardActor3D
		if actor and actor.looks != looks:
			actor.queue_free()
			actor = null
		if actor == null:
			actor = BillboardActor3D.new()
			var visual := content.visual_of(String(looks.get("body_plan", "base:human_m")))
			if visual.is_empty():
				visual = content.visual_of("base:human_m")
			actor.setup(content, visual, looks, {"kind": "entity", "id": id, "entity": e, "location": client.location})
			actor.doll.stepped.connect(func() -> void:
				if on_step.is_valid():
					on_step.call(Vector2(actor.position.x, actor.position.z) * CELL))
			space.add_child(actor)
			actor.position = at
			_actors[id] = actor
		actor.body.set_meta("target", {"kind": "entity", "id": id, "entity": e, "location": client.location})
		actor.show_actor(at, yaw, delta, id == client.character_id)
		actor.scale = Vector3.ONE * (.6 if e.get("young", false) else 1.0)
		var held := own_held if id == client.character_id else String(e.get("held", ""))
		actor.doll.hold(item_picture(held), item_grip(held), held)
	for id: String in _actors.keys():
		if not seen.has(id):
			(_actors[id] as Node).queue_free()
			_actors.erase(id)

func _update_item(id: String, e: Dictionary, at: Vector3) -> void:
	var node := _actors.get(id) as Sprite3D
	if node == null:
		node = Sprite3D.new()
		node.texture = item_picture(String(e.get("item", "")))
		node.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		node.pixel_size = .04
		node.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		space.add_child(node)
		_actors[id] = node
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(.6, .6, .6)
		shape.shape = box
		body.add_child(shape)
		body.set_meta("target", {"kind": "entity", "id": id, "entity": e, "location": client.location})
		node.add_child(body)
	node.position = at + Vector3.UP * .22

func screen_point(screen: Vector2) -> Vector2:
	_cursor = {}
	if not eye.is_inside_tree() or eye.get_world_3d() == null:
		return Vector2.ZERO
	var origin := eye.project_ray_origin(screen)
	var to := origin + eye.project_ray_normal(screen) * eye.far
	var query := PhysicsRayQueryParameters3D.create(origin, to)
	query.hit_back_faces = true
	var own_actor := _actors.get(client.character_id) as BillboardActor3D
	if own_actor:
		query.exclude = [own_actor.body.get_rid()]
	var hit := eye.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var body := hit["collider"] as Node
		if body.has_meta("target"):
			_cursor = body.get_meta("target")
		elif body.has_meta("targets"):
			var targets: Array = body.get_meta("targets")
			var face := int(hit.get("face_index", -1))
			if face >= 0 and face < targets.size():
				_cursor = targets[face]
		if _cursor.get("roof_group", false):
			_cursor = _cursor.duplicate()
			var roof_hit: Vector3 = hit["position"]
			_cursor["cell"] = Vector2i(floori(roof_hit.x), floori(roof_hit.z))
		if _cursor.has("cell"):
			return (Vector2(_cursor["cell"]) + Vector2.ONE * .5) * CELL
		var p: Vector3 = hit["position"]
		return Vector2(p.x, p.z) * CELL
	# Unknown space is outside loaded chunks, so cannot produce a valid action.
	return own_pixel_position(1)

func pick_target(point: Vector2) -> Dictionary:
	if not _cursor.is_empty():
		var target := _cursor.duplicate()
		if target.get("kind") == "part":
			var props := props_at(target["cell"])
			var worn: Dictionary = props if target["layer"] == "structure" else props.get(target["layer"], {})
			for key: String in ["damage", "work"]:
				if int(worn.get(key, 0)) > 0:
					target[key] = int(worn[key])
		return target
	var cell := Vector2i(floori(point.x / CELL), floori(point.y / CELL))
	return {"kind": "ground", "id": ground_at(client.location, cell), "cell": cell, "location": client.location}

func hidden_room() -> Dictionary:
	if client.has_position:
		var cell := Movement.cell_of(client.position)
		if _cell_layer(cell, "roof") != "" or _cell_layer(cell, "ceiling") != "":
			return {cell: true}
	return {}

func swing_own(dir: Vector2) -> void:
	var actor := _actors.get(client.character_id) as BillboardActor3D
	if actor:
		actor.doll.swing(dir.rotated(-yaw), swing_kind(own_held))

func burst_at(_at: Vector2, _kind: String, _tint := Color.WHITE) -> void:
	pass

func show_plan(plan: Array) -> void:
	for child: Node in _ghost_root.get_children():
		child.queue_free()
	for entry: Array in plan:
		var cell: Vector2i = entry[0]
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(.96, .08, .96)
		box.mesh = mesh
		box.material_override = models.material(Color("80d58b") if entry[1] == "" else Color("d77b75"))
		var at := Vector2(cell) + Vector2.ONE * .5
		box.position = Vector3(at.x, elevation(at) + (0 if client.z < 0 else client.z * STOREY) + .07, at.y)
		_ghost_root.add_child(box)
