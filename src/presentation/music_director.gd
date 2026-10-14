class_name MusicDirector
extends Node
## Background music (the author's tracks) by mood. One director for the whole
## application (App): the start screen and the game share it, so a track
## goes on across them. Tracks are files in a pack's music/<mood>/ (ogg, mp3,
## wav), found at start: adding music is dropping files in.
##
## Moods (the game tells which, App passes it on):
##   danger  — something threatens (combat, step 10);
##   home    — under a roof, in a room, on a building's level;
##   night   — outdoors at night;
##   explore — outdoors by day, in fields and woods alike (the forest folder's
##             tracks play here too); also the start screen ("menu").
##
## Never abrupt (the author: no sharp changes between melodies):
##   * two melodies never sound together: the old one fades out (6 s), a
##     short silence, the new one fades in (5 s);
##   * a mood must hold for SETTLE_S before the music follows it;
##   * a track with less than LET_FINISH_S left plays to its end;
##   * every track fades in, even if its file starts loud, and fades out in
##     its last seconds;
##   * between tracks of one mood: silence of 30-90 s; when the mood changes
##     during a silence, the new mood's track comes after 3-8 s.
##   Danger comes and goes quicker (a threat does not wait).
## Time is counted here (not read from the audio driver), so the behaviour is
## the same with any driver and can be tested.

const MOODS := ["explore", "forest", "home", "night", "danger"]
## Folders whose tracks play under another mood. Forest and open country are
## one mood (the author: walking through woods and glades must not keep
## changing the melody); the forest tracks join the explore rotation.
const SHARED := {"forest": "explore"}
const GAP_S := Vector2(30.0, 90.0)
const MOOD_GAP_S := Vector2(3.0, 8.0)
const AFTER_FADE_S := Vector2(2.0, 4.0)
const FIRST_S := Vector2(1.0, 3.0)
const FADE_IN_S := 5.0
const FADE_OUT_S := 6.0
const END_FADE_S := 4.0
const LET_FINISH_S := 25.0
const SETTLE_S := 10.0
const DANGER_SETTLE_S := 1.0
const DANGER_FADE_S := 2.5
const SILENT_DB := -40.0

var tracks := {}
## The mood the music plays now ("" before the first track).
var mood := ""
## silent | playing | fading
var phase := "silent"
var track := ""
var _wait := 0.0
var _wanted := ""
var _wanted_for := 0.0
var _next := {}
var _player: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _length := 0.0
## A volume ramp in progress: [from_db, to_db, elapsed, duration].
var _ramp := []
## The mood turned while the track played out: the next comes soon.
var _mood_turned := false


func setup(registry: ContentRegistry) -> void:
	_rng.randomize()
	var by_folder := {}
	for pid: String in registry.packs:
		var dir: String = registry.packs[pid].get("dir", "")
		for m: String in MOODS:
			var md := dir.path_join("music").path_join(m)
			if not DirAccess.dir_exists_absolute(md):
				continue
			for f in DirAccess.get_files_at(md):
				if f.get_extension().to_lower() in ["ogg", "mp3", "wav"]:
					(by_folder.get_or_add(m, []) as Array).append(md.path_join(f))
	# Each mood: its own folder's tracks, interleaved with the folders that
	# share it (field, forest, field, forest...), its own first.
	for m: String in MOODS:
		if SHARED.has(m) or not by_folder.has(m):
			continue
		var lists: Array = [by_folder[m]]
		for f: String in SHARED:
			if SHARED[f] == m and by_folder.has(f):
				lists.append(by_folder[f])
		var mixed := []
		for l: Array in lists:
			l.sort()
		for i in lists.map(func(l: Array) -> int: return l.size()).max():
			for l: Array in lists:
				if i < l.size():
					mixed.append(l[i])
		tracks[m] = mixed
		_next[m] = _rng.randi() % (tracks[m] as Array).size()
	_next["explore"] = 0  # the start screen opens with the first (quiet) explore track
	_player = AudioStreamPlayer.new()
	_player.bus = &"Music"
	add_child(_player)
	_wait = _rng.randf_range(FIRST_S.x, FIRST_S.y)


