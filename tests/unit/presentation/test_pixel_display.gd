extends TestCase

var window: Window
var display: PixelDisplay


func before_each() -> void:
	window = Window.new()
	display = PixelDisplay.new()


func after_each() -> void:
	display.free()
	window.free()


func test_hd_fits_requested_windows_without_integer_letterboxing() -> void:
	display.setup(window, "hd")
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
	check(window.snap_2d_transforms_to_pixel, "HD snaps final transforms to logical pixels")


func test_legacy_restores_original_raster_and_integer_policy() -> void:
	display.setup(window, "hd")
	display.free()
	display = PixelDisplay.new()
	display.setup(window, "legacy")
	eq(window.content_scale_size, Vector2i(480, 270))
	eq(window.content_scale_stretch, Window.CONTENT_SCALE_STRETCH_INTEGER)
	check(not window.snap_2d_transforms_to_pixel, "original transform policy restored")


func test_camera_preserves_world_coverage_including_far_view() -> void:
	var g := GameScreen.new()
	g.settings = GameSettings.new()
	for mode: String in ["legacy", "hd"]:
		g._opts = {"display": mode}
		for zoom: float in [1.0, 0.75]:
			g.settings.set_value("view_zoom", zoom)
			g.apply_settings()
			var raster := Vector2(PixelDisplay.HD_SIZE if mode == "hd" else PixelDisplay.LEGACY_SIZE)
			eq(raster / g.camera.zoom, Vector2(480, 270) / zoom, "same world coverage")
			eq(g.view.scale, Vector2.ONE, "world nodes are never scaled")
	g.free()


func test_app_switch_and_hud_bounds() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	for mode: String in ["hd", "legacy"]:
		var app := App.new()
		app.configure({"profile_dir": tmp_dir().path_join(mode), "world": "display", "display": mode})
		root.add_child(app)
		await (Engine.get_main_loop() as SceneTree).process_frame
		var g := app.game
		var bounds := Rect2(Vector2.ZERO, Vector2(PixelDisplay.HD_SIZE if mode == "hd" else PixelDisplay.LEGACY_SIZE))
		eq(g.get_viewport_rect().size, bounds.size)
		g._layout_hud()
		for control: Control in [g.minimap, g.hotbar, g.status]:
			check(bounds.encloses(control.get_global_rect()), "%s in %s" % [control.get_class(), mode])
		check(g.hotbar.get_global_rect().end.y <= g.status.position.y, "hotbar above status")
		if mode == "hd":
			check(g.hud.get_global_rect().end.y <= g._info.position.y, "top lines separate")
			check(g._info.get_global_rect().end.y <= g.minimap.position.y, "minimap below top lines")
		app.quit()
		app.free()
		await (Engine.get_main_loop() as SceneTree).process_frame


func test_default_launch_is_hd_without_a_profile_setting() -> void:
	eq(ProjectSettings.get_setting("display/window/size/viewport_width"), 960)
	eq(ProjectSettings.get_setting("display/window/size/viewport_height"), 540)
	var app := App.new()
	app.configure({"profile_dir": tmp_dir(), "world": "default_hd"})
	(Engine.get_main_loop() as SceneTree).root.add_child(app)
	check(not app._opts.has("display"), "no launch override")
	eq(app.get_window().content_scale_size, Vector2i(960, 540))
	eq(app.game.camera.zoom, Vector2(2, 2))
	check(app.game.hud.clip_text, "compact HD HUD enabled by default")
	app.quit()
	app.free()
	await (Engine.get_main_loop() as SceneTree).process_frame
