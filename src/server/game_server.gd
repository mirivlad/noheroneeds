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
## Chunks no player needed for this long leave memory (if safe, see
## ServerWorld.unload_idle); checked every UNLOAD_EVERY ticks.
var unload_after_ticks := TICK_RATE * 60
const UNLOAD_EVERY := TICK_RATE * 10
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
## Tests and tools: every tick waits until its batch is on disk, so a
## request's result always comes out in the same tick (real servers never wait).
var wait_for_disk := false
var tick := 0
## Microseconds each step() took, since the last take_stats().
var _tick_usec: Array[int] = []
var _sync_loads_seen := 0
## Microseconds per part of the tick since the last take_stats().
var _sections := {}
var _mark := 0
var _replica := {}
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
	## snapshot id -> {entity id: Vector2i(hot version, cold version), "~inventory": version}
	var snapshots := {}
	var oldest_snapshot := 1
	## entity id -> short number on this connection (never reused)
	var net_ids := {}
	var next_net_id := 1
	## Where the player's chunk was when prefetching and streaming last ran.
	var prefetched_at := Vector2i(1 << 30, 0)
	var streamed_at := Vector2i(1 << 30, 0)
	var streamed_epoch := -1
	var streaming_unfinished := true
	var acked := 0
	var next_snapshot := 1
	## chunk key -> revision the client has
	var chunks := {}


func _init(server_world: ServerWorld, net: Transport, server_identity: PlayerIdentity) -> void:
	world = server_world
	transport = net
	identity = server_identity


func step() -> void:
	var t0 := Time.get_ticks_usec()
	_step()
	_tick_usec.append(Time.get_ticks_usec() - t0)


## Tick times and traffic since the last call: {ticks, p50, p99, max (µs),
## bytes per channel, players}.
func take_stats() -> Dictionary:
	var t := _tick_usec.duplicate()
	t.sort()
	_tick_usec.clear()
	var n := t.size()
	var out := {"ticks": n, "p50": t[n / 2] if n else 0, "p99": t[mini(n - 1, n * 99 / 100)] if n else 0,
		"max": t[-1] if n else 0, "bytes": transport.bytes_sent.duplicate(), "players": world.present.size(),
		"sync_loads": world.sync_loads - _sync_loads_seen, "chunks": world.loaded_chunks(), "sections_ms": {}}
	for k: String in _sections:
		out["sections_ms"][k] = snappedf(_sections[k] / 1000.0, 0.1)
	_sections.clear()
	_sync_loads_seen = world.sync_loads
	return out


## Adds the time since the previous mark to a named part of the tick.
func _lap(name: String) -> void:
	var now := Time.get_ticks_usec()
	_sections[name] = _sections.get(name, 0) + now - _mark
	_mark = now


func _step() -> void:
	_mark = Time.get_ticks_usec()
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
	_lap("network_in")
	world.tick = tick
	world.advance_time()
	world.poll_loaded()
	for s: Session in _sessions.values():
		if s.state == "playing":
			_prefetch(s)
	if tick % TICK_RATE == 0:
		for s: Session in _sessions.values():
			if s.state == "playing":
				_mark_needed(s)
	if tick % UNLOAD_EVERY == 0:
		world.unload_idle(unload_after_ticks)
	_lap("prefetch")
	for s: Session in _sessions.values():
		if s.state == "playing":
			_apply_input(s)
	_lap("movement")
	world.commit_async(wait_for_disk)
	world.flush_state(STATE_ROWS_PER_TICK)
	if wait_for_disk:
		world.writer.wait_idle()
	world.poll()
	for ack: Array in world.take_acks():
		var s := _session_of(ack[0])
		if s:
			_send(s, Transport.Channel.RELIABLE, Protocol.RESULT, {"request_id": ack[1], "result": ack[2]})
	for id: String in world.relocated:
		var rs := _session_of(id)
		if rs:
			_tell_location(rs)
	world.relocated.clear()
	_lap("storage")
	for s: Session in _sessions.values():
		if s.state == "playing":
			_stream_chunks(s)
	_lap("chunks")
	_update_replica()
	for s: Session in _sessions.values():
		if s.state == "playing":
			_send_snapshot(s)
	_lap("snapshots")
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
	_tell_location(s)


