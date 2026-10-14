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
##                 forest, water), quieter under a roof.
## World sounds are positional (Effects bus): far ones fade, the camera
## hears. Ambience plays on its own bus.

const VOICES := 16
const HEARING := 420.0
## Ambience: how far around the player the ground is sampled (cells).
const AMB_RADIUS := 9
const AMB_EVERY := 0.5
const AMB_FADE := 1.5
const INDOORS_DB := -8.0

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
var _rng := RandomNumberGenerator.new()
## Seen by MusicDirector: the share of forest around, and being indoors.
var forest_share := 0.0
var indoors := false


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
	_flat = AudioStreamPlayer.new()
	_flat.bus = &"Effects"
	add_child(_flat)
	_location = client.location


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


## Which ambience to hear: the surface ground around the player (also from
## a building's upper level), each loop as loud as its share of it; water
## carries far, so a little of it is heard well.
func _listen_around() -> void:
	var me := Movement.cell_of(client.position)
	var counts := {}
	var defs := {}
	var total := 0
	var forest := 0
	for dy in range(-AMB_RADIUS, AMB_RADIUS + 1, 2):
		for dx in range(-AMB_RADIUS, AMB_RADIUS + 1, 2):
			var g := view.ground_at(Levels.SURFACE, me + Vector2i(dx, dy))
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
	forest_share = float(forest) / maxf(1.0, float(total))
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
