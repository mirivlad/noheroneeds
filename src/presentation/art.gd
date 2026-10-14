class_name Art
extends RefCounted
## Shared look of the screens: pictures (loaded once), the pixel font and
## the interface theme of ART_STANDARD 10 — a dark warm base, light warm
## text, a thin frame.

const FONT_PATH := "res://assets/fonts/monogram.ttf"
const TEXT := Color("f2e6c8")
const TEXT_DIM := Color("b8a888")
const TEXT_HOT := Color("ffe2a0")
const INK := Color("1e1824")
const PANEL := Color(0.118, 0.094, 0.141, 0.94)
const BUTTON := Color("2c2230")
const BUTTON_HOT := Color("45343a")
const BUTTON_DOWN := Color("5a4232")
const FRAME := Color("6b5440")
const FRAME_HOT := Color("c8a060")

static var _textures := {}
static var _sounds := {}
static var _theme: Theme


## A picture by path. Run from the sources, PNGs are read from their files,
## never from the import cache, which is missing or stale after a pull until
## something imports again (the editor or tools/run_game.sh).
static func texture(path: String) -> Texture2D:
	if not _textures.has(path):
		if path.begins_with("res://") and not _from_source(path):
			_textures[path] = load(path)
		else:
			var img := Image.new()
			img.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
			var t := ImageTexture.create_from_image(img)
			t.resource_name = path  # where it came from
			_textures[path] = t
	return _textures[path]


## A sound by path (WAV, OGG, MP3), the same way as pictures: from the file
## itself when run from the sources. loop: plays around (ambience, music).
static func audio(path: String, loop := false) -> AudioStream:
	var key := path + ("#loop" if loop else "")
	if _sounds.has(key):
		return _sounds[key]
	var s: AudioStream
	if not OS.has_feature("editor") and ResourceLoader.exists(path):
		s = load(path)
	elif FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		match path.get_extension().to_lower():
			"wav":
				s = AudioStreamWAV.load_from_buffer(bytes)
			"ogg":
				s = AudioStreamOggVorbis.load_from_buffer(bytes)
			"mp3":
				s = AudioStreamMP3.load_from_buffer(bytes)
	if s:
		s.resource_name = path  # where it came from
	if s and loop:
		s = s.duplicate()
		if s is AudioStreamWAV:
			var w := s as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(w.get_length() * w.mix_rate)
		elif s is AudioStreamOggVorbis:
			(s as AudioStreamOggVorbis).loop = true
		elif s is AudioStreamMP3:
			(s as AudioStreamMP3).loop = true
	_sounds[key] = s
	return s


## Lets go of the cached pictures, sounds, font and theme (at exit, so
## nothing is held when the engine shuts down).
static func clear() -> void:
	_textures.clear()
	_sounds.clear()
	_theme = null


static func _from_source(path: String) -> bool:
	return OS.has_feature("editor") and FileAccess.file_exists(path) and path.get_extension().to_lower() == "png"


static func font() -> Font:
	return load(FONT_PATH)


