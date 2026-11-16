class_name WeatherView
extends Control
## The weather on the screen (ADR-0033), over the world and under the HUD:
## rain as falling streaks (as many as it rains hard), morning fog as a veil,
## a storm's lightning as a flash. Nothing outdoors-looking indoors (under
## the player's own ceiling) or below ground. Worked out from the weather
## seed and the time, as the server does; nothing of it is sent.

## A flash of lightning began (the audio's thunder answers it).
signal lightning
const DROPS := 280
const DROP := Color(0.67, 0.76, 0.80, 0.30)
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
var _fog_texture: GradientTexture2D


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
	var here := client.weather_place()
	var climate := client.climate()
	rain = Weather.rain(seed, now, here, climate) if sky else 0.0
	if rain < 0.05:
		rain = 0.0  # a few drops are no rain
	fog = Weather.fog(seed, now, here, climate) if sky else 0.0
	snow = Weather.snow(seed, now, here, climate) if sky else 0.0
	if snow < 0.05:
		snow = 0.0
	# Lightning: in a storm, now and then, the same for everyone at the time.
	if sky and Weather.storm(seed, now, here, climate):
		var beat := int(now / (Daylight.HOUR_MS / 6.0))
		if beat != _flash_seen and absi(hash([seed, beat])) % 3 == 0 and _flash_seen >= 0:
			flash = 0.55
			lightning.emit()
		_flash_seen = beat
	flash = maxf(0.0, flash - delta * 2.5)
	queue_redraw()


func _draw() -> void:
	var r := get_rect()
	if fog > 0.0:
		# Broad drifting banks, with a much thinner veil over the actor at centre.
		draw_rect(r, Color(FOG, 0.055 * fog))
		if _fog_texture == null:
			_fog_texture = GradientTexture2D.new()
			_fog_texture.width = 64
			_fog_texture.height = 64
			_fog_texture.fill = GradientTexture2D.FILL_RADIAL
			_fog_texture.fill_from = Vector2(.5, .5)
			_fog_texture.fill_to = Vector2(1, .5)
			_fog_texture.gradient = Gradient.new()
			_fog_texture.gradient.set_color(0, Color.WHITE)
			_fog_texture.gradient.set_color(1, Color(1, 1, 1, 0))
		for i in 3:
			var size := Vector2(r.size.x * .85, r.size.y * .65)
			var at := Vector2(r.size.x * (i * .42 - .18) + sin(_t * .06 + i) * 35, r.size.y * (-.25 if i % 2 == 0 else .7))
			draw_texture_rect(_fog_texture, Rect2(at, size), false, Color(FOG, .16 * fog))
	if rain > 0.0: draw_rect(r, Color(0.36, 0.43, 0.48, 0.055 * rain))
	for i in int(DROPS * rain):
		var h := absi(hash(i * 7919 + 13))
		var depth := float(h % 101) / 100.0
		var x := float(h % int(r.size.x + 40)) - 20.0
		# Sparse sheets move through the view, rather than a uniform white hatch.
		if sin(x * .013 + _t * .21) + depth < -.25: continue
		var speed := 240.0 + depth * 220.0
		var y := fmod(float((h >> 4) % 997) + _t * speed, r.size.y + 20.0) - 10.0
		var at := Vector2(x - y * .09, y)
		var length := 2.0 + depth * 5.0
		draw_line(at, at + Vector2(-length * .12, length), Color(DROP, .10 + depth * .20), 1.0)
	# Fewer near flakes, fine distant specks: no opaque all-screen curtain.
	for i in int(180 * snow):
		var h := absi(hash(i * 104729 + 7))
		var depth := float(h % 101) / 100.0
		var speed := 18.0 + depth * 38.0
		var y := fmod(float((h >> 4) % 991) + _t * speed, r.size.y + 10.0) - 5.0
		var x := fmod(float(h % int(r.size.x + 20)) + sin(_t * .8 + float(h % 97)) * (3.0 + depth * 7.0), r.size.x + 20.0) - 10.0
		var width := 2.0 if depth > .8 else 1.0
		draw_rect(Rect2(roundf(x), roundf(y), width, width), Color(.88, .93, .94, .30 + depth * .4))
	if flash > 0.0:
		draw_rect(r, Color(1, 1, 1, flash))
