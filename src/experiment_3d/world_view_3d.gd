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
var buildings := BuildingModules3D.new()
var ground_material := GroundMaterial3D.new()
var terrain: TerrainShape3D
var _floor_chunks := {}
var yaw := 0.0
var tilt := 55.0
var zoom := 16.875
var camera_settings: GameSettings
var _location := ""
var _geometry := {}
var _queued := {}
var _job := {}
var _actors := {}
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
## Screen pixels to a pixel of the raster: the 3D picture is drawn at the screen's own (ADR-0058).
var _pixel := 1.0

func setup(registry: ContentRegistry, game_client: GameClient) -> void:
	content = registry
	client = game_client
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	env.ambient_light_color = Color("aebfcf")
	env.ambient_light_energy = .3
	# The sun shapes things (a lit side and a shade side), the sky only fills the
	# shade: a bright, even ambient made trees and walls look flat and washed out.
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.1
	environment.environment = env

func _ready() -> void:
	_resize()
	get_viewport().size_changed.connect(_resize)

func _notification(what: int) -> void:
	# The scene made up front but never placed (a start that failed before setup()) is freed too.
	if what == NOTIFICATION_PREDELETE:
		for n: Node in [panel, viewport, space, eye, sun, environment, _ghost_root]:
			if is_instance_valid(n) and n.get_parent() == null:
				n.free()

func _resize() -> void:
	_pixel = _screen_pixel()
	viewport.size = Vector2i((get_viewport_rect().size * _pixel).round())
	panel.size = Vector2(viewport.size)
	panel.scale = Vector2.ONE / _pixel

func _screen_pixel() -> float:
	return maxf(1.0, get_viewport().get_final_transform().get_scale().x)

func configure_camera(settings: GameSettings) -> void:
	camera_settings = settings
	yaw = float(settings.values.get("experiment_3d_yaw", 0.0))
	tilt = clampf(float(settings.values.get("experiment_3d_tilt", 55)), 25, 78)
	zoom = clampf(float(settings.values.get("experiment_3d_zoom", 16.875)), 12, 48)

func camera_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_MIDDLE:
			_rotate = b.pressed
			if not _rotate:
				_save_camera()
			return true
		if b.pressed and b.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
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
	# the window can grow with the raster's size the same (no size_changed)
	if not is_equal_approx(_screen_pixel(), _pixel):
		_resize()
	if client.geography and _land == null:
		# Call the ORIGINAL surface sampler, never a new world generator.
		_land = SurfaceGenerator.new(client.geography.world_seed, content)
		terrain = TerrainShape3D.new(_land, _rock_at)
	if client.location != _location:
		_location = client.location
		_clear_geometry()
		_following = false
	var changed := client.changed_chunks.duplicate()
	client.changed_chunks.clear()
	if changed.has("*"):
		_clear_geometry()
	if _land and client.z >= 0: _refresh_foundations(changed)
	if terrain and not changed.is_empty():
		terrain.heights.clear()  # rock dug out (or laid) moves the ground at its corners
	if not changed.is_empty():
		_cut_from = Vector2i(1 << 30, 0)  # a roof laid or taken off: the cut again
	for key: String in changed:
		var split := key.split("|")
		if split.size() != 3: continue
		# Normals, texture blending and connected walls read adjacent cells.
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				_queued[ServerWorld.chunk_key(split[0], int(split[1]) + dx, int(split[2]) + dy)] = true
	# Floor division matters west and north of the origin.
	var around := Vector2i(floori(float(client.position.x) / Movement.UNIT / Chunk.SIZE), floori(float(client.position.y) / Movement.UNIT / Chunk.SIZE))
	if around != _height_around:
		_height_around = around
		if terrain: terrain.prune(around * Chunk.SIZE, (RADIUS + 2) * Chunk.SIZE)

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
	if client.z >= 0 or _cut != Rect2i():
		_update_cutaway()
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
	sun.light_energy = .15 + daylight * .95 if client.z >= 0 else 0.0
	environment.environment.ambient_light_energy = .14 + daylight * .1 if client.z >= 0 else .28
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
	_floor_chunks.clear()
	if terrain:
		terrain.extra_pads.clear()
		terrain.heights.clear()

