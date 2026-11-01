class_name AudioDirector
extends Node2D
## The game's sounds (presentation only, ADR-0009): what to play comes from
## the content's "sound" definitions (sounds.json), keyed by a content id and
## an event, with a general sound ("*") for everything without its own.
##   footsteps   — every character's, on the ground under its feet;
##   world       — building, taking down, doors opening and closing, by
##                 anyone, where it happens (GameClient.world_events);
##   own actions — picking up, dropping, going up and down stairs;
##   ambience    — loops mixed from the ground around the player (meadow,
##                 forest, water), quieter under a roof;
##   wind        — gusts now and then with calm between, of the ground
##                 most of around;
##   rain        — a loop as loud as it rains (ADR-0033), and thunder
##                 at a storm's lightning (WeatherView);
##   doings      — filling, pouring, eating, drinking, digging, felling,
##                 tilling, sowing, crafting, dressing (ADR-0037);
##   beasts       — rarely, by events (the author, 27.10.2026): now and then
##                 one's own call ("voice", every [lo, hi] seconds, each
##                 beast on its own), and always its blow ("attack"), the
##                 start of a hunt ("chase": a wolf howls), its death cry
##                 ("death") — the last three come as world events.
## World sounds are positional (Effects bus): far ones fade, the camera
## hears. Ambience plays on its own bus.

const VOICES := 16
## How far a sound carries, in screen pixels of the 2D listener (the camera,
## zoomed twice): about 22 cells (the author heard no beast at all at 13).
const HEARING := 700.0
## Ambience: how far around the player the ground is sampled (cells).
const AMB_RADIUS := 9
const AMB_EVERY := 0.5
const AMB_FADE := 1.5
const INDOORS_DB := -8.0
## Wind comes in gusts with calm between them (the author: calm of at least
## 15 s), the gust of the ground most of around (meadow, forest).
const WIND_CALM := Vector2(15.0, 45.0)

var content: ContentRegistry
var client: GameClient
var view: WorldView
var _voices: Array[AudioStreamPlayer2D] = []
var _next_voice := 0
var _flat: AudioStreamPlayer
## stream path -> [AudioStreamPlayer, sound definition, current weight, target weight]
var _amb := {}
var _amb_wait := 0.0
var _location := ""
var _wind: AudioStreamPlayer
var _wind_wait := 0.0
## The wind sound of the ground most of around, chosen by _listen_around().
var _wind_def := {}
## Rain (ADR-0033): a loop as loud as it rains, quieter under a roof.
var _rain: AudioStreamPlayer
var _rain_level := 0.0
var _rng := RandomNumberGenerator.new()
## Seen by MusicDirector: the share of forest around, and being indoors.
var forest_share := 0.0
var indoors := false
## Beasts heard now and then: id -> the time (s, _clock) of its next call.
var _calls := {}
var _clock := 0.0


func setup(registry: ContentRegistry, game_client: GameClient, world_view: WorldView) -> void:
	content = registry
	client = game_client
	view = world_view
	_rng.randomize()
	for i in VOICES:
		var v := AudioStreamPlayer2D.new()
		v.bus = &"Effects"
		v.max_distance = HEARING
		v.attenuation = 1.4
		add_child(v)
		_voices.append(v)
	_wind = AudioStreamPlayer.new()
	_wind.bus = &"Ambience"
	add_child(_wind)
	_wind_wait = _rng.randf_range(4.0, WIND_CALM.x)
	_rain = AudioStreamPlayer.new()
	_rain.bus = &"Ambience"
	add_child(_rain)
	_flat = AudioStreamPlayer.new()
	_flat.bus = &"Effects"
	add_child(_flat)
	_location = client.location


func _exit_tree() -> void:
	# Players freed while they play leave their streams with the audio server.
	for n: Node in get_children():
		if n is AudioStreamPlayer:
			(n as AudioStreamPlayer).stop()
		elif n is AudioStreamPlayer2D:
			(n as AudioStreamPlayer2D).stop()


