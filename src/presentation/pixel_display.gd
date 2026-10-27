class_name PixelDisplay
extends Node
## Presentation only: simulation cells and WorldView's coordinates stay intact.
## The logical raster is 960x540 (ADR-0022): a texel of the LPC pictures is a
## pixel of it, a world pixel two (the camera's zoom). It is drawn at the
## screen's own resolution (ADR-0058): the interface and the world keep their
## size, and pictures finer than its pixel (RO characters, a quarter of a
## world pixel a texel) keep their detail.

const SIZE := Vector2i(960, 540)
## World pixels to the raster's (the camera's zoom at the normal view).
const WORLD_SCALE := 2.0

var _window: Window
var _last_size := Vector2i.ZERO


func setup(window: Window) -> void:
	_window = window
	_window.content_scale_size = SIZE
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	_window.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_window.snap_2d_transforms_to_pixel = true
	_fit()


func _process(_delta: float) -> void:
	# Viewport.size_changed need not fire when only the physical window changes
	# and its fixed logical raster stays the same (viewport stretch).
	if _window.size != _last_size:
		_fit()


## Exact integer fits use integer stretch; else the aspect-fit rect is filled
## with nearest sampling (fractional fits have uneven pixel widths).
func _fit() -> void:
	_last_size = _window.size
	var fit := minf(float(_window.size.x) / SIZE.x, float(_window.size.y) / SIZE.y)
	_window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER \
		if fit >= 1.0 and is_equal_approx(fit, roundf(fit)) else Window.CONTENT_SCALE_STRETCH_FRACTIONAL