func _refresh_foundations(changed: Array) -> void:
	var dirty := false
	var keys: Array = client.chunks.keys() if changed.has("*") else changed
	for key: String in keys:
		if not key.begins_with("surface|") or not client.chunks.has(key): continue
		var c: Chunk = client.chunks[key]
		var k := key.split("|")
		var origin := Vector2i(int(k[1]), int(k[2])) * Chunk.SIZE
		var floors := {}
		for y in Chunk.SIZE:
			for x in Chunk.SIZE:
				if c.get_cell("ground", x, y) in ["base:wood_floor", "base:stone_floor"] and not c.get_props(x, y).has("village"):
					floors[origin + Vector2i(x, y)] = true
		if floors != _floor_chunks.get(key, {}):
			_floor_chunks[key] = floors
			dirty = true
	for key: String in _floor_chunks.keys():
		if not client.chunks.has(key):
			_floor_chunks.erase(key)
			dirty = true
	if not dirty: return
	var cells := {}
	for floors: Dictionary in _floor_chunks.values(): cells.merge(floors)
	var pads := []
	while not cells.is_empty():
		var first: Vector2i = cells.keys()[0]
		var low := first
		var high := first
		var todo: Array[Vector2i] = [first]
		cells.erase(first)
		while not todo.is_empty():
			var at: Vector2i = todo.pop_back()
			low = low.min(at)
			high = high.max(at)
			for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				if cells.erase(at + d): todo.append(at + d)
		var rect := Rect2(Vector2(low), Vector2(high - low + Vector2i.ONE))
		pads.append([rect, terrain.natural(Vector2i(rect.get_center())) + .04])
	terrain.extra_pads = pads
	terrain.heights.clear()
	for key: String in _geometry: _queued[key] = true

func elevation(p: Vector2) -> float:
	var bridge := .18 if client.z >= 0 and _cell_layer(Vector2i(floori(p.x),floori(p.y)), "ground") == "base:bridge" else 0.0
	return surface_elevation(p) + bridge

func surface_elevation(p: Vector2) -> float:
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
	if terrain == null: terrain = TerrainShape3D.new(_land, _rock_at)
	return terrain.height(c)

## Whether a surface cell is rock (a cliff or a crag): the ground stands round it.
func _rock_at(c: Vector2i) -> bool:
	return content.get_def(_cell_layer(c, "structure")).get("role") == "rock"

