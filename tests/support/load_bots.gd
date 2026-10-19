extends SceneTree
## Load bots: N clients over ENet in one process, playing like restless
## players (walk, turn, build, take down, drop, pick up).
##   godot --headless -s res://tests/support/load_bots.gd -- --connect=HOST:PORT --bots=N --seconds=S
## Keys are kept in user://bot_keys/<n> (RSA generation takes seconds).
## Prints "BOTS {...}" at the end: acknowledgement delays, corrections, failures.

var _bots: Array = []
var _rng := RandomNumberGenerator.new()
var _sent := {}
var _ack_ms: Array = []
var _end := 0
var _accum := 0.0
var _content: ContentRegistry


class Bot:
	var client: GameClient
	var turn_at := 0
	var act_at := 0


func _initialize() -> void:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		o[kv[0]] = kv[1] if kv.size() > 1 else ""
	var hp := String(o.get("connect", "127.0.0.1:24680")).split(":")
	_content = ContentRegistry.load_packs(["res://content/base"])
	_rng.seed = int(o.get("seed", "1"))
	for i in int(o.get("bots", "10")):
		var key := PlayerIdentity.load_or_create(ProjectSettings.globalize_path("user://bot_keys/%d" % i))
		var c := PortableCharacter.create("Бот %d" % i, "base:human_m")
		c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
		var t := ENetTransport.new()
		t.start_client(hp[0], int(hp[1]))
		var b := Bot.new()
		b.client = GameClient.new(t, key, CharacterFile.export_signed(c, key, _content), _content)
		_bots.append(b)
	_end = Time.get_ticks_msec() + int(o.get("seconds", "60")) * 1000
	print("BOTS STARTED %d" % _bots.size())


func _process(delta: float) -> bool:
	_accum += delta
	var tick := 1.0 / Movement.TICK_RATE
	while _accum >= tick:
		_accum -= tick
		for b: Bot in _bots:
			_play(b)
			b.client.step()
			for rid: String in b.client.results.keys():
				if _sent.has(rid):
					_ack_ms.append(Time.get_ticks_msec() - int(_sent[rid]))
					_sent.erase(rid)
				b.client.results.erase(rid)
	if Time.get_ticks_msec() >= _end:
		_report()
		return true
	return false


func _play(b: Bot) -> void:
	var c := b.client
	if c.state != "playing" or not c.has_position:
		return
	var now := Time.get_ticks_msec()
	if now >= b.turn_at:
		b.turn_at = now + _rng.randi_range(800, 3000)
		c.move = Vector2i(_rng.randi_range(-1, 1), _rng.randi_range(-1, 1))
	if now >= b.act_at:
		b.act_at = now + _rng.randi_range(2000, 6000)
		var cell := Movement.cell_of(c.position) + Vector2i(_rng.randi_range(-3, 3), _rng.randi_range(-3, 3))
		var roll := _rng.randf()
		var rid := ""
		if roll < 0.4:
			rid = c.request({"type": "build", "location": c.location, "x": cell.x, "y": cell.y, "part": "base:wood_wall"})
		elif roll < 0.7:
			rid = c.request({"type": "dismantle", "location": c.location, "x": cell.x, "y": cell.y})
		elif roll < 0.85:
			rid = c.request({"type": "drop", "item": "base:stone", "count": 1})
		else:
			for id: String in c.entities:
				if c.entities[id].get("kind") == "item":
					rid = c.request({"type": "pickup", "entity": id})
					break
		if rid != "":
			_sent[rid] = now


func _report() -> void:
	_ack_ms.sort()
	var n := _ack_ms.size()
	var playing := 0
	var corrections := 0
	for b: Bot in _bots:
		if b.client.state == "playing":
			playing += 1
		corrections += b.client.corrections
		b.client.transport.close()
	print("BOTS " + JSON.stringify({"bots": _bots.size(), "playing": playing, "acks": n,
		"unanswered": _sent.size(), "ack_p50_ms": _ack_ms[n / 2] if n else -1,
		"ack_p99_ms": _ack_ms[mini(n - 1, n * 99 / 100)] if n else -1, "ack_max_ms": _ack_ms[-1] if n else -1,
		"corrections": corrections}))
