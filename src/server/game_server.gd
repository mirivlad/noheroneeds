class_name GameServer
extends RefCounted
## The authoritative server loop over a Transport (ADR-0004). One step() is
## one tick: read the network, apply inputs, hand changes to the writer,
## acknowledge committed requests, stream chunks, send snapshots.
## Single-player runs the same server in-process over a MemoryTransport.

const TICK_RATE := Movement.TICK_RATE
## Chunks sent to one client per tick at most (≈ 0.5 ms each to encode, cached).
const CHUNKS_PER_TICK := 4
## Snapshots kept per client as possible bases for deltas.
const SNAPSHOT_HISTORY := 64
## Most queued inputs per client; beyond it the oldest are dropped.
const MAX_QUEUED_INPUTS := 8
## Entity state rows written per tick (the rest wait for later ticks).
const STATE_ROWS_PER_TICK := 100

var world: ServerWorld
var transport: Transport
## This server's key; its fingerprint is the server id (ADR-0006).
var identity: PlayerIdentity
## CharacterFile import policy (trusted servers, limits).
var import_policy := {}
## Clients see this many chunks around their own in each direction.
var view_chunks := 2
var tick := 0
var _sessions := {}
var _crypto := Crypto.new()


class Session:
	var peer := 0
	## new -> challenged -> authed -> playing
	var state := "new"
	var nonce := PackedByteArray()
	var player := ""
	var public_key := ""
	var character_id := ""
	var inputs: Array = []
	var last_input_seq := 0
	var direction := Vector2i.ZERO
	## snapshot id -> {entity id: state}
	var snapshots := {}
	var acked := 0
	var next_snapshot := 1
	## chunk key -> revision the client has
	var chunks := {}


func _init(server_world: ServerWorld, net: Transport, server_identity: PlayerIdentity) -> void:
	world = server_world
	transport = net
	identity = server_identity


func step() -> void:
	for e in transport.poll():
		match e.kind:
			Transport.Kind.CONNECTED:
				_sessions[e.peer] = Session.new()
				_sessions[e.peer].peer = e.peer
			Transport.Kind.DISCONNECTED:
				_drop(e.peer)
			Transport.Kind.PACKET:
				if _sessions.has(e.peer):
					_on_message(_sessions[e.peer], Protocol.decode(e.data, true))
	world.tick = tick
	world.poll_loaded()
	for s: Session in _sessions.values():
		if s.state == "playing":
			_prefetch(s)
			_apply_input(s)
	world.commit_async()
	world.flush_state(STATE_ROWS_PER_TICK)
	world.poll()
	for ack: Array in world.take_acks():
		var s := _session_of(ack[0])
		if s:
			_send(s, Transport.Channel.RELIABLE, Protocol.RESULT, {"request_id": ack[1], "result": ack[2]})
	for s: Session in _sessions.values():
		if s.state == "playing":
			_stream_chunks(s)
			_send_snapshot(s)
	tick += 1


## Disconnects everyone and commits everything (the world stays open).
func shutdown() -> void:
	for peer: int in _sessions.keys():
		_drop(peer)
		transport.disconnect_peer(peer)
	world.sync()


func session_count() -> int:
	return _sessions.size()


func _on_message(s: Session, m: Dictionary) -> void:
	var t := String(m.get("t", ""))
	if t == "":
		return _reject(s, "malformed")
	match s.state:
		"new":
			if t != Protocol.HELLO:
				return _reject(s, "expected hello")
			if m["v"] != Protocol.VERSION:
				return _reject(s, "protocol %d, server speaks %d" % [m["v"], Protocol.VERSION])
			if m["content"] != world.content.fingerprint():
				return _reject(s, "content differs from the server's")
			var fp := PlayerIdentity.fingerprint_of(m["public_key"])
			if m["key_alg"] != PlayerIdentity.KEY_ALG or fp == "":
				return _reject(s, "unsupported key")
			s.player = fp
			s.public_key = m["public_key"]
			s.nonce = _crypto.generate_random_bytes(32)
			s.state = "challenged"
			_send(s, Transport.Channel.RELIABLE, Protocol.CHALLENGE, {"nonce": s.nonce, "server_id": identity.fingerprint})
		"challenged":
			if t != Protocol.AUTH:
				return _reject(s, "expected auth")
			var payload := Protocol.auth_payload(s.nonce, identity.fingerprint, s.player)
			if not PlayerIdentity.verify(PlayerIdentity.KEY_ALG, m["sig_alg"], s.public_key, payload, m["signature"]):
				return _reject(s, "authentication failed")
			s.state = "authed"
		"authed":
			if t != Protocol.JOIN:
				return _reject(s, "expected join")
			_join(s, m["character"])
		"playing":
			match t:
				Protocol.INPUT:
					_take_input(s, m)
				Protocol.REQUEST:
					world.handle(s.character_id, m["request"])


func _join(s: Session, file: PackedByteArray) -> void:
	var r := CharacterFile.read(file, world.content, import_policy)
	if not r.ok:
		return _reject(s, "character refused: " + "; ".join(r.errors))
	if r.owner != s.player:
		return _reject(s, "the character is signed by another key")
	var id := r.character.character_id
	# The same character connected again (a reconnect): the new connection wins.
	var old := _session_of(id)
	if old:
		_drop(old.peer)
		transport.disconnect_peer(old.peer)
	var err := world.enter(s.player, r.character)
	if err != "":
		return _reject(s, err)
	s.character_id = id
	s.state = "playing"
	var p: Dictionary = world.present[id]
	_send(s, Transport.Channel.RELIABLE, Protocol.WELCOME, {"character_id": id, "location": p["location"], "tick": tick})