func corner_normal(c: Vector2i) -> Vector3:
	return Vector3(corner_height(c + Vector2i.LEFT) - corner_height(c + Vector2i.RIGHT), 2, corner_height(c + Vector2i.UP) - corner_height(c + Vector2i.DOWN)).normalized()

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
	var rock_surface := SurfaceTool.new()
	rock_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_job = {"rock": rock_surface, "rock_count": 0, "key": best, "chunk": client.chunks[best], "origin": Vector2i(int(k[1]), int(k[2])) * Chunk.SIZE, "row": 0, "root": root, "ground": st, "faces": PackedVector3Array(), "targets": [], "instances": {}, "meshes": {}, "parts": {}, "count": 0}

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
			# Keep the substrate below laid floors and any ground drawn by a model
			# (a cave's floor too). Coplanar top faces cause stripes/z-fighting.
			var bed := .14 if ground in ["base:wood_floor", "base:stone_floor", "base:bridge"] or models.catalog.has(ground) else 0.0
			points.append(Vector3(at.x, corner_height(at) + level - bed, at.y))
		var color := ground_color(ground)
		# A way down is a hole in the ground (hole_mesh), not a floor with stairs on it.
		if content.get_def(c.get_cell("structure", x, y)).get("leads") != "down" and not c.get_props(x, y).get("stairs_down", false):
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
		st.set_normal(corner_normal(Vector2i(roundi(p[i].x), roundi(p[i].z))) if target.get("kind") == "ground" else normal)
		st.set_uv(Vector2(p[i].x, p[i].z))
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
	var instance_id := model_id
	var role := String(d.get("role", ""))
	if role == "rock":
		var floor_y := position3.y - lift
		mesh = RockCells3D.mesh(cell, (terrain.cell(cell) if client.z >= 0 and terrain else 0.0) - floor_y,
			func(c: Vector2i) -> float: return (terrain.low(c) if client.z >= 0 and terrain else 0.0) - floor_y,
			_rock_at, func(c: Vector2i) -> bool: return client.z >= 0 and terrain != null and not _rock_at(c) and terrain.cell(c) >= terrain.cell(cell) - .5,
			buildings.rock)
		instance_id = "rock:" + str(cell)
		basis = Basis.IDENTITY
	elif role in ["wall", "window", "door"] and not id.contains("rock"):
		if role == "wall":
			var mask := wall_mask(cell)
			mesh = buildings.wall(mask, id.contains("stone"))
			basis = Basis.IDENTITY
		else:
			mesh = buildings.opening(role == "window", bool(props.get("open", false)))
		instance_id = "module:" + str(mesh.get_instance_id())
	elif layer == "roof":
		mesh = roof_mesh(cell)
		basis = Basis.IDENTITY
		instance_id = "module:" + str(mesh.get_instance_id())
	elif (d.get("leads") == "down" and layer == "structure") or layer == "transition":
		mesh = hole_mesh(cell, position3.y - lift, lift)
		basis = Basis.IDENTITY
		instance_id = "hole:" + str(cell)
	elif layer == "ground" and id == "base:bridge":
		mesh = bridge_mesh(cell)
		position3.y += .1
		basis = Basis.IDENTITY
		instance_id = "bridge:" + str(cell)
	elif layer == "ground" and id == "base:wood_floor":
		mesh = buildings.floor_mesh()
		position3.y += .1
		basis = Basis.IDENTITY
		instance_id = "module:floor"
	if d.get("openable", false) and role != "door" and props.get("open", false):
		var hinge := basis * Vector3(-.45, 0, 0)
		basis = basis.rotated(Vector3.UP, PI / 2)
		position3 += hinge - basis * Vector3(-.45, 0, 0)
	_job["meshes"][instance_id] = mesh
	var t := Transform3D(basis, position3)
	if role == "rock":
		(_job["rock"] as SurfaceTool).append_from(mesh, 0, t)
		_job["rock_count"] += 1
	else:
		var entries: Array = _job["instances"].get_or_add(instance_id, [])
		entries.append(t)
		# A house's parts, cut away while one is inside it: [cell, a cover (ceiling, roof) or not].
		var parts: Array = _job["parts"].get_or_add(instance_id, [])
		var cover := layer in ["ceiling", "roof"]
		parts.append([cell, cover] if cover or role in ["wall", "window", "door"] else [])
	_job["count"] += 1
	var target := {"kind": "part", "id": id, "layer": layer, "cell": cell, "location": client.location}
	if layer == "transition":
		target = {"kind": "ground", "id": ground_at(client.location, cell), "cell": cell, "location": client.location}
	if layer == "ground":
		target = {"kind": "ground", "id": id, "cell": cell, "location": client.location}
	# Picking boxes are independent of movement. No physics-driven walking.
	if role == "rock" or layer == "roof":
		var triangles := mesh.get_faces()
		for vertex: Vector3 in triangles:
			_job["faces"].append(t * vertex)
		for i in triangles.size() / 3: _job["targets"].append(target)
	else:
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

func bridge_mesh(cell: Vector2i) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var at := Vector2(cell) + Vector2.ONE * .5
	var p: Array[Vector3] = []
	for d:Vector2 in [Vector2.ZERO,Vector2.RIGHT,Vector2.DOWN,Vector2.ONE]:
		p.append(Vector3(d.x-.5,surface_elevation(Vector2(cell)+d)-surface_elevation(at),d.y-.5))
	for i in 4: p.append(p[i]-Vector3.UP*.12)
	# The upper face has exactly the terrain's two triangles, so feet and
	# deck agree even where a river bends over non-planar cell corners.
	for face:Array in [[0,1,2,3],[4,6,5,7],[4,5,0,1],[6,2,7,3],[4,0,6,2],[5,7,1,3]]:
		for tri:Array in [[0,1,2],[1,3,2]]:
			var normal := (p[face[tri[2]]]-p[face[tri[0]]]).cross(p[face[tri[1]]]-p[face[tri[0]]]).normalized()
			for j:int in tri:
				var vertex := p[face[j]]
				st.set_normal(normal)
				st.set_uv(Vector2(vertex.x+.5,vertex.z+.5))
				st.add_vertex(vertex)
	st.set_material(buildings.deck)
	return st.commit()

