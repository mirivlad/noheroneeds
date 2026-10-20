extends TestCase

var window: Window
var display: PixelDisplay


func before_each() -> void:
	window = Window.new()
	display = PixelDisplay.new()


func after_each() -> void:
	display.free()
	window.free()


func test_fits_requested_windows_without_integer_letterboxing() -> void:
	display.setup(window)
	for physical: Vector2i in [Vector2i(1920, 1080), Vector2i(1600, 900), Vector2i(2560, 1440),
			Vector2i(1280, 1024), Vector2i(800, 450), Vector2i(2880, 1700)]:
		window.size = physical
		display._process(0.0)
		eq(window.content_scale_size, Vector2i(960, 540))
		var fit := minf(float(physical.x) / 960, float(physical.y) / 540)
		var expected := Window.CONTENT_SCALE_STRETCH_INTEGER if is_equal_approx(fit, roundf(fit)) \
			else Window.CONTENT_SCALE_STRETCH_FRACTIONAL
		eq(window.content_scale_stretch, expected, str(physical))
	eq(window.content_scale_aspect, Window.CONTENT_SCALE_ASPECT_KEEP)
	eq(window.canvas_item_default_texture_filter, Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	check(window.snap_2d_transforms_to_pixel, "final transforms snap to logical pixels")


func test_camera_preserves_world_coverage_including_far_view() -> void:
	var g := GameScreen.new()
	g.settings = GameSettings.new()
	for zoom: float in [1.0, 0.75]:
		g.settings.set_value("view_zoom", zoom)
		g.apply_settings()
		eq(Vector2(PixelDisplay.SIZE) / g.camera.zoom, Vector2(480, 270) / zoom, "30 by 17 cells, more when far")
		eq(g.view.scale, Vector2.ONE, "world nodes are never scaled")
	g.free()


func test_launch_and_hud_bounds() -> void:
	eq(ProjectSettings.get_setting("display/window/size/viewport_width"), 960)
	eq(ProjectSettings.get_setting("display/window/size/viewport_height"), 540)
	var app := App.new()
	app.configure({"profile_dir": tmp_dir(), "world": "display"})
	(Engine.get_main_loop() as SceneTree).root.add_child(app)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var g := app.game
	var bounds := Rect2(Vector2.ZERO, Vector2(PixelDisplay.SIZE))
	eq(g.get_viewport_rect().size, bounds.size)
	eq(app.get_window().content_scale_size, PixelDisplay.SIZE)
	eq(g.camera.zoom, Vector2(2, 2))
	g._layout_hud()
	for control: Control in [g.minimap, g.hotbar, g.status]:
		check(bounds.encloses(control.get_global_rect()), control.get_class() + " on the screen")
	check(g.hotbar.get_global_rect().end.y <= g.status.position.y, "hotbar above status")
	check(g.hud.get_global_rect().end.y <= g._info.position.y, "top lines separate")
	check(g._info.get_global_rect().end.y <= g.minimap.position.y, "minimap below top lines")
	check(g.hud.clip_text, "bounded HUD lines")
	app.quit()
	app.free()
	await (Engine.get_main_loop() as SceneTree).process_frame
