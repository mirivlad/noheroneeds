class_name GameSettings
extends RefCounted
## The player's own settings (not a world's rules): screen, sound, view,
## hints, the server port offered by default. Kept in settings.cfg of the
## profile; unknown or broken values fall back to the defaults.

const DEFAULTS := {
	"experiment_3d_yaw": 0.0,
	"experiment_3d_tilt": 55.0,
	"experiment_3d_zoom": 16.875,
	"fullscreen": false,
	"vsync": true,
	"volume": 0.8,
	"music_volume": 0.7,
	"effects_volume": 0.8,
	"ambience_volume": 0.7,
	## 1.0: the standard view; 0.75: farther out (640 x 360 of the world on the
	## same pixels, ADR-0001: for roofs and sieges).
	"view_zoom": 1.0,
	"show_fps": false,
	"show_hints": true,
	"server_port": 24680,
	## The last server joined, "host:port".
	"last_address": "127.0.0.1:24680",
	"max_players": 8,
	## The character played (file id in the character library).
	"character": "",
	## Quick slots of each character (ADR-0021): character id -> [item id, ...].
	"hotbars": {},
	## Cells of each character's bag (ADR-0041): character id -> [item id or "", ...].
	"bags": {},
}

## Volume setting -> audio bus (default_bus_layout.tres).
const BUSES := {"volume": "Master", "music_volume": "Music", "effects_volume": "Effects", "ambience_volume": "Ambience"}

var path := ""
var values := DEFAULTS.duplicate()


static func load_from(file_path: String) -> GameSettings:
	var s := GameSettings.new()
	s.path = file_path
	var cfg := ConfigFile.new()
	if cfg.load(file_path) == OK:
		for key: String in DEFAULTS:
			var v: Variant = cfg.get_value("settings", key, DEFAULTS[key])
			# A value of the wrong kind (edited by hand) keeps the default.
			if typeof(v) == typeof(DEFAULTS[key]) or (typeof(DEFAULTS[key]) == TYPE_FLOAT and typeof(v) == TYPE_INT):
				s.values[key] = v
	for key: String in BUSES:
		s.values[key] = clampf(float(s.values[key]), 0.0, 1.0)
	s.values["view_zoom"] = 0.75 if float(s.values["view_zoom"]) < 0.9 else 1.0
	s.values["server_port"] = clampi(int(s.values["server_port"]), 1024, 65535)
	s.values["max_players"] = clampi(int(s.values["max_players"]), 1, 64)
	return s


func get_value(key: String) -> Variant:
	return values.get(key, DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	values[key] = value


func save() -> bool:
	var cfg := ConfigFile.new()
	for key: String in values:
		cfg.set_value("settings", key, values[key])
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return cfg.save(path) == OK


## Puts the screen and sound settings into effect.
func apply() -> void:
	if DisplayServer.get_name() != "headless":
		# Only what changed: setting the window mode again (windowed over
		# windowed) makes the window take its first size, so any change in
		# the settings used to resize a maximised or stretched window.
		var mode := DisplayServer.window_get_mode()
		var full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
		if values["fullscreen"] and not full:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		elif not values["fullscreen"] and full:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var vsync := DisplayServer.VSYNC_ENABLED if values["vsync"] else DisplayServer.VSYNC_DISABLED
		if DisplayServer.window_get_vsync_mode() != vsync:
			DisplayServer.window_set_vsync_mode(vsync)
	for key: String in BUSES:
		var idx := AudioServer.get_bus_index(BUSES[key])
		if idx < 0:
			continue
		var v := float(values[key])
		AudioServer.set_bus_volume_db(idx, linear_to_db(v) if v > 0.0 else -80.0)
		AudioServer.set_bus_mute(idx, v <= 0.0)