## A way down (a cave mouth, a shaft): a pit in the ground HOLE_DEPTH deep, its
## walls rock, steps going down one side, dark at the bottom. Relative to the
## cell's middle at `middle` (metres) on a level `lift` up.
const HOLE_DEPTH := 1.4

func hole_mesh(cell: Vector2i, middle: float, lift: float) -> Mesh:
	var top: Array[Vector3] = []
	for d: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
		var h := corner_height(cell + d) if client.z >= 0 else 0.0
		top.append(Vector3(d.x - .5, h - middle, d.y - .5))
	var floor_y := minf(minf(top[0].y, top[1].y), minf(top[2].y, top[3].y)) - HOLE_DEPTH
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The four walls, facing in: [top a, top b] of each side, seen from inside.
	for side: Array in [[1, 0], [3, 1], [2, 3], [0, 2]]:
		var a: Vector3 = top[side[0]]
		var b: Vector3 = top[side[1]]
		_inward(st, [a, b, Vector3(a.x, floor_y, a.z), Vector3(b.x, floor_y, b.z)])
	# Steps down along the north wall.
	for i in 3:
		var y := floor_y + HOLE_DEPTH * (3 - i) / 4.0
		var z0 := -.5 + i * .3
		_inward(st, [Vector3(-.5, y, z0 + .3), Vector3(.5, y, z0 + .3), Vector3(-.5, y, z0), Vector3(.5, y, z0)])
		_inward(st, [Vector3(-.5, y, z0 + .3), Vector3(.5, y, z0 + .3), Vector3(-.5, floor_y, z0 + .3), Vector3(.5, floor_y, z0 + .3)])
	st.set_material(buildings.rock)
	st.commit(mesh)
	var dark := SurfaceTool.new()
	dark.begin(Mesh.PRIMITIVE_TRIANGLES)
	_inward(dark, [Vector3(-.5, floor_y, -.5), Vector3(.5, floor_y, -.5), Vector3(-.5, floor_y, .5), Vector3(.5, floor_y, .5)])
	dark.set_material(models.material(Color("0b0a0d")))
	dark.commit(mesh)
	return mesh

## A quad [a, b, c, d] (a-b along the top, c-d below them) with both faces drawn.
func _inward(st: SurfaceTool, p: Array) -> void:
	for tri: Array in [[0, 1, 2], [1, 3, 2], [0, 2, 1], [1, 2, 3]]:
		var n: Vector3 = (p[tri[2]] - p[tri[0]]).cross(p[tri[1]] - p[tri[0]]).normalized()
		for i: int in tri:
			st.set_normal(n)
			st.set_uv(Vector2(p[i].x + p[i].z, p[i].y))
			st.add_vertex(p[i])

func wall_mask(cell: Vector2i) -> int:
	var mask := 0
	var directions := [Vector2i.RIGHT, Vector2i.UP, Vector2i.LEFT, Vector2i.DOWN]
	for i in 4:
		if content.get_def(_cell_layer(cell + directions[i], "structure")).get("role") in ["wall", "window", "door"]:
			mask |= 1 << i
	return mask if mask != 0 else 5

func roof_mesh(cell: Vector2i) -> Mesh:
	var eaves := 0
	var directions := [Vector2i.RIGHT, Vector2i.UP, Vector2i.LEFT, Vector2i.DOWN]
	for i in 4:
		var neighbor: Vector2i = cell + directions[i]
		if _cell_layer(neighbor, "roof") == "" and content.get_def(_cell_layer(neighbor, "structure")).get("role") in ["wall", "window", "door"]:
			eaves |= 1 << i
	return buildings.roof(cell, building_footprint(cell), eaves)

