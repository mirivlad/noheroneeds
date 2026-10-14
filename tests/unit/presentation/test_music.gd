extends TestCase
## Music by mood without abrupt changes (the author's rule): the director
## driven by time, the volume watched step by step.

var m: MusicDirector
var _last_db := 0.0
var _worst_jump := 0.0


func before_each() -> void:
	m = MusicDirector.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(m)
	m.setup(ContentRegistry.load_packs(["res://content/base"]))
	_worst_jump = 0.0


func after_each() -> void:
	m.free()
	for i in 3:
		await (Engine.get_main_loop() as SceneTree).process_frame


## Advances time; returns the phases seen. Watches that the volume never
## jumps (an abrupt start or stop) while a track sounds.
func _run(sec: float, dt := 0.1) -> Array:
	var phases := []
	for i in int(sec / dt):
		var before_track := m.track
		m._process(dt)
		var db := m._player.volume_db
		if m.track != "" and m.track == before_track:
			_worst_jump = maxf(_worst_jump, absf(db - _last_db))
		_last_db = db
		if phases.is_empty() or phases[-1] != m.phase:
			phases.append(m.phase)
	return phases


func test_the_start_screen_opens_softly_with_the_first_explore_track() -> void:
	check(m.tracks.size() == 5, "five moods of the author's: %s" % [m.tracks.keys()])
	m.want("menu")
	_run(3.5)
	check(m.track.ends_with("explore/morning_light_trail.ogg"), "the quiet one first: " + m.track)
	check(m._player.volume_db < -10.0, "fading in, not loud at once: %.1f dB" % m._player.volume_db)
	_run(5.0)
	check(absf(m._player.volume_db) < 0.5, "full after the fade-in")
	check(_worst_jump < 2.0, "no jump in volume: %.2f dB a step" % _worst_jump)


func test_a_mood_change_fades_out_pauses_and_fades_in() -> void:
	m.want("explore")
	_run(20.0)
	var first := m.track
	m.want("forest")
	var phases := _run(30.0)
	eq(phases.slice(0, 4), ["playing", "fading", "silent", "playing"], "out, a pause, in")
	check(m.track.contains("/forest/"), "now the forest: " + m.track)
	check(first != m.track, "another track")
	check(_worst_jump < 2.0, "never abrupt: %.2f dB a step" % _worst_jump)


func test_a_short_change_of_place_does_not_change_the_music() -> void:
	m.want("explore")
	_run(15.0)
	var playing := m.track
	m.want("home")
	_run(6.0)  # a minute's visit would be longer; this is less than SETTLE_S
	m.want("explore")
	_run(20.0)
	eq(m.track, playing, "the same track goes on")
	eq(m.phase, "playing")


func test_a_track_near_its_end_plays_out_and_the_next_is_of_the_new_mood() -> void:
	m.want("explore")
	_run(3.0)
	_run(m._length - m._time - 20.0)  # 20 s before the end
	var playing := m.track
	m.want("home")
	_run(15.0)
	eq(m.track, playing, "it plays out")
	check(m._player.volume_db > -1.0 or m._length - m._time < MusicDirector.END_FADE_S, "not cut")
	_run(5.0 + MusicDirector.MOOD_GAP_S.y + MusicDirector.FADE_IN_S)
	check(m.track.contains("/home/"), "then home, soon: " + m.track)
	check(_worst_jump < 2.0, "never abrupt: %.2f dB a step" % _worst_jump)


func test_danger_comes_quickly_and_leaves_slowly() -> void:
	m.want("forest")
	_run(30.0)
	m.want("danger")
	_run(MusicDirector.DANGER_SETTLE_S + MusicDirector.DANGER_FADE_S + 1.5)
	check(m.track.contains("/danger/"), "danger within seconds: " + m.track)
	m.want("forest")
	_run(MusicDirector.DANGER_SETTLE_S + 3.0)
	eq(m.phase, "fading", "still fading out")
	_run(20.0)
	check(m.track.contains("/forest/"), "back to the forest: " + m.track)