## A sound of an event for a thing, at a place in the world (pixels), or
## everywhere (at = null: the player's own doing).
func play(event: String, id: String, at: Variant = null) -> void:
	var d := content.sound_of(id, event)
	if d.is_empty():
		return
	var paths: PackedStringArray = d["paths"]
	var stream := Art.audio(paths[_rng.randi() % paths.size()])
	if stream == null:
		return
	var pitch: Array = d["pitch"]
	if at == null:
		_flat.stream = stream
		_flat.volume_db = float(d["volume_db"])
		_flat.pitch_scale = _rng.randf_range(pitch[0], pitch[1])
		_flat.play()
		return
	var v := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % VOICES
	v.stream = stream
	v.global_position = at
	v.volume_db = float(d["volume_db"])
	v.pitch_scale = _rng.randf_range(pitch[0], pitch[1])
	v.play()


## Beasts near call now and then, each when its own time comes (a first call
## not before half its least wait: no chorus when one comes upon a herd).
func _beasts_call(delta: float) -> void:
	_clock += delta
	var here := {}
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") != "creature" or not e.has("x") or String(e.get("profession", "")) != "":
			continue
		var kind := String(e.get("creature", ""))
		var d := content.sound_of(kind, "voice")
		if d.is_empty() or not d.has("every"):
			continue
		here[id] = true
		var every: Array = d["every"]
		if not _calls.has(id):
			_calls[id] = _clock + _rng.randf_range(float(every[0]) * 0.25, float(every[1]) * 0.6)
		elif _clock >= float(_calls[id]):
			_calls[id] = _clock + _rng.randf_range(float(every[0]), float(every[1]))
			if not e.get("asleep", false):
				play("voice", kind, Vector2(int(e["x"]), int(e["y"])) / WorldView.UNITS_PER_PIXEL)
	for id: String in _calls.keys():
		if not here.has(id):
			_calls.erase(id)


## Whether a tree stands on a cell (a tall solid plant).
func _tree_at(location: String, cell: Vector2i) -> bool:
	var id := client.cell_at(location, cell, "cover")
	if id == "":
		return false
	var d := content.get_def(id)
	return bool(d.get("solid", false)) and float(d.get("height", 0.0)) >= 2.0


## A character's foot came down at a point (pixels).
func step_at(location: String, at: Vector2) -> void:
	if location != client.location:
		return
	var cell := Vector2i(floori(at.x / WorldView.CELL), floori((at.y - 1) / WorldView.CELL))
	play("step", view.ground_at(location, cell), at)


func _process(delta: float) -> void:
	if client == null:
		return
	for e: Dictionary in client.world_events:
		if e["location"] == client.location:
			var c: Vector2i = e["cell"]
			play(String(e["type"]), String(e["part"]), Vector2((c.x + 0.5) * WorldView.CELL, (c.y + 0.5) * WorldView.CELL))
	client.world_events.clear()
	if client.location != _location:
		if _location != "":
			play("climb", "", null)
		_location = client.location
	_amb_wait -= delta
	if _amb_wait <= 0.0 and client.has_position:
		_amb_wait = AMB_EVERY
		_listen_around()
	_blow(delta)
	_rain_on(delta)
	_beasts_call(delta)
	for path: String in _amb:
		var a: Array = _amb[path]
		a[2] = move_toward(float(a[2]), float(a[3]), delta / AMB_FADE)
		var p: AudioStreamPlayer = a[0]
		var w: float = a[2]
		p.volume_db = float((a[1] as Dictionary)["volume_db"]) + (linear_to_db(w) if w > 0.001 else -80.0) \
			+ (INDOORS_DB if indoors else 0.0)
		if w <= 0.001 and p.playing:
			p.stop()
		elif w > 0.001 and not p.playing:
			p.play(_rng.randf_range(0.0, maxf(0.0, p.stream.get_length() - 1.0)))