func _take_input(s: Session, m: Dictionary) -> void:
	for e: Array in Protocol.clean_inputs(m["inputs"]):
		if e[0] > s.last_input_seq and (s.inputs.is_empty() or e[0] > s.inputs[-1][0]):
			s.inputs.append(e)
	while s.inputs.size() > MAX_QUEUED_INPUTS:
		s.inputs.pop_front()
	var ack: int = m["ack"]
	if ack > s.acked and s.snapshots.has(ack):
		s.acked = ack
		for id: int in s.snapshots.keys():
			if id < ack:
				s.snapshots.erase(id)


## One input per tick; two when a backlog builds up (jitter), so the server
## never falls behind the client for long.
func _apply_input(s: Session) -> void:
	var steps := 2 if s.inputs.size() > 2 else 1
	for i in steps:
		if s.inputs.is_empty():
			return
		var e: Array = s.inputs.pop_front()
		s.last_input_seq = e[0]
		var p: Dictionary = world.present[s.character_id]
		var loc: String = p["location"]
		world.move_character(s.character_id, Movement.step(p["pos"], e[1], e[2],
			func(x: int, y: int) -> bool: return world.is_solid(loc, x, y)))


## Keeps one ring of chunks beyond what the client sees loading in advance.
func _prefetch(s: Session) -> void:
	var p: Dictionary = world.present[s.character_id]
	var cell := Movement.cell_of(p["pos"])
	var mc := Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))
	var r := view_chunks + 1
	for cy in range(mc.y - r, mc.y + r + 1):
		for cx in range(mc.x - r, mc.x + r + 1):
			world.prefetch(p["location"], cx, cy)


func _send_snapshot(s: Session) -> void:
	var me: Dictionary = world.present[s.character_id]
	var mine := Movement.cell_of(me["pos"])
	var mc := Vector2i(floori(float(mine.x) / Chunk.SIZE), floori(float(mine.y) / Chunk.SIZE))
	var now := {}
	for id: String in world.present:
		var p: Dictionary = world.present[id]
		if p["location"] != me["location"]:
			continue
		var cell := Movement.cell_of(p["pos"])
		var c := Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))
		if absi(c.x - mc.x) <= view_chunks and absi(c.y - mc.y) <= view_chunks:
			now[id] = {"x": p["pos"].x, "y": p["pos"].y, "kind": "character", "name": p["name"], "appearance": p["appearance"]}
	# The player's own inventory travels only to that player.
	now[s.character_id]["inventory"] = world.inventory(s.character_id).stacks.duplicate()
	for cy in range(mc.y - view_chunks, mc.y + view_chunks + 1):
		for cx in range(mc.x - view_chunks, mc.x + view_chunks + 1):
			for id: String in world.items_in_chunk(me["location"], cx, cy):
				var it: Dictionary = world.items[id]
				now[id] = {"x": it["x"], "y": it["y"], "kind": "item", "item": it["item"], "count": it["count"]}
	var base: Dictionary = s.snapshots.get(s.acked, {}) if s.acked > 0 else {}
	var changed := {}
	for id: String in now:
		var old: Dictionary = base.get(id, {})
		var diff := {}
		for f: String in now[id]:
			if not old.has(f) or old[f] != now[id][f]:
				diff[f] = now[id][f]
		if not diff.is_empty():
			changed[id] = diff
	var removed: Array = []
	for id: String in base:
		if not now.has(id):
			removed.append(id)
	var sid := s.next_snapshot
	s.next_snapshot += 1
	s.snapshots[sid] = now
	if s.snapshots.size() > SNAPSHOT_HISTORY:
		s.snapshots.erase(s.snapshots.keys().min())
	_send(s, Transport.Channel.STATE, Protocol.SNAPSHOT, {"id": sid, "base": s.acked if s.acked > 0 else 0,
		"tick": tick, "entities": changed, "removed": removed, "input_ack": s.last_input_seq})


func _stream_chunks(s: Session) -> void:
	var p: Dictionary = world.present[s.character_id]
	var loc: String = p["location"]
	var cell := Movement.cell_of(p["pos"])
	var mc := Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))
	var budget := CHUNKS_PER_TICK
	# Nearest first, so the ground under the player arrives before the edges.
	for r in view_chunks + 1:
		for cy in range(mc.y - r, mc.y + r + 1):
			for cx in range(mc.x - r, mc.x + r + 1):
				if maxi(absi(cx - mc.x), absi(cy - mc.y)) != r:
					continue
				var key := ServerWorld.chunk_key(loc, cx, cy)
				var rev := world.chunk_revision(loc, cx, cy)
				if s.chunks.get(key, -1) == rev:
					continue
				if budget == 0:
					return
				budget -= 1
				s.chunks[key] = rev
				_send(s, Transport.Channel.BULK, Protocol.CHUNK, {"location": loc, "cx": cx, "cy": cy,
					"data": world.encoded_chunk(loc, cx, cy)})


func _session_of(character_id: String) -> Session:
	for s: Session in _sessions.values():
		if s.character_id == character_id and s.state == "playing":
			return s
	return null


func _drop(peer: int) -> void:
	var s: Session = _sessions.get(peer)
	if s == null:
		return
	if s.state == "playing":
		world.leave(s.character_id)
	_sessions.erase(peer)


func _reject(s: Session, reason: String) -> void:
	_send(s, Transport.Channel.RELIABLE, Protocol.REJECT, {"reason": reason})
	_drop(s.peer)
	transport.disconnect_peer(s.peer)


func _send(s: Session, channel: Transport.Channel, type: String, fields: Dictionary) -> void:
	transport.send(s.peer, channel, Protocol.encode(type, fields))
