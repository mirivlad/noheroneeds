class_name MusicDirector
extends Node
## Background music (the author's tracks) by mood, as in Dust City: a mood's
## tracks play in turn with silence between them, a change of mood fades
## over. Tracks are files in a pack's music/<mood>/ (ogg, mp3, wav), found
## at start: adding music is dropping files in, nothing to edit.
##   explore — open country by day (the default);
##   forest  — among trees;
##   home    — indoors, under one's own roof.
## A mood without tracks falls back to explore; no tracks at all: silence.
## Presentation only: nothing here is saved or seeded.

const MOODS := ["explore", "forest", "home", "night", "danger"]
const GAP_S := Vector2(40.0, 150.0)
const FIRST_S := Vector2(4.0, 12.0)
const FADE_OUT_S := 4.0
const FADE_IN_S := 3.0
## A mood must hold this long before the music follows it.
const SETTLE_S := 8.0

var tracks := {}
var mood := ""
var phase := "gap"
var _wait := 0.0
var _wanted := ""
var _wanted_for := 0.0
var _next := {}
var _player: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()


func setup(registry: ContentRegistry) -> void:
	_rng.randomize()
	for pid: String in registry.packs:
		var dir: String = registry.packs[pid].get("dir", "")
		for m: String in MOODS:
			var md := dir.path_join("music").path_join(m)
			if not DirAccess.dir_exists_absolute(md):
				continue
			for f in DirAccess.get_files_at(md):
				var ext := f.get_extension().to_lower()
				if ext in ["ogg", "mp3", "wav"]:
					(tracks.get_or_add(m, []) as Array).append(md.path_join(f))
	for m: String in tracks:
		(tracks[m] as Array).sort()
	_player = _new_player()
	_wait = _rng.randf_range(FIRST_S.x, FIRST_S.y)


func _new_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = &"Music"
	p.finished.connect(_on_finished.bind(p))
	add_child(p)
	return p


## The mood the place calls for; the music follows once it has held a while.
func want(m: String) -> void:
	if not tracks.has(m):
		m = "explore"
	if m != _wanted:
		_wanted = m
		_wanted_for = 0.0


func _process(delta: float) -> void:
	if tracks.is_empty():
		return
	_wanted_for += delta
	if _wanted != "" and _wanted != mood and (mood == "" or _wanted_for >= SETTLE_S):
		var was_playing := phase == "playing"
		mood = _wanted
		if was_playing:
			_fade_out()
			_start()
	if phase == "gap":
		_wait -= delta
		if _wait <= 0.0:
			_start()


func _start() -> void:
	var list: Array = tracks.get(mood, tracks.get("explore", []))
	if list.is_empty():
		phase = "gap"
		_wait = GAP_S.y
		return
	var i := int(_next.get(mood, 0))
	_next[mood] = (i + 1) % list.size()
	_player.stream = Art.audio(String(list[i]))
	_player.volume_db = -40.0
	_player.play()
	create_tween().tween_property(_player, "volume_db", 0.0, FADE_IN_S)
	phase = "playing"


func _fade_out() -> void:
	if _player.playing:
		var old := _player
		_player = _new_player()
		var tw := create_tween()
		tw.tween_property(old, "volume_db", -60.0, FADE_OUT_S)
		tw.tween_callback(old.queue_free)


func _on_finished(p: AudioStreamPlayer) -> void:
	if p == _player:
		phase = "gap"
		_wait = _rng.randf_range(GAP_S.x, GAP_S.y)