func building_footprint(cell: Vector2i) -> Rect2i:
	# Existing village footprints keep their ridge when a part is removed.
	if _land:
		for plan: Dictionary in _land.settlements.plans_touching(floori(cell.x / 32.0), floori(cell.y / 32.0)):
			for home: Dictionary in plan.get("homes", []):
				if (home["rect"] as Rect2i).has_point(cell): return home["rect"]
	# Player construction uses the connected live floor, never a prefab.
	var pending: Array[Vector2i] = [cell]
	var seen := {cell: true}
	var low := cell
	var high := cell
	while not pending.is_empty() and seen.size() < 256:
		var at: Vector2i = pending.pop_back()
		low = low.min(at)
		high = high.max(at)
		for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next := at + d
			var floor := _cell_layer(next, "ground")
			if not seen.has(next) and (floor in ["base:wood_floor", "base:stone_floor"] or content.get_def(floor).get("role") == "floor"):
				seen[next] = true
				pending.append(next)
	return Rect2i(low, high - low + Vector2i.ONE) if seen.size() > 1 else Rect2i(cell, Vector2i.ONE)

func _add_box_faces(box: AABB, target: Dictionary) -> void:
	for face: Array in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		for i in [0, 1, 2, 0, 2, 3]:
			_job["faces"].append(box.get_endpoint(face[i]))
		_job["targets"].append(target)
		_job["targets"].append(target)

func _finish_chunk() -> void:
	var root: Node3D = _job["root"]
	var st: SurfaceTool = _job["ground"]
	var material := ground_material.make(_job["origin"], func(at: Vector2i) -> String: return _cell_layer(at, "ground"))
	st.set_material(material)
	var mesh := MeshInstance3D.new()
	mesh.mesh = st.commit()
	root.add_child(mesh)
	if int(_job["rock_count"]) > 0:
		var rock := MeshInstance3D.new()
		(_job["rock"] as SurfaceTool).set_material(buildings.rock)
		rock.mesh = (_job["rock"] as SurfaceTool).commit()
		root.add_child(rock)
	for id: String in _job["instances"]:
		var transforms: Array = _job["instances"][id]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _job["meshes"][id] if _job["meshes"].has(id) else models.mesh_for(id, content.get_def(id))
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		var parts: Array = _job["parts"].get(id, [])
		if parts.any(func(p: Array) -> bool: return not p.is_empty()):
			node.set_meta("parts", parts)
			node.set_meta("transforms", transforms)
			_cut_away(node)
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
		actor.doll.submerged = (client.in_water(client.position) or client.aboard() != "") if id == client.character_id else (kind == "character" and (client.in_water(Vector2i(int(e.get("x", 0)), int(e.get("y", 0)))) or String(e.get("aboard", "")) != ""))
		actor.show_actor(at, yaw, delta, id == client.character_id)
		# Interpolate XZ first, then sample the rendered triangle under the
		# interpolated feet. Interpolating target Y cuts through convex hills.
		actor.position.y = elevation(Vector2(actor.position.x, actor.position.z)) + (0 if client.z < 0 else int(e.get("z", client.z)) * STOREY)
		actor.scale = Vector3.ONE * (.6 if e.get("young", false) else 1.0)
		var held := own_held if id == client.character_id else String(e.get("held", ""))
		actor.doll.hold(item_picture("" if actor.doll.submerged else held), item_grip(held), "" if actor.doll.submerged else held)
		# Hurt: a flinch; fallen: lies a while (ADR-0019).
		var h := int(e.get("health", e.get("max_health", 0)))
		if h < int(_hp_seen.get(id, h)):
			actor.doll.react("dead" if h <= 0 else "hurt", 2.0 if h <= 0 else 0.0)
		_hp_seen[id] = h
		if int(e.get("deaths", 0)) > int(_deaths_seen.get(id, e.get("deaths", 0))):
			actor.doll.react("dead", 2.0)
		_deaths_seen[id] = int(e.get("deaths", 0))
		# Others' blows (the own are shown at the click): their count, the low bits the direction.
		var blows := int(e.get("swing", 0))
		if id != client.character_id and _swing_seen.has(id) and int(_swing_seen[id]) != blows:
			actor.swing(Vector2.RIGHT.rotated((blows & 7) * PI / 4), swing_kind(held), yaw)
		_swing_seen[id] = blows
	for id: String in _actors.keys():
		if not seen.has(id):
			(_actors[id] as Node).queue_free()
			_actors.erase(id)
			_swing_seen.erase(id)