func _tell_location(s: Session) -> void:
	var loc: String = world.present[s.character_id]["location"]
	s.prefetched_at = Vector2i(1 << 30, 0)
	s.streamed_at = Vector2i(1 << 30, 0)
	s.inputs.clear()
	_send(s, Transport.Channel.RELIABLE, Protocol.LOCATION, {"location": loc, "z": world.levels.z(loc)})


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
		s.oldest_snapshot = ack


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
			func(x: int, y: int) -> bool: return world.is_solid(loc, x, y), e[3] == 1))


## Keeps one ring of chunks beyond what the client sees loading in advance.
func _prefetch(s: Session) -> void:
	var p: Dictionary = world.present[s.character_id]
	var cell := Movement.cell_of(p["pos"])
	var mc := Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))
	if mc == s.prefetched_at:
		return  # only when the player enters another chunk
	s.prefetched_at = mc
	var r := view_chunks + 1
	for loc: String in _shown_locations(p["location"]):
		for cy in range(mc.y - r, mc.y + r + 1):
			for cx in range(mc.x - r, mc.x + r + 1):
				world.prefetch(loc, cx, cy)


## What a player standing in `location` gets chunks of: the location itself,
## and on a building level also the surface below it (seen dimmed). Things
## and people come only from the player's own location.
func _shown_locations(location: String) -> Array:
	return [location] if location == ServerWorld.SURFACE else [location, ServerWorld.SURFACE]


## Entity states for this tick, shared by every client's snapshot. Each
## entity has a hot part (position) and a cold part (what it is, looks), each
## with a version; a snapshot remembers versions only, so the delta against
## the client's acknowledged base is a comparison of numbers.
func _update_replica() -> void:
	for id: String in _replica.keys():
		var r: Dictionary = _replica[id]
		if r["kind"] == "character" and not world.present.has(id):
			_replica.erase(id)
		elif r["kind"] == "item" and not world.items.has(id):
			_replica.erase(id)
	for id: String in world.present:
		var p: Dictionary = world.present[id]
		var r: Dictionary = _replica.get(id, {})
		if r.is_empty():
			_replica[id] = {"kind": "character", "hot": {"x": p["pos"].x, "y": p["pos"].y}, "hv": 1,
				"cold": {"kind": "character", "name": p["name"], "appearance": p["appearance"]}, "cv": 1}
		elif r["hot"]["x"] != p["pos"].x or r["hot"]["y"] != p["pos"].y:
			r["hot"] = {"x": p["pos"].x, "y": p["pos"].y}
			r["hv"] += 1


func _item_replica(id: String) -> Dictionary:
	if not _replica.has(id):
		var it: Dictionary = world.items[id]
		_replica[id] = {"kind": "item", "hot": {"x": it["x"], "y": it["y"]}, "hv": 1,
			"cold": {"kind": "item", "item": it["item"], "count": it["count"]}, "cv": 1}
	return _replica[id]


## The chunks a player sees plus one ring stay in memory.
func _mark_needed(s: Session) -> void:
	var p: Dictionary = world.present[s.character_id]
	var cell := Movement.cell_of(p["pos"])
	var mc := Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))
	var r := view_chunks + 1
	for loc: String in _shown_locations(p["location"]):
		for cy in range(mc.y - r, mc.y + r + 1):
			for cx in range(mc.x - r, mc.x + r + 1):
				world.mark_needed(loc, cx, cy)


