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
var location := ""
var server_id := ""
## Predicted own position (1/256 cell units).
var position := Vector2i.ZERO
var has_position := false
## Movement intention for the next ticks, each axis -1..1.
var move := Vector2i.ZERO
## Other entities as of the newest snapshot: id -> state.
var entities := {}
## chunk key -> Chunk
var chunks := {}
## request id -> result, as acknowledged by the server
var results := {}
## Times a prediction had to be corrected (for tests and diagnostics).
var corrections := 0

var _snapshots := {}
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
	if state == "playing" and has_position:
		_input_seq += 1
		_unacked_inputs.append([_input_seq, move.x, move.y])
		position = Movement.step(position, move.x, move.y, _solid)
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
	chunks.clear()
	_snapshots.clear()
	_latest_snapshot = 0
	_unacked_inputs.clear()


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
		Protocol.REJECT:
			reject_reason = m["reason"]
			state = "rejected"
		Protocol.RESULT:
			results[m["request_id"]] = m["result"]
			_requests.erase(m["request_id"])
		Protocol.CHUNK:
			var c := ChunkCodec.decode(m["data"])
			if c:
				chunks[ServerWorld.chunk_key(m["location"], m["cx"], m["cy"])] = c
		Protocol.SNAPSHOT:
			_on_snapshot(m)


func _on_snapshot(m: Dictionary) -> void:
	var sid: int = m["id"]
	if sid <= _latest_snapshot:
		return  # older or repeated: newest wins
	var base_id: int = m["base"]
	if base_id != 0 and not _snapshots.has(base_id):
		return  # cannot rebuild it; the next one will do
	var full: Dictionary = (_snapshots.get(base_id, {}) as Dictionary).duplicate(true)
	for id: Variant in m["removed"]:
		full.erase(id)
	var changed: Dictionary = m["entities"]
	for id: String in changed:
		var st: Dictionary = full.get(id, {})
		st.merge(changed[id], true)
		full[id] = st
	_snapshots[sid] = full
	_latest_snapshot = sid
	for old: int in _snapshots.keys():
		if old < base_id:
			_snapshots.erase(old)
	entities = full.duplicate()
	entities.erase(character_id)
	if full.has(character_id):
		_reconcile(Vector2i(full[character_id]["x"], full[character_id]["y"]), m["input_ack"])


## The server's position after input `ack`, plus our inputs it has not seen yet.
func _reconcile(server_pos: Vector2i, ack: int) -> void:
	while not _unacked_inputs.is_empty() and _unacked_inputs[0][0] <= ack:
		_unacked_inputs.pop_front()
	var replay := server_pos
	for e: Array in _unacked_inputs:
		replay = Movement.step(replay, e[1], e[2], _solid)
	if has_position and replay != position:
		corrections += 1
	position = replay
	has_position = true


func _solid(x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c: Chunk = chunks.get(ServerWorld.chunk_key(location, cx, cy))
	if c == null:
		return false  # unknown ground: the server will correct us
	var part := c.get_cell("structure", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE)
	return part != "" and bool(content.get_def(part).get("solid", true))


func _send(channel: Transport.Channel, type: String, fields: Dictionary) -> void:
	transport.send(Transport.SERVER, channel, Protocol.encode(type, fields))