func _exit_tree() -> void:
	silence()


## Stops at once (leaving the game): a player freed while it plays leaves
## its stream with the audio server.
func silence() -> void:
	if _player:
		_player.stop()
		_player.stream = null


## The mood called for now; "menu" is the start screen.
func want(m: String) -> void:
	if m == "menu" or not tracks.has(m):
		m = "explore"
	if m != _wanted:
		_wanted = m
		_wanted_for = 0.0


func _process(delta: float) -> void:
	if tracks.is_empty():
		return
	_wanted_for += delta
	var settle := DANGER_SETTLE_S if _wanted == "danger" or mood == "danger" else SETTLE_S
	var change := _wanted != "" and _wanted != mood and (mood == "" or _wanted_for >= settle)
	_apply_ramp(delta)
	match phase:
		"playing":
			_time += delta
			var left := _length - _time
			if left <= END_FADE_S and (_ramp.is_empty() or float(_ramp[1]) > SILENT_DB):
				_ramp_to(SILENT_DB, maxf(0.1, left))
			if left <= 0.0:
				_stop()
				var gap := MOOD_GAP_S if _mood_turned else GAP_S
				_wait = _rng.randf_range(gap.x, gap.y) if mood != "danger" else 0.5
				_mood_turned = false
			elif change:
				if left <= LET_FINISH_S and _wanted != "danger" and mood != "danger":
					mood = _wanted  # this one plays out; the next is of the new mood
					_mood_turned = true
				else:
					var fade := DANGER_FADE_S if _wanted == "danger" else (FADE_OUT_S + 2.0 if mood == "danger" else FADE_OUT_S)
					_ramp_to(SILENT_DB - 20.0, fade)
					phase = "fading"
					mood = _wanted
		"fading":
			_time += delta
			if _ramp.is_empty():
				_stop()
				_wait = _rng.randf_range(AFTER_FADE_S.x, AFTER_FADE_S.y) if mood != "danger" else 0.3
		"silent":
			if change:
				var was := mood
				mood = _wanted
				if was != "":
					_wait = minf(_wait, _rng.randf_range(MOOD_GAP_S.x, MOOD_GAP_S.y) if mood != "danger" else 0.3)
			if mood == "" and _wanted != "":
				mood = _wanted
			_wait -= delta
			if _wait <= 0.0 and mood != "":
				_start()


func _start() -> void:
	var list: Array = tracks.get(mood, [])
	if list.is_empty():
		_wait = GAP_S.x
		return
	var i := int(_next.get(mood, 0)) % list.size()
	_next[mood] = (i + 1) % list.size()
	track = String(list[i])
	var stream := Art.audio(track)
	_length = stream.get_length() if stream else 0.0
	_time = 0.0
	if _player and stream:
		_player.stream = stream
		_player.volume_db = SILENT_DB
		_player.play()
	_ramp = [SILENT_DB, 0.0, 0.0, FADE_IN_S if mood != "danger" else DANGER_FADE_S]
	phase = "playing"


func _stop() -> void:
	if _player:
		_player.stop()
	_ramp = []
	track = ""
	phase = "silent"


func _ramp_to(db: float, sec: float) -> void:
	var now := _player.volume_db if _player else 0.0
	_ramp = [now, db, 0.0, sec]


func _apply_ramp(delta: float) -> void:
	if _ramp.is_empty():
		return
	_ramp[2] = float(_ramp[2]) + delta
	var k := clampf(float(_ramp[2]) / maxf(0.001, float(_ramp[3])), 0.0, 1.0)
	if _player:
		_player.volume_db = lerpf(float(_ramp[0]), float(_ramp[1]), k)
	if k >= 1.0:
		_ramp = []