func _rain_on(delta: float) -> void:
	var d := content.sound_of("", "rain")
	if d.is_empty() or not client.has_time:
		return
	var want := Weather.rain(client.weather_seed, client.world_time, client.weather_place(), client.climate()) if client.z >= 0 else 0.0
	_rain_level = move_toward(_rain_level, want, delta / AMB_FADE)
	if _rain_level <= 0.01:
		if _rain.playing:
			_rain.stop()
		return
	if _rain.stream == null:
		_rain.stream = Art.audio((d["paths"] as PackedStringArray)[0], true)
	_rain.volume_db = float(d["volume_db"]) + linear_to_db(_rain_level) + (INDOORS_DB if indoors else 0.0)
	if not _rain.playing:
		_rain.play(_rng.randf_range(0.0, maxf(0.0, _rain.stream.get_length() - 1.0)))


## A gust now and then: when one has died away, calm for WIND_CALM.
func _blow(delta: float) -> void:
	if _wind.playing:
		_wind.volume_db = float(_wind_def.get("volume_db", 0.0)) + (INDOORS_DB if indoors else 0.0)
		return
	_wind_wait -= delta
	if _wind_wait > 0.0 or _wind_def.is_empty():
		return
	var paths: PackedStringArray = _wind_def["paths"]
	_wind.stream = Art.audio(paths[_rng.randi() % paths.size()])
	var pitch: Array = _wind_def["pitch"]
	_wind.pitch_scale = _rng.randf_range(pitch[0], pitch[1])
	_wind.volume_db = float(_wind_def["volume_db"]) + (INDOORS_DB if indoors else 0.0)
	_wind.play()
	_wind_wait = _rng.randf_range(WIND_CALM.x, WIND_CALM.y)


## Which ambience to hear: the surface ground around the player (also from
## a building's upper level), each loop as loud as its share of it; water
## carries far, so a little of it is heard well.
func _listen_around() -> void:
	var me := Movement.cell_of(client.position)
	# From a building's level the surface around is heard; underground only
	# the depth one is in (ADR-0017): no wind, no birds, no lake above.
	var where := client.location if client.z < 0 else Levels.SURFACE
	var counts := {}
	var defs := {}
	var total := 0
	var forest := 0
	var winds := {}
	var wind_defs := {}
	var forest_amb: Dictionary = content.sounds.get("base:forest_floor", {}).get("ambience", {})
	for dy in range(-AMB_RADIUS, AMB_RADIUS + 1, 2):
		for dx in range(-AMB_RADIUS, AMB_RADIUS + 1, 2):
			var g := view.ground_at(where, me + Vector2i(dx, dy))
			if g == "":
				continue
			total += 1
			var d: Dictionary = content.sounds.get(g, {}).get("ambience", {})
			if d.is_empty():
				continue
			var path: String = (d["paths"] as PackedStringArray)[0]
			counts[path] = int(counts.get(path, 0)) + 1
			defs[path] = d
			if g in ["base:forest_floor", "base:moss"]:
				forest += 1
			elif _tree_at(where, me + Vector2i(dx, dy)) and not forest_amb.is_empty():
				# Trees on grass are a forest too (its birds, the woodpecker).
				var fp: String = (forest_amb["paths"] as PackedStringArray)[0]
				counts[fp] = int(counts.get(fp, 0)) + 1
				defs[fp] = forest_amb
				forest += 1
			var wd: Dictionary = content.sounds.get(g, {}).get("wind", {})
			if not wd.is_empty():
				winds[wd["id"]] = int(winds.get(wd["id"], 0)) + 1
				wind_defs[wd["id"]] = wd
	forest_share = float(forest) / maxf(1.0, float(total))
	var most := ""
	for id: String in winds:
		if most == "" or int(winds[id]) > int(winds[most]):
			most = id
	_wind_def = wind_defs.get(most, {})
	indoors = not view.hidden_room().is_empty()
	for path: String in _amb:
		_amb[path][3] = 0.0
	for path: String in counts:
		var share := float(counts[path]) / maxf(1.0, float(total))
		if path.contains("water"):
			share = minf(1.0, share * 3.0)
		if not _amb.has(path):
			var p := AudioStreamPlayer.new()
			p.bus = &"Ambience"
			p.stream = Art.audio(path, true)
			p.volume_db = -80.0
			add_child(p)
			_amb[path] = [p, defs[path], 0.0, 0.0]
		_amb[path][3] = clampf(share * 1.6, 0.0, 1.0)
