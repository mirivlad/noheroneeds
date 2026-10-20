class_name WeatherView
extends Control
## The weather on the screen (ADR-0033), over the world and under the HUD:
## rain as falling streaks (as many as it rains hard), morning fog as a veil,
## a storm's lightning as a flash. Nothing outdoors-looking indoors (under
## the player's own ceiling) or below ground. Worked out from the weather
## seed and the time, as the server does; nothing of it is sent.

const DROPS := 520
const DROP := Color(0.78, 0.85, 1.0, 0.75)
const FOG := Color(0.82, 0.85, 0.88)
var client: GameClient
var view: WorldView
## Shown now, 0..1 (tests read them).
var rain := 0.0
var snow := 0.0
var fog := 0.0
var flash := 0.0
var _t := 0.0
var _flash_seen := -1


func setup(game_client: GameClient, world_view: WorldView) -> void:
	client = game_client
	view = world_view
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## Whether the sky is over the player now.
func outdoors() -> bool:
	return client.has_time and client.z >= 0 and view.hidden_room().is_empty()


func _process(delta: float) -> void:
	_t += delta
	var sky := outdoors()
	var seed := client.weather_seed
	var now := client.world_time
	rain = Weather.rain(seed, now) if sky else 0.0
	if rain < 0.05:
		rain = 0.0  # a few drops are no rain
	fog = Weather.fog(seed, now) if sky else 0.0
	snow = Weather.snow(seed, now) if sky else 0.0
	if snow < 0.05:
		snow = 0.0
	# Lightning: in a storm, now and then, the same for everyone at the time.
	if sky and Weather.storm(seed, now):
		var beat := int(now / (Daylight.HOUR_MS / 6.0))
		if beat != _flash_seen and absi(hash([seed, beat])) % 3 == 0:
			flash = 0.55
		_flash_seen = beat
	flash = maxf(0.0, flash - delta * 2.5)
	queue_redraw()


func _draw() -> void:
	var r := get_rect()
	if fog > 0.0:
		draw_rect(r, Color(FOG, 0.38 * fog))
	if rain > 0.0:
		draw_rect(r, Color(0.45, 0.5, 0.6, 0.14 * rain))  # the air greys in the rain
	var n := int(DROPS * minf(1.0, 0.25 + rain)) if rain > 0.0 else 0
	for i in n:
		# Each drop its own column and pace; it falls and comes round again.
		var h := absi(hash(i * 7919 + 13))
		var x := float(h % int(r.size.x + 40)) - 20.0
		var speed := 380.0 + float((h >> 8) % 160)
		var y := fmod(float((h >> 4) % 997) + _t * speed, r.size.y + 20.0) - 10.0
		var at := Vector2(roundf(x - y * 0.12), roundf(y))
		draw_line(at, at + Vector2(-1, 9), DROP, 1.0)
	# Snow (ADR-0036): flakes, slower, drifting from side to side.
	for i in int(DROPS * 0.7 * minf(1.0, 0.25 + snow)) if snow > 0.0 else 0:
		var h := absi(hash(i * 104729 + 7))
		var speed := 30.0 + float((h >> 8) % 40)
		var y := fmod(float((h >> 4) % 991) + _t * speed, r.size.y + 10.0) - 5.0
		var x := fmod(float(h % int(r.size.x + 20)) + sin(_t * 1.3 + float(h % 97)) * 6.0, r.size.x + 20.0) - 10.0
		var big := (h >> 3) % 3 == 0
		draw_rect(Rect2(roundf(x), roundf(y), 2 if big else 1, 2 if big else 1), Color(1, 1, 1, 0.85))
	if flash > 0.0:
		draw_rect(r, Color(1, 1, 1, flash))