func _update_item(id: String, e: Dictionary, at: Vector3) -> void:
	var node := _actors.get(id) as Sprite3D
	if node == null:
		node = Sprite3D.new()
		node.texture = item_picture(String(e.get("item", "")))
		node.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		node.pixel_size = .04 * GROUND_ITEM_SCALE * .75  # a thing on the ground, about half a metre
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
	node.position = at + Vector3.UP * .3  # its middle: the picture stands on the ground

func screen_point(screen: Vector2) -> Vector2:
	_cursor = {}
	if not eye.is_inside_tree() or eye.get_world_3d() == null:
		return Vector2.ZERO
	var origin := eye.project_ray_origin(screen * _pixel)
	var to := origin + eye.project_ray_normal(screen * _pixel) * eye.far
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

## The house one is inside (a roof or a ceiling over one's cell): its rect grown
## by its walls; its covers are not drawn and its walls stand a sixth of their
## height (the author, 28.10.2026), so one sees in. Empty when outdoors.
var _cut := Rect2i()
var _cut_from := Vector2i(1 << 30, 0)

func _update_cutaway() -> void:
	var me := Movement.cell_of(client.position) if client.has_position else Vector2i(1 << 30, 0)
	if me == _cut_from:
		return
	_cut_from = me
	var inside := client.has_position and (_cell_layer(me, "roof") != "" or _cell_layer(me, "ceiling") != "")
	var cut := building_footprint(me).grow(1) if inside else Rect2i()
	if cut == _cut:
		return
	_cut = cut
	for root: Node in _geometry.values():
		for node: Node in root.get_children():
			if node.has_meta("parts"):
				_cut_away(node as MultiMeshInstance3D)

## Lays a chunk's house parts as the cut says: whole, or cut away inside it.
func _cut_away(node: MultiMeshInstance3D) -> void:
	var parts: Array = node.get_meta("parts")
	var transforms: Array = node.get_meta("transforms")
	for i in parts.size():
		node.multimesh.set_instance_transform(i, cut_transform(transforms[i], parts[i]))

## Where a house part stands as the cut says: as laid; or, in the house one is in,
## a cover gone and a wall a sixth of its height on its foot.
func cut_transform(t: Transform3D, part: Array) -> Transform3D:
	if part.is_empty() or not _cut.has_point(part[0]):
		return t
	if part[1]:
		return Transform3D(Basis.from_scale(Vector3.ZERO), t.origin)
	return t * Transform3D(Basis.from_scale(Vector3(1, 1.0 / 6.0, 1)), Vector3.ZERO)

func hidden_room() -> Dictionary:
	if client.has_position:
		var cell := Movement.cell_of(client.position)
		if _cell_layer(cell, "roof") != "" or _cell_layer(cell, "ceiling") != "":
			return {cell: true}
	return {}

func swing_own(dir: Vector2) -> void:
	var actor := _actors.get(client.character_id) as BillboardActor3D
	if actor:
		actor.swing(dir, swing_kind(own_held), yaw)

func react_own(clip: String) -> void:
	var actor := _actors.get(client.character_id) as BillboardActor3D
	if actor:
		actor.doll.react(clip)

func draw_own(dir: Vector2) -> void:
	var actor := _actors.get(client.character_id) as BillboardActor3D
	if actor:
		actor.swing(dir, swing_kind(own_held), yaw)
		actor.doll._drawn = true

func loose_own(dir: Vector2) -> void:
	var actor := _actors.get(client.character_id) as BillboardActor3D
	if actor:
		if dir.length() > 0.01:
			actor.facing = dir.normalized()
		actor.doll.loose(dir.rotated(-yaw))

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