func _send_snapshot(s: Session) -> void:
	var me: Dictionary = world.present[s.character_id]
	var loc: String = me["location"]
	var mine := Movement.cell_of(me["pos"])
	var mc := Vector2i(floori(float(mine.x) / Chunk.SIZE), floori(float(mine.y) / Chunk.SIZE))
	var view := {}
	for id: String in world.present:
		var p: Dictionary = world.present[id]
		if p["location"] != loc:
			continue
		var cell := Movement.cell_of(p["pos"])
		if absi(floori(float(cell.x) / Chunk.SIZE) - mc.x) <= view_chunks and absi(floori(float(cell.y) / Chunk.SIZE) - mc.y) <= view_chunks:
			view[id] = _replica[id]
	for cy in range(mc.y - view_chunks, mc.y + view_chunks + 1):
		for cx in range(mc.x - view_chunks, mc.x + view_chunks + 1):
			for id: String in world.items_in_chunk(loc, cx, cy):
				view[id] = _item_replica(id)
	var base: Dictionary = s.snapshots.get(s.acked, {}) if s.acked > 0 else {}
	var changed := {}
	var versions := {}
	for id: String in view:
		var r: Dictionary = view[id]
		var v := Vector2i(r["hv"], r["cv"])
		versions[id] = v
		var b: Variant = base.get(id)
		if b == null:
			var full: Dictionary = r["hot"].duplicate()
			full.merge(r["cold"])
			full["uid"] = id
			changed[_net_id(s, id)] = full
		elif b != v:
			var d := {}
			if b.x != v.x:
				d.merge(r["hot"])
			if b.y != v.y:
				d.merge(r["cold"])
			changed[_net_id(s, id)] = d
	# The player's own inventory goes only to that player, and only when it changed.
	var inv_v := world.inventory_version(s.character_id)
	versions["~inventory"] = inv_v
	if base.get("~inventory", -1) != inv_v:
		var mine_n := _net_id(s, s.character_id)
		if not changed.has(mine_n):
			changed[mine_n] = {}
		changed[mine_n]["inventory"] = world.inventory(s.character_id).stacks.duplicate()
	var removed: Array = []
	for id: String in base:
		if not versions.has(id) and s.net_ids.has(id):
			removed.append(s.net_ids[id])
	var sid := s.next_snapshot
	s.next_snapshot += 1
	s.snapshots[sid] = versions
	while s.snapshots.size() > SNAPSHOT_HISTORY:
		s.snapshots.erase(s.oldest_snapshot)
		s.oldest_snapshot += 1
	_send(s, Transport.Channel.STATE, Protocol.SNAPSHOT, {"id": sid, "base": s.acked if s.acked > 0 else 0,
		"tick": tick, "entities": changed, "removed": removed, "input_ack": s.last_input_seq,
		"time": world.world_time, "rate": world.time_rate})


func _net_id(s: Session, id: String) -> int:
	if not s.net_ids.has(id):
		s.net_ids[id] = s.next_net_id
		s.next_net_id += 1
	return s.net_ids[id]


func _stream_chunks(s: Session) -> void:
	var p: Dictionary = world.present[s.character_id]
	var loc: String = p["location"]
	var cell := Movement.cell_of(p["pos"])
	var mc := Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))
	if mc == s.streamed_at and s.streamed_epoch == world.revision_epoch and not s.streaming_unfinished:
		return  # same place, nothing changed, nothing left to send
	s.streamed_at = mc
	s.streamed_epoch = world.revision_epoch
	s.streaming_unfinished = false
	var budget := CHUNKS_PER_TICK
	# Nearest first, so the ground under the player arrives before the edges;
	# the player's own location before the surface seen below it.
	for shown: String in _shown_locations(loc):
		for r in view_chunks + 1:
			for cy in range(mc.y - r, mc.y + r + 1):
				for cx in range(mc.x - r, mc.x + r + 1):
					if maxi(absi(cx - mc.x), absi(cy - mc.y)) != r:
						continue
					var key := ServerWorld.chunk_key(shown, cx, cy)
					var rev := world.chunk_revision(shown, cx, cy)
					if s.chunks.get(key, -1) == rev:
						continue
					if budget == 0:
						s.streaming_unfinished = true
						return
					budget -= 1
					s.chunks[key] = rev
					_send(s, Transport.Channel.BULK, Protocol.CHUNK, {"location": shown, "cx": cx, "cy": cy,
						"data": world.encoded_chunk(shown, cx, cy)})


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
