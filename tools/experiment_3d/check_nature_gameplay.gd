extends "res://tools/experiment_3d/check_runtime.gd"
## The existing full action scenario, with wall-clock streaming readiness for
## today's asynchronous loader. Normal per-frame view budget stays unchanged.
func settle() -> void:
	var deadline := Time.get_ticks_msec() + 120000
	var stable := 0
	var complete := false
	while Time.get_ticks_msec() < deadline:
		await pump(1)
		var received := true
		if g.client.location == "surface":
			var at := Movement.cell_of(g.client.position)
			for y in range((at.y >> 5) - 2, (at.y >> 5) + 3):
				for x in range((at.x >> 5) - 2, (at.x >> 5) + 3):
					received = received and g.client.chunks.has(ServerWorld.chunk_key("surface", x, y))
		if received and view.pending_chunks() == 0 and view._geometry.size() >= 9:
			stable += 1
			if stable >= 3:
				complete = true
				break
		else:
			stable = 0
	verify(complete, "expected native chunks finish streaming before action checks")
	await physics_frame
	await physics_frame
	await pump(3)

# Feed a screen-space pointer through the real viewport. The old world-point
# debug hook deliberately clears the 3D ray cache before choosing an action.
func hit_at(cell: Vector2i, height := .4) -> Dictionary:
	var p := Vector2(cell) + Vector2.ONE * .5
	var point := Vector3(p.x, view.elevation(p) + (0 if g.client.z < 0 else g.client.z * 2) + height, p.y)
	var screen := view.eye.unproject_position(point) / view._pixel
	g.mouse_at = null
	var motion := InputEventMouseMotion.new()
	motion.position = screen
	motion.global_position = screen
	g.get_viewport().push_input(motion, true)
	g._update_target()
	print("GAMEPLAY_RAY ", {"wanted": cell, "screen": screen, "viewport_mouse": g.get_viewport().get_mouse_position(), "target": g.target})
	return g.target

func move_to(cell: Vector2i) -> void:
	world.move_character(g.client.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	for i in 120:
		await pump(1)
		if Movement.cell_of(g.client.position) == cell: return
	verify(false, "the client receives the requested action-scenario position")


func attach_app() -> void:
	# Window mouse coordinates follow the real desktop pointer. A contained
	# native viewport accepts isolated input without moving the user's mouse.
	var input_view := SubViewport.new()
	input_view.size = Vector2i(960, 540)
	input_view.disable_3d = true
	input_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(input_view)
	var display := TextureRect.new()
	display.texture = input_view.get_texture()
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.size = Vector2(960, 540)
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(display)
	input_view.add_child(app)
