class_name WeatherView
extends Control
## The weather on the screen (ADR-0033), over the world and under the HUD:
## rain as falling streaks (as many as it rains hard), morning fog as a veil,
## a storm's lightning as a flash. Nothing outdoors-looking indoors (under
## the player's own ceiling) or below ground. Worked out from the weather
## seed and the time, as the server does; nothing of it is sent.

## A flash of lightning began (the audio's thunder answers it).
signal lightning
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
	if client.has_time and client.z >= 0:
		_draw_life(r)
	if flash > 0.0:
		draw_rect(r, Color(1, 1, 1, flash))


## Life over the land (presentation only), by what lies there: each tile of
## the world in sight looks at the ground and plant of its cell ("ambient"):
## fireflies at night over grass and moss, mist over bog and mud, snow
## drifting over snow, leaves falling from maples. Where each one is comes
## from its tile, so it stays put as the view moves.
const LIFE_TILE := 32
func _draw_life(r: Rect2) -> void:
	if view is WorldView3D:
		return  # Existing rain/snow remain screen-space; 2D world motes do not.
	var xf := view.get_global_transform_with_canvas()
	var seen := xf.affine_inverse() * r  # the world in sight, in world pixels
	var zoom := xf.get_scale().x
	var night := Daylight.is_night(client.world_time)
	var dim := 1.0 - 0.6 * rain
	var x0 := floori(seen.position.x / LIFE_TILE)
	var y0 := floori(seen.position.y / LIFE_TILE)
	for ty in range(y0, floori(seen.end.y / LIFE_TILE) + 1):
		for tx in range(x0, floori(seen.end.x / LIFE_TILE) + 1):
			var h := absi(hash([tx, ty, 31]))
			var cell := Vector2i(tx * 2 + (h % 2), ty * 2 + ((h >> 1) % 2))
			for kind: String in _life_at(cell):
				var base := Vector2(tx * LIFE_TILE + (h >> 2) % LIFE_TILE, ty * LIFE_TILE + (h >> 7) % LIFE_TILE)
				match kind:
					"fireflies":
						if not night or (h >> 12) % 3 != 0:
							continue
						var at := base + Vector2(sin(_t * 0.7 + h % 13) * 6.0, cos(_t * 0.9 + h % 7) * 4.0)
						var glow := maxf(0.0, sin(_t * 2.2 + float(h % 50)))
						if glow > 0.05:
							var p := (xf * at).round()
							_soft_at(p + Vector2(zoom, zoom) * 0.5, zoom * 7.0, Color(0.85, 1.0, 0.45, 0.35 * glow * dim))
							draw_rect(Rect2(p, Vector2(zoom, zoom)), Color(0.92, 1.0, 0.6, glow * dim))
					"mist":
						var at := base + Vector2(fmod(_t * 3.0 + h % 40, 40.0) - 20.0, 0)
						var a := (0.22 if night else 0.14) * (0.6 + 0.4 * sin(_t * 0.4 + h % 11))
						_soft_at(xf * at, zoom * (36.0 + h % 20), Color(0.82, 0.88, 0.85, a))
					"drift":
						if (h >> 12) % 2 != 0:
							continue
						var run := fmod(_t * 40.0 + float(h % 97), 64.0)
						var at := Vector2(tx * LIFE_TILE - 16 + run, base.y + sin(_t + h % 5) * 2.0)
						var p := (xf * at).round()
						draw_line(p, p + Vector2(zoom * 3.0, 0), Color(1, 1, 1, 0.45 * (1.0 - run / 64.0)), zoom * 0.5)
					"leaves":
						for k in 2:
							var hk := absi(hash([h, k]))
							var fall := fmod(_t * (8.0 + hk % 6) + hk % 50, 40.0)
							var at := base + Vector2(sin(_t * 1.6 + hk % 9) * 4.0 + k * 9, -24.0 + fall)
							var p := (xf * at).round()
							var c := Color(0.95, 0.5 + 0.2 * (hk % 3) / 2.0, 0.15, 0.9 * (1.0 - fall / 40.0))
							draw_rect(Rect2(p, Vector2(zoom, zoom)), c)


## A soft round patch of light or mist, `size` across, centred on `at`.
func _soft_at(at: Vector2, size: float, color: Color) -> void:
	draw_texture_rect(Effects.soft(), Rect2(at - Vector2(size, size) * 0.5, Vector2(size, size)), false, color)


## What lives over a cell: the ambient of its ground and of its plant.
func _life_at(cell: Vector2i) -> Array:
	var c: Chunk = client.chunks.get(ServerWorld.chunk_key(client.location, cell.x >> 5, cell.y >> 5))
	if c == null:
		return []
	var out := []
	for layer: String in ["ground", "cover"]:
		var id := c.get_cell(layer, cell.x & 31, cell.y & 31)
		if id != "":
			var a := String(view.content.get_def(id).get("ambient", ""))
			if a != "":
				out.append(a)
	return out