static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = 16
	for type in ["Label", "Button", "CheckBox", "OptionButton", "LineEdit", "SpinBox", "PopupMenu", "TooltipLabel"]:
		t.set_color("font_color", type, TEXT)
		t.set_color("font_outline_color", type, INK)
	for type in ["Button", "CheckBox", "OptionButton"]:
		t.set_color("font_hover_color", type, TEXT_HOT)
		t.set_color("font_pressed_color", type, TEXT_HOT)
		t.set_color("font_focus_color", type, TEXT_HOT)
		t.set_color("font_hover_pressed_color", type, TEXT_HOT)
		t.set_color("font_disabled_color", type, Color(TEXT_DIM, 0.5))
	t.set_constant("outline_size", "Label", 2)
	for type in ["Button", "OptionButton"]:
		t.set_stylebox("normal", type, _box(BUTTON, FRAME))
		t.set_stylebox("hover", type, _box(BUTTON_HOT, FRAME_HOT))
		t.set_stylebox("pressed", type, _box(BUTTON_DOWN, FRAME_HOT))
		t.set_stylebox("focus", type, _box(Color(0, 0, 0, 0), FRAME_HOT))
		t.set_stylebox("disabled", type, _box(Color(BUTTON, 0.5), Color(FRAME, 0.5)))
	for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		t.set_stylebox(st, "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("normal", "LineEdit", _box(Color("161219"), FRAME))
	t.set_stylebox("focus", "LineEdit", _box(Color(0, 0, 0, 0), FRAME_HOT))
	t.set_stylebox("read_only", "LineEdit", _box(Color("161219"), Color(FRAME, 0.5)))
	t.set_color("caret_color", "LineEdit", TEXT_HOT)
	t.set_color("font_placeholder_color", "LineEdit", Color(TEXT_DIM, 0.6))
	t.set_color("selection_color", "LineEdit", Color(FRAME_HOT, 0.4))
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, FRAME, 6))
	t.set_stylebox("panel", "PopupMenu", _box(Color("1a1520"), FRAME, 3))
	t.set_stylebox("hover", "PopupMenu", _box(BUTTON_HOT, Color(0, 0, 0, 0)))
	t.set_color("font_hover_color", "PopupMenu", TEXT_HOT)
	t.set_stylebox("panel", "TooltipPanel", _box(Color("1a1520"), FRAME, 3))
	t.set_stylebox("slider", "HSlider", _box(Color("161219"), FRAME, 0, 3))
	t.set_stylebox("grabber_area", "HSlider", _box(Color("8a6a40"), Color(0, 0, 0, 0), 0, 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(Color("c8a060"), Color(0, 0, 0, 0), 0, 3))
	t.set_icon("grabber", "HSlider", _square(8, TEXT))
	t.set_icon("grabber_highlight", "HSlider", _square(8, TEXT_HOT))
	t.set_icon("checked", "CheckBox", _check(true))
	t.set_icon("unchecked", "CheckBox", _check(false))
	t.set_icon("checked", "PopupMenu", _check(true))
	t.set_icon("unchecked", "PopupMenu", _check(false))
	t.set_icon("radio_checked", "PopupMenu", _check(true))
	t.set_icon("radio_unchecked", "PopupMenu", _check(false))
	t.set_constant("h_separation", "CheckBox", 6)
	t.set_constant("separation", "VBoxContainer", 3)
	t.set_constant("separation", "HBoxContainer", 4)
	_theme = t
	return t


static func _box(fill: Color, frame: Color, margin := 4, height := -1) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = frame
	b.set_border_width_all(1 if frame.a > 0 else 0)
	b.content_margin_left = margin
	b.content_margin_right = margin
	b.content_margin_top = maxi(1, margin / 2)
	b.content_margin_bottom = maxi(1, margin / 2)
	if height > 0:
		b.content_margin_top = height / 2.0
		b.content_margin_bottom = height / 2.0
	return b


static func _square(size: int, c: Color) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(c)
	for i in size:
		for e in [0, size - 1]:
			img.set_pixel(i, e, INK)
			img.set_pixel(e, i, INK)
	return ImageTexture.create_from_image(img)


static func _check(on: bool) -> Texture2D:
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color("161219"))
	for i in 10:
		for e in [0, 9]:
			img.set_pixel(i, e, FRAME)
			img.set_pixel(e, i, FRAME)
	if on:
		for y in range(3, 7):
			for x in range(3, 7):
				img.set_pixel(x, y, TEXT_HOT)
	return ImageTexture.create_from_image(img)


## Small pixel icons for buttons: "play" (a triangle), "server" (a rack with
## lights), "back" (an arrow).
static func icon(kind: String) -> Texture2D:
	var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	match kind:
		"play":
			for y in range(1, 11):
				var w := 5 - absi(y - 5) if y <= 5 else 5 - (y - 6)
				for x in range(3, 3 + clampi(w * 2, 0, 8)):
					img.set_pixel(x, y, TEXT)
		"server":
			for rack in [1, 5]:
				for y in range(rack, rack + 4):
					for x in range(1, 11):
						img.set_pixel(x, y, FRAME_HOT if y == rack or y == rack + 3 or x == 1 or x == 10 else BUTTON)
				img.set_pixel(8, rack + 1, Color("7ad070"))
				img.set_pixel(8, rack + 2, Color("7ad070"))
			for x in range(4, 8):
				img.set_pixel(x, 10, TEXT_DIM)
			img.set_pixel(5, 9, TEXT_DIM)
			img.set_pixel(6, 9, TEXT_DIM)
	return ImageTexture.create_from_image(img)
