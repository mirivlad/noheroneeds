class_name GameClient
extends RefCounted
## The player's side of the connection (ADR-0004). Holds a mirror of what the
## server shows this player, predicts its own movement with the same code as
## the server and corrects it from snapshots. Presentation reads this mirror;
## it never decides outcomes.

var transport: Transport
var identity: PlayerIdentity
## The signed character file this client joins with.
var character_file := PackedByteArray()
## Same content as the server, for the handshake and for predicting walls.
var content: ContentRegistry

## connecting -> challenged -> joining -> playing; rejected / disconnected
var state := "connecting"
var reject_reason := ""
var character_id := ""
## The own character as the server shows it to others (name, appearance).
var own := {}
## The world time (game ms, ADR-0014): the server's from each snapshot,
## carried on between snapshots at the server's rate.
var world_time := 0.0
var time_rate := 0
var has_time := false
var location := ""
## The level label of the location (0 on the surface).
var z := 0
var server_id := ""
## Predicted own position (1/256 cell units).
var position := Vector2i.ZERO
var has_position := false
## Movement intention for the next ticks, each axis -1..1.
var move := Vector2i.ZERO
## Running (held key), 1.5 times as fast.
var run := false
## Other entities as of the newest snapshot: id -> state.
var entities := {}
## chunk key -> Chunk
var chunks := {}
## request id -> result, as acknowledged by the server
var results := {}
## Own position before the last tick, for drawing between ticks.
var previous_position := Vector2i.ZERO
## Chunk keys received since the presentation last asked.
var changed_chunks: Array[String] = []
## Changes seen in the world since the view last took them (see _note_changes).
var world_events: Array[Dictionary] = []
## Times a prediction had to be corrected (for tests and diagnostics).
var corrections := 0

## short net number -> entity id (this connection)
var _uid_of := {}
var _latest_snapshot := 0
var _input_seq := 0
var _unacked_inputs: Array = []
var _requests := {}


func _init(net: Transport, player: PlayerIdentity, file: PackedByteArray, registry: ContentRegistry) -> void:
	transport = net
	identity = player
	character_file = file
	content = registry


## One client tick.
func step() -> void:
	for e in transport.poll():
		match e.kind:
			Transport.Kind.CONNECTED:
				_send(Transport.Channel.RELIABLE, Protocol.HELLO, {"v": Protocol.VERSION, "content": content.fingerprint(),
					"key_alg": PlayerIdentity.KEY_ALG, "public_key": identity.public_pem()})
			Transport.Kind.DISCONNECTED:
				if state != "rejected":
					state = "disconnected"
			Transport.Kind.PACKET:
				_on_message(Protocol.decode(e.data, false))
	if has_time:
		world_time += time_rate
	if state == "playing" and has_position:
		_input_seq += 1
		_unacked_inputs.append([_input_seq, move.x, move.y, 1 if run else 0])
		previous_position = position
		position = Movement.step(position, move.x, move.y, _solid, run)
		_send(Transport.Channel.STATE, Protocol.INPUT, {"inputs": _unacked_inputs.slice(-Protocol.INPUT_REDUNDANCY),
			"ack": _latest_snapshot})


## Sends a request (build, transfer...) and returns its id. It is resent after
## a reconnect until its result arrives; the server applies it only once.
func request(op: Dictionary) -> String:
	var rid := Uuid.v4()
	var r := op.duplicate(true)
	r["request_id"] = rid
	_requests[rid] = r
	if state == "playing":
		_send(Transport.Channel.RELIABLE, Protocol.REQUEST, {"request": r})
	return rid


## Starts over on a new connection, keeping unanswered requests.
func reconnect(net: Transport) -> void:
	transport = net
	state = "connecting"
	has_position = false
	entities.clear()
	own = {}
	chunks.clear()
	_uid_of.clear()
	_latest_snapshot = 0
	_unacked_inputs.clear()


## The own inventory as the server last showed it: {item id: count}.
func inventory() -> Dictionary:
	return own.get("inventory", {})


func unanswered_requests() -> int:
	return _requests.size()


func _on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		Protocol.CHALLENGE:
			server_id = m["server_id"]
			_send(Transport.Channel.RELIABLE, Protocol.AUTH, {"sig_alg": PlayerIdentity.SIG_ALG,
				"signature": identity.sign(Protocol.auth_payload(m["nonce"], server_id, identity.fingerprint))})
			_send(Transport.Channel.RELIABLE, Protocol.JOIN, {"character": character_file})
			state = "joining"
		Protocol.WELCOME:
			character_id = m["character_id"]
			location = m["location"]
			state = "playing"
			for rid: String in _requests:
				_send(Transport.Channel.RELIABLE, Protocol.REQUEST, {"request": _requests[rid]})
		Protocol.LOCATION:
			location = m["location"]
			z = m["z"]
			has_position = false  # the next snapshot places us
			_unacked_inputs.clear()
			changed_chunks.append("*")  # the view redraws everything for the new place
		Protocol.REJECT:
			reject_reason = m["reason"]
			state = "rejected"
		Protocol.RESULT:
			results[m["request_id"]] = m["result"]
			_requests.erase(m["request_id"])
		Protocol.CHUNK:
			var c := ChunkCodec.decode(m["data"])
			if c:
				var key := ServerWorld.chunk_key(m["location"], m["cx"], m["cy"])
				var old: Chunk = chunks.get(key)
				if old:
					_note_changes(String(m["location"]), Vector2i(int(m["cx"]), int(m["cy"])) * Chunk.SIZE, old, c)
				chunks[key] = c
				changed_chunks.append(key)
		Protocol.SNAPSHOT:
			_on_snapshot(m)


