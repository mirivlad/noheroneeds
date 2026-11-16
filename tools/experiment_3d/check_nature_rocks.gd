extends "res://tools/experiment_3d/check_rocks.gd"
## Final surface-boundary mining with actual isolated viewport input.
func attach_app() -> void:
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

func aim_at(point: Vector3) -> void:
	g.mouse_at = null
	var motion := InputEventMouseMotion.new()
	motion.position = view.eye.unproject_position(point) / view._pixel
	motion.global_position = motion.position
	g.get_viewport().push_input(motion, true)
	g._update_target()
	print("NATURE_ROCK_RAY ", g.target)

# Functional captures may run while headless regression tests are active.
# Their frame intervals are deliberately not reported as performance data.
func benchmark() -> Dictionary:
	return {"measured": false, "reason": "functional surface-boundary check only"}
