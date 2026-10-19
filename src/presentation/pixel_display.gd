class_name PixelDisplay
extends Node
## Presentation only: simulation cells and WorldView's coordinates stay intact.
## HD is the default. --display=legacy is compatibility/comparison only.

const DEFAULT_MODE := "hd"
const LEGACY_SIZE := Vector2i(480, 270)
const HD_SIZE := Vector2i(960, 540)

var _window: Window
var _hd := false
var _last_size := Vector2i.ZERO


static func world_scale(mode: String) -> float:
	return 1.0 if mode == "legacy" else 2.0


func setup(window: Window, mode: String) -> void:
	_window = window
	_hd = mode != "legacy"
	if mode not in ["legacy", "hd"]:
		push_warning("Unknown display mode '%s'; using HD" % mode)
	_window.content_scale_size = HD_SIZE if _hd else LEGACY_SIZE
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	_window.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_window.snap_2d_transforms_to_pixel = _hd
	set_process(_hd)
	_fit()


func _process(_delta: float) -> void:
	# Viewport.size_changed need not fire when only the physical window changes
	# and its fixed logical raster stays the same (viewport stretch).
	if _window.size != _last_size:
		_fit()


## Exact integer fits use integer stretch. Else HD fills the aspect-fit rect
## with nearest sampling; fractional fits necessarily have uneven pixel widths.
## Legacy retains the project's original integer-only policy.
func _fit() -> void:
	_last_size = _window.size
	var logical := _window.content_scale_size
	var fit := minf(float(_window.size.x) / logical.x, float(_window.size.y) / logical.y)
	_window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER \
		if not _hd or (fit >= 1.0 and is_equal_approx(fit, roundf(fit))) \
		else Window.CONTENT_SCALE_STRETCH_FRACTIONAL