## What changed in a chunk the client already had, for sounds and effects:
## {"type": "build"|"dismantle"|"open"|"close", "location", "cell", "part"}.
## A chunk seen for the first time is no news.
func _note_changes(loc: String, origin: Vector2i, old: Chunk, new: Chunk) -> void:
	for layer: String in ["structure", "cover", "ceiling", "roof"]:
		var a: PackedInt32Array = old.layers.get(layer, PackedInt32Array())
		var b: PackedInt32Array = new.layers.get(layer, PackedInt32Array())
		if a.is_empty() and b.is_empty():
			continue
		for i in Chunk.CELLS:
			var was := old.palette[a[i]] if not a.is_empty() else ""
			var now := new.palette[b[i]] if not b.is_empty() else ""
			if was == now:
				continue
			var cell := origin + Vector2i(i % Chunk.SIZE, i / Chunk.SIZE)
			if was != "":
				world_events.append({"type": "dismantle", "location": loc, "cell": cell, "part": was})
			if now != "":
				world_events.append({"type": "build", "location": loc, "cell": cell, "part": now})
	var seen := {}
	for i: int in new.props.keys() + old.props.keys():
		if seen.has(i):
			continue
		seen[i] = true
		var was_open := bool((old.props.get(i, {}) as Dictionary).get("open", false))
		var now_open := bool((new.props.get(i, {}) as Dictionary).get("open", false))
		if was_open != now_open:
			var cell := origin + Vector2i(i % Chunk.SIZE, i / Chunk.SIZE)
			var part := new.get_cell("structure", i % Chunk.SIZE, i / Chunk.SIZE)
			world_events.append({"type": "open" if now_open else "close", "location": loc, "cell": cell, "part": part})


## Snapshots (protocol 7) are differences from what this client last
## acknowledged; the newest one applies on top of what we have, older or
## repeated ones are dropped (the server repeats what we may have missed).
func _on_snapshot(m: Dictionary) -> void:
	var sid: int = m["id"]
	if sid <= _latest_snapshot:
		return
	var removed := (m["removed"] as PackedByteArray).to_int32_array()
	for n in removed:
		entities.erase(_uid_of.get(n, ""))
	var changed: Dictionary = m["entities"]
	for n: Variant in changed:
		var fields: Dictionary = changed[n]
		if typeof(fields.get("uid")) == TYPE_STRING:
			_uid_of[n] = fields["uid"]
			fields.erase("uid")
		var id: String = _uid_of.get(n, "")
		if id == "":
			continue  # a number we were never introduced to: wait for a full state
		if id == character_id:
			own.merge(fields, true)
		else:
			(entities.get_or_add(id, {}) as Dictionary).merge(fields, true)
	var hot := (m["hot"] as PackedByteArray).to_int32_array()
	for i in range(0, hot.size() - 2, 3):
		var id: String = _uid_of.get(hot[i], "")
		var e: Dictionary = own if id == character_id else entities.get(id, {})
		if id != "" and (id == character_id or entities.has(id)):
			e["x"] = hot[i + 1]
			e["y"] = hot[i + 2]
	_latest_snapshot = sid
	time_rate = int(m["rate"])
	# The server's clock, unless ours is just ahead by the ticks in flight.
	if not has_time or absf(world_time - float(m["time"])) > time_rate * 10:
		world_time = float(m["time"])
	has_time = true
	if own.has("x"):
		_reconcile(Vector2i(own["x"], own["y"]), m["input_ack"])


## The server's position after input `ack`, plus our inputs it has not seen yet.
func _reconcile(server_pos: Vector2i, ack: int) -> void:
	while not _unacked_inputs.is_empty() and _unacked_inputs[0][0] <= ack:
		_unacked_inputs.pop_front()
	var replay := server_pos
	for e: Array in _unacked_inputs:
		replay = Movement.step(replay, e[1], e[2], _solid, e[3] == 1)
	if has_position and replay != position:
		corrections += 1
	if not has_position:
		previous_position = replay
	position = replay
	has_position = true


func _solid(x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	if c == null:
		return false  # unknown ground: the server will correct us
	return Terrain.is_solid(c, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, content, location != Levels.SURFACE)


func _send(channel: Transport.Channel, type: String, fields: Dictionary) -> void:
	transport.send(Transport.SERVER, channel, Protocol.encode(type, fields))
