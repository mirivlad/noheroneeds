class_name GameSettings
extends RefCounted
## The player's own settings (not a world's rules): screen, sound, view,
## hints, the server port offered by default. Kept in settings.cfg of the
## profile; unknown or broken values fall back to the defaults.

const DEFAULTS := {
	"fullscreen": false,
	"vsync": true,
	"volume": 0.8,
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
}

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
	s.values["volume"] = clampf(float(s.values["volume"]), 0.0, 1.0)
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
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if values["fullscreen"]
			else DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if values["vsync"]
			else DisplayServer.VSYNC_DISABLED)
	var v := float(values["volume"])
	AudioServer.set_bus_volume_db(0, linear_to_db(v) if v > 0.0 else -80.0)
	AudioServer.set_bus_mute(0, v <= 0.0)
