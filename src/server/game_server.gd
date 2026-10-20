class_name GameServer
extends RefCounted
## The authoritative server loop over a Transport (ADR-0004). One step() is
## one tick: read the network, apply inputs, hand changes to the writer,
## acknowledge committed requests, stream chunks, send snapshots.
## Single-player runs the same server in-process over a MemoryTransport.

const TICK_RATE := Movement.TICK_RATE
## Chunks sent to one client per tick at most (≈ 0.5 ms each to encode, cached).
const CHUNKS_PER_TICK := 4
## About how many bytes of entities a snapshot carries: it goes unreliably
## and must fit a packet (ENet's MTU is about 1400; ADR-0018).
const SNAPSHOT_BYTES := 1100
## A creature's position goes out at most this often (ticks; 4 = 5 a second).
const CREATURE_HOT_TICKS := 4
## How far around a player creatures are sent (cells, half width and height):
## a zoomed-out screen (40 x 22 cells) and a margin.
const CREATURE_VIEW := Vector2i(26, 18)
## Unacknowledged snapshots remembered per client (what each carried).
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
## The sections of this tick, and of the slowest tick since the last stats.
var _this_tick := {}
var _slowest := {}
var _slowest_usec := 0
## entity id -> Replica: what clients are shown of it this tick.
var _replica := {}
## Request id -> when it came; microseconds from a request to its result
## (the commit to disk is in between), since the last take_stats().
var _request_at := {}
var _result_usec: Array[int] = []


## An entity as clients see it: a hot part (position) and a cold part (what
## it is, looks), each with a version that grows on every change. Shared by
## all sessions and updated in place; a session compares versions only.
class Replica:
	var kind := ""
	var x := 0
	var y := 0
	var hv := 1
	var cv := 1
	## The warm part: health, the most, deaths so far (ADR-0019), and blows
	## struck (Combat.swings: count and direction) for the swing to be seen.
	var wv := 1
	var health := 0
	var max_health := 0
	var deaths := 0
	var swing := 0
	var cold := {}
	## Encoded size of the cold part (to keep a snapshot within a packet).
	var cold_size := 0
	## A creature's beat for sending its position (0..CREATURE_HOT_TICKS-1).
	var phase := 0
	## Gone from the world (views holding it drop it).
	var gone := false
	## A creature's cell of the grid (GameServer._grid).
	var grid_key := Vector3i.ZERO
	## Where it is; its level label goes to clients in the cold part ("z").
	var location := ""

	func _init(k: String, loc: String, z: int, px: int, py: int, c: Dictionary) -> void:
		kind = k
		location = loc
		x = px
		y = py
		cold = c
		cold["z"] = z
		cold_size = Cbor.encode_fast(c).size()

	## Moved to another location (a character up the stairs): a cold change.
	func relocate(loc: String, z: int) -> void:
		location = loc
		cold = cold.duplicate()
		cold["z"] = z
		cold_size = Cbor.encode_fast(cold).size()
		cv += 1

	## Both versions in one number, as sessions remember them.
	func version() -> Vector3i:
		return Vector3i(hv, wv, cv)

	## Health (characters and creatures): changes often, goes apart from the
	## cold part, packed. Returns whether it changed.
	func set_health(h: int, top: int, died: int, swung := 0) -> bool:
		if h == health and top == max_health and died == deaths and swung == swing:
			return false
		health = h
		max_health = top
		deaths = died
		swing = swung
		wv += 1
		return true
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
	## What the client has acknowledged (protocol 7): entity id ->
	## Replica.version() (hot, warm, cold); snapshots carry only differences
	## from it. "~inventory" -> the inventory version.
	var known := {}
	## What the client may see (id -> Replica), worked out again at
	## view_due, or sooner when the player moves to another grid cell or
	## items change; replicas update in place in between.
	var view := {}
	var view_due := 0
	var view_cell := Vector3i(1 << 30, 0, 0)
	var view_items_rev := -1
	## The tick the view was last worked out.
	var view_built := -1
	## Entities sent to the client and not removed since (it may have them).
	var shown := {}
	## Entities whose removal was sent and not acknowledged yet: repeated.
	var removing := {}
	## snapshot id -> [{entity id: Vector2i versions sent}, [removed ids]]
	var pending := {}
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
	## Map tiles asked for and not sent yet: [[location, cx, cy], ...].
	var map_queue: Array = []


func _init(server_world: ServerWorld, net: Transport, server_identity: PlayerIdentity) -> void:
	world = server_world
	transport = net
	identity = server_identity


func step() -> void:
	var t0 := Time.get_ticks_usec()
	_this_tick = {}
	_step()
	var took := Time.get_ticks_usec() - t0
	_tick_usec.append(took)
	if took > _slowest_usec:
		_slowest_usec = took
		_slowest = _this_tick


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
	out["slowest_ms"] = {}
	for k: String in _slowest:
		out["slowest_ms"][k] = snappedf(_slowest[k] / 1000.0, 0.1)
	_slowest = {}
	_slowest_usec = 0
	_sync_loads_seen = world.sync_loads
	_result_usec.sort()
	var r := _result_usec.size()
	out["result_ms"] = [_result_usec[r / 2] / 1000 if r else 0, _result_usec[mini(r - 1, r * 99 / 100)] / 1000 if r else 0,
		_result_usec[-1] / 1000 if r else 0]
	_result_usec.clear()
	if _request_at.size() > 10000:
		_request_at.clear()  # never answered (a client gone mid-request): not kept forever
	return out


## Adds the time since the previous mark to a named part of the tick.
func _lap(name: String) -> void:
	var now := Time.get_ticks_usec()
	_sections[name] = _sections.get(name, 0) + now - _mark
	_this_tick[name] = int(_this_tick.get(name, 0)) + now - _mark
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
	world.creatures.step(tick)
	_lap("creatures")
	world.combat.step(tick)
	_lap("combat")
	world.commit_async(wait_for_disk)
	world.flush_state(STATE_ROWS_PER_TICK)
	if wait_for_disk:
		world.writer.wait_idle()
	world.poll()
	for ack: Array in world.take_acks():
		if _request_at.has(ack[1]):
			_result_usec.append(Time.get_ticks_usec() - int(_request_at[ack[1]]))
			_request_at.erase(ack[1])
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
			_send_map_tiles(s)
	_lap("chunks")
	_update_replica()
	_update_creature_replicas()
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
				Protocol.MAP_REQUEST:
					_queue_map_tiles(s, String(m["location"]), (m["chunks"] as PackedByteArray).to_int32_array())
				Protocol.REQUEST:
					_request_at[ServerWorld.rs(m["request"], "request_id")] = Time.get_ticks_usec()
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
	_send(s, Transport.Channel.RELIABLE, Protocol.WELCOME, {"character_id": id, "location": p["location"], "tick": tick,
		"max_levels": world.max_levels})
	_send_map_known(s)
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
	if ack > s.acked and s.pending.has(ack):
		s.acked = ack
		_acknowledged(s, s.pending[ack])
		for id: int in s.pending.keys():
			if id <= ack:
				s.pending.erase(id)


## The client has a snapshot: what it carried is now known to be there. Every
## snapshot carries every difference from the known state (within its size),
## so the newest acknowledged one is enough; older ones are dropped unread.
func _acknowledged(s: Session, sent: Array) -> void:
	var versions: Dictionary = sent[0]
	for id: String in versions:
		if s.shown.has(id) or id == "~inventory":
			s.known[id] = versions[id]
	# Removed in that snapshot: the client has them no more (they are sent
	# whole if they come back).
	for id: String in sent[1]:
		s.removing.erase(id)
		if not s.shown.has(id):
			s.known.erase(id)


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
	return [location, ServerWorld.SURFACE] if world.levels.kind(location) == Levels.BUILDING_LEVEL else [location]


## Character and item states for this tick, shared by every client's snapshot.
func _update_replica() -> void:
	for id: String in _others.keys():
		var r: Replica = _replica[id]
		if (r.kind == "character" and not world.present.has(id)) or (r.kind == "item" and not world.items.has(id)) \
				or (r.kind == "projectile" and not world.combat.projectiles.has(id)):
			_gone(id)
	for id: String in world.combat.projectiles:
		var pr: Combat.Projectile = world.combat.projectiles[id]
		var r: Replica = _replica.get(id)
		if r == null:
			r = Replica.new("projectile", pr.location, world.levels.z(pr.location), int(pr.pos.x), int(pr.pos.y),
				{"kind": "projectile", "item": pr.ammo, "vx": int(pr.vel.x), "vy": int(pr.vel.y)})
			_replica[id] = r
			_others[id] = true
		else:
			if r.location != pr.location:
				r.relocate(pr.location, world.levels.z(pr.location))  # down to the street, up to a walkway
			if r.x != int(pr.pos.x) or r.y != int(pr.pos.y):
				r.x = int(pr.pos.x)
				r.y = int(pr.pos.y)
				r.hv += 1
	for id: String in world.present:
		var p: Dictionary = world.present[id]
		var pos: Vector2i = p["pos"]
		var r: Replica = _replica.get(id)
		if r == null:
			r = Replica.new("character", p["location"], world.levels.z(p["location"]), pos.x, pos.y,
				{"kind": "character", "name": p["name"], "appearance": p["appearance"]})
			_replica[id] = r
			_others[id] = true
		r.set_health(int(p.get("health", 0)), world.combat.max_health_of(id), int(p.get("deaths", 0)), int(p.get("swing", 0)))
		if r.cold.get("appearance", {}) != p["appearance"] or r.cold.get("name", "") != p["name"]:
			r.cold = r.cold.duplicate()
			r.cold["appearance"] = (p["appearance"] as Dictionary).duplicate(true)
			r.cold["name"] = p["name"]
			r.cold_size = Cbor.encode_fast(r.cold).size()
			r.cv += 1
		if r.location != p["location"]:
			r.relocate(p["location"], world.levels.z(p["location"]))
		if String(r.cold.get("held", "")) != String(p.get("held", "")):
			r.cold = r.cold.duplicate()
			r.cold["held"] = String(p.get("held", ""))  # what is in its hands, for all to see
			r.cold_size = Cbor.encode_fast(r.cold).size()
			r.cv += 1
		if r.x != pos.x or r.y != pos.y:
			r.x = pos.x
			r.y = pos.y
			r.hv += 1


func _gone(id: String) -> void:
	var r: Replica = _replica[id]
	r.gone = true
	_gone_tick = tick
	_replica.erase(id)
	_others.erase(id)
	if r.kind == "creature":
		(_grid.get(r.grid_key, {}) as Dictionary).erase(id)


## Creatures' replicas follow what the creatures did this tick (CreatureSim
## tells who came, left or moved): no walk over all of them. A creature's
## position goes out at most every CREATURE_HOT_TICKS, each on its own beat
## (and at once when it stops): clients ease toward it; creatures need not 20
## updates a second, and there may be hundreds in view.
func _update_creature_replicas() -> void:
	var ch := world.creatures.take_changes()
	for id: String in ch[1]:
		if _replica.has(id):
			_gone(id)
		_lagging.erase(id)
	for id: String in ch[0]:
		var c := world.creatures.get_creature(id)
		if c == null:
			continue
		if _replica.has(id):
			_lagging[id] = true  # left and came back in one tick
			continue
		var cold := {"kind": "creature", "creature": c.kind}
		if not c.looks.is_empty():
			cold["appearance"] = c.looks
		if c.owner != "":
			cold["owner"] = c.owner  # one's own animal (ADR-0030)
		var r := Replica.new("creature", c.location, world.levels.z(c.location), c.pos.x, c.pos.y, cold)
		r.set_health(c.health, world.combat.max_health_of(id), 0, int(world.combat.swings.get(id, 0)))
		r.phase = absi(hash(id)) % CREATURE_HOT_TICKS
		_replica[id] = r
		_to_grid(id, r, c.location)
	_lagging.merge(ch[2])
	for id: String in world.creatures.take_owner_changes():
		var c := world.creatures.get_creature(id)
		var r: Replica = _replica.get(id)
		if c and r and String(r.cold.get("owner", "")) != c.owner:
			r.cold = r.cold.duplicate()
			r.cold["owner"] = c.owner
			r.cold_size = Cbor.encode_fast(r.cold).size()
			r.cv += 1
	for id: String in world.combat.take_health_changes():
		var c := world.creatures.get_creature(id)
		var r: Replica = _replica.get(id)
		if c and r:
			r.set_health(c.health, world.combat.max_health_of(id), 0, int(world.combat.swings.get(id, 0)))
	for id: String in _lagging.keys():
		var c := world.creatures.get_creature(id)
		var r: Replica = _replica.get(id)
		if c == null or r == null:
			_lagging.erase(id)
			continue
		if (tick + r.phase) % CREATURE_HOT_TICKS != 0 and c.target != Creature.NO_TARGET:
			continue  # not its beat, and it walks on
		_lagging.erase(id)
		if r.x != c.pos.x or r.y != c.pos.y:
			r.x = c.pos.x
			r.y = c.pos.y
			r.hv += 1
			_to_grid(id, r, c.location)


## Creatures' replicas by cells of GRID x GRID: Vector3i(gx, gy, location
## number) -> {id: Replica}. Kept up to date as they move; views take the
## cells round the player.
const GRID := 8
var _grid := {}
var _loc_numbers := {}
## Creatures whose replica may lag behind them: id -> true.
var _lagging := {}
## Ids of character and item replicas (checked every tick for being gone).
var _others := {}
## The last tick a replica went (views drop gone ones then).
var _gone_tick := -1


func _loc_n(loc: String) -> int:
	if not _loc_numbers.has(loc):
		_loc_numbers[loc] = _loc_numbers.size()
	return _loc_numbers[loc]


func _to_grid(id: String, r: Replica, location: String) -> void:
	var at := Movement.cell_of(Vector2i(r.x, r.y))
	var key := Vector3i(floori(float(at.x) / GRID), floori(float(at.y) / GRID), _loc_n(location))
	if key == r.grid_key and (_grid.get(key, {}) as Dictionary).has(id):
		return
	(_grid.get(r.grid_key, {}) as Dictionary).erase(id)
	r.grid_key = key
	(_grid.get_or_add(key, {}) as Dictionary)[id] = r


func _item_replica(id: String) -> Replica:
	var r: Replica = _replica.get(id)
	if r == null:
		var it: Dictionary = world.items[id]
		r = Replica.new("item", it["location"], world.levels.z(it["location"]), it["x"], it["y"],
			{"kind": "item", "item": it["item"], "count": it["count"]})
		_replica[id] = r
		_others[id] = true
	return r


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


## What this client may see (id -> Replica), worked out again every few
## ticks (each session on its own beat), when the player moves to another
## grid cell or when items change; in between, the replicas it holds change
## in place, and new characters, creatures, items show up within a few ticks.
func _view(s: Session) -> Dictionary:
	var me: Dictionary = world.present[s.character_id]
	var loc: String = me["location"]
	var mine := Movement.cell_of(me["pos"])
	var ln := _loc_n(loc)
	var cell := Vector3i(floori(float(mine.x) / GRID), floori(float(mine.y) / GRID), ln)
	if tick < s.view_due and cell == s.view_cell and s.view_items_rev == world.items_rev:
		return s.view
	# Sessions on their own beats, so their views are not all worked out in one tick.
	s.view_due = tick + CREATURE_HOT_TICKS - (tick + s.peer) % CREATURE_HOT_TICKS
	s.view_cell = cell
	s.view_items_rev = world.items_rev
	s.view_built = tick
	var mc := Vector2i(floori(float(mine.x) / Chunk.SIZE), floori(float(mine.y) / Chunk.SIZE))
	var view := {}
	for id: String in world.present:
		var p: Dictionary = world.present[id]
		if p["location"] != loc:
			continue
		var pc := Movement.cell_of(p["pos"])
		if absi(floori(float(pc.x) / Chunk.SIZE) - mc.x) <= view_chunks and absi(floori(float(pc.y) / Chunk.SIZE) - mc.y) <= view_chunks:
			view[id] = _replica[id]
	for cy in range(mc.y - view_chunks, mc.y + view_chunks + 1):
		for cx in range(mc.x - view_chunks, mc.x + view_chunks + 1):
			for id: String in world.items_in_chunk(loc, cx, cy):
				view[id] = _item_replica(id)
	_creatures_into(view, ln, mine, "")
	# Others on the plan of buildings and the surface, where they can be
	# seen (ADR-0015): one on a walkway from the street, the street from a
	# window or an open roof — each checked by Sight.
	if _on_plan(loc):
		for id: String in world.present:
			var p: Dictionary = world.present[id]
			if p["location"] == loc or not _on_plan(p["location"]):
				continue
			var pc := Movement.cell_of(p["pos"])
			if absi(pc.x - mine.x) <= CREATURE_VIEW.x and absi(pc.y - mine.y) <= CREATURE_VIEW.y \
					and Sight.clear(world, loc, mine, p["location"], pc):
				view[id] = _replica[id]
		if loc != ServerWorld.SURFACE:
			_creatures_into(view, _loc_n(ServerWorld.SURFACE), mine, loc)
			for cy in range(mc.y - view_chunks, mc.y + view_chunks + 1):
				for cx in range(mc.x - view_chunks, mc.x + view_chunks + 1):
					for id: String in world.items_in_chunk(ServerWorld.SURFACE, cx, cy):
						var r := _item_replica(id)
						var ic := Movement.cell_of(Vector2i(r.x, r.y))
						if absi(ic.x - mine.x) <= CREATURE_VIEW.x and absi(ic.y - mine.y) <= CREATURE_VIEW.y \
								and Sight.clear(world, loc, mine, ServerWorld.SURFACE, ic):
							view[id] = r
	s.view = view
	return view


## Creatures of the grid's location `ln` as far as a screen sees (zoomed
## out) and a little more round `mine`; seen from `from` (another location
## on the plan) only those Sight lets through.
func _creatures_into(view: Dictionary, ln: int, mine: Vector2i, from: String) -> void:
	var lo := (mine - CREATURE_VIEW) * Movement.UNIT
	var hi := (mine + CREATURE_VIEW + Vector2i.ONE) * Movement.UNIT
	for gy in range(floori(float(mine.y - CREATURE_VIEW.y) / GRID), floori(float(mine.y + CREATURE_VIEW.y) / GRID) + 1):
		for gx in range(floori(float(mine.x - CREATURE_VIEW.x) / GRID), floori(float(mine.x + CREATURE_VIEW.x) / GRID) + 1):
			var cell_creatures: Dictionary = _grid.get(Vector3i(gx, gy, ln), {})
			for id: String in cell_creatures:
				var r: Replica = cell_creatures[id]
				if r.x >= lo.x and r.x < hi.x and r.y >= lo.y and r.y < hi.y \
						and (from == "" or Sight.clear(world, from, mine, r.location, Movement.cell_of(Vector2i(r.x, r.y)),
							Sight.EYE, float(BodySize.of(world.content.get_def(String(r.cold.get("creature", ""))))["body"]))):
					view[id] = r


func _on_plan(location: String) -> bool:
	return location == ServerWorld.SURFACE or world.levels.kind(location) == Levels.BUILDING_LEVEL


## A snapshot (protocol 7): only what differs from what the client has
## acknowledged. Positions of entities it has go packed [net, x, y] in "hot";
## an entity new to it comes whole (with "uid") in "entities", as do cold
## changes and the own inventory; "removed" lists nets that left the view
## (repeated until acknowledged).
func _send_snapshot(s: Session) -> void:
	var view := _view(s)
	var my_pos: Vector2i = world.present[s.character_id]["pos"]
	# Arrows fly too fast to wait for the view: each tick, those near.
	var my_loc: String = world.present[s.character_id]["location"]
	for id: String in world.combat.projectiles:
		var r: Replica = _replica.get(id)
		if r and (r.location == my_loc or (_on_plan(r.location) and _on_plan(my_loc))) \
				and absi(r.x - my_pos.x) <= CREATURE_VIEW.x * Movement.UNIT \
				and absi(r.y - my_pos.y) <= CREATURE_VIEW.y * Movement.UNIT:
			view[id] = r
	var due := []
	for id: String in view:
		var r: Replica = view[id]
		if s.known.get(id) == Vector3i(r.hv, r.wv, r.cv) or r.gone:
			continue
		due.append([-1 if id == s.character_id else absi(r.x - my_pos.x) + absi(r.y - my_pos.y), id])
	# A snapshot goes unreliably and must stay within a packet: entities up to
	# SNAPSHOT_BYTES (sizes estimated, not encoded), the nearest first; the
	# others come in the next snapshots.
	due.sort()
	var room := SNAPSHOT_BYTES
	var sent := {}
	var changed := {}
	var hot := PackedInt32Array()
	var warm := PackedInt32Array()
	for pair: Array in due:
		var id: String = pair[1]
		var r: Replica = view[id]
		var known: Variant = s.known.get(id)
		var k: Vector3i = known if known != null else Vector3i(-1, -1, -1)
		var cost := 12
		if known == null:
			cost += r.cold_size + 60
		elif k.z != r.cv:
			cost += r.cold_size + 4
		if known != null and k.y != r.wv:
			cost += 16
		if cost > room and id != s.character_id:
			continue
		room -= cost
		sent[id] = r.version()
		var n := _net_id(s, id)
		if known == null:
			s.shown[id] = true
			s.removing.erase(id)
			var entry := r.cold.duplicate()
			entry["x"] = r.x
			entry["y"] = r.y
			entry["uid"] = id
			if r.max_health > 0:
				entry["health"] = r.health
				entry["max_health"] = r.max_health
				entry["deaths"] = r.deaths
				entry["swing"] = r.swing  # blows from now on are seen as swings
			changed[n] = entry
			continue
		if k.x != r.hv:
			hot.append(n)
			hot.append(r.x)
			hot.append(r.y)
		if k.y != r.wv:
			warm.append_array([n, r.health, r.max_health, r.deaths, r.swing])
		if k.z != r.cv:
			changed[n] = r.cold.duplicate()
	# The player's own inventory goes only to that player, and only when it changed.
	var inv_v := world.inventory_version(s.character_id)
	if s.known.get("~inventory", -1) != inv_v:
		sent["~inventory"] = inv_v
		var mine_n := _net_id(s, s.character_id)
		if not changed.has(mine_n):
			changed[mine_n] = {}
		changed[mine_n]["inventory"] = world.inventory(s.character_id).stacks.duplicate()
		changed[mine_n]["friends"] = world.friends_of(s.character_id).keys()
	# Who left the view: only when it was worked out again or something went.
	for id: String in (s.shown.keys() if s.view_built == tick or _gone_tick == tick else []):
		var r: Replica = view.get(id)
		if r == null or r.gone:
			s.shown.erase(id)
			s.known.erase(id)
			s.removing[id] = true
	var removed := PackedInt32Array()
	for id: String in s.removing:
		removed.append(s.net_ids[id])
	var sid := s.next_snapshot
	s.next_snapshot += 1
	s.pending[sid] = [sent, s.removing.keys()]
	if s.pending.size() > SNAPSHOT_HISTORY:
		s.pending.erase(s.pending.keys().min())
	_send(s, Transport.Channel.STATE, Protocol.SNAPSHOT, {"id": sid, "tick": tick, "hot": hot.to_byte_array(),
		"warm": warm.to_byte_array(),
		"entities": changed, "removed": removed.to_byte_array(), "input_ack": s.last_input_seq,
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
					world.explore(s.character_id, shown, cx, cy)
					_send(s, Transport.Channel.BULK, Protocol.CHUNK, {"location": shown, "cx": cx, "cy": cy,
						"data": world.encoded_chunk(shown, cx, cy)})


## Map tiles a client may have (ADR-0020): only of chunks its character has
## seen; queued, sent a few a tick.
const MAP_TILES_PER_TICK := 12
const MAP_QUEUE_MAX := 2048


func _queue_map_tiles(s: Session, location: String, pairs: PackedInt32Array) -> void:
	var seen: Dictionary = world.explored(s.character_id).get(location, {})
	for i in range(0, pairs.size() - 1, 2):
		if s.map_queue.size() >= MAP_QUEUE_MAX:
			return
		if seen.has(Vector2i(pairs[i], pairs[i + 1])):
			s.map_queue.append([location, pairs[i], pairs[i + 1]])


func _send_map_tiles(s: Session) -> void:
	if s.map_queue.is_empty():
		return
	var by_location := {}
	for i in mini(MAP_TILES_PER_TICK, s.map_queue.size()):
		var q: Array = s.map_queue.pop_front()
		var tile := world.map_tile(q[0], q[1], q[2])
		if not tile.is_empty():
			(by_location.get_or_add(q[0], []) as Array).append([q[1], q[2], tile])
	for loc: String in by_location:
		_send(s, Transport.Channel.BULK, Protocol.MAP_TILES, {"location": loc, "tiles": by_location[loc]})


## What the character has seen, every location, as it comes into the world.
func _send_map_known(s: Session) -> void:
	var all := world.explored(s.character_id)
	for loc: String in all:
		var pairs := PackedInt32Array()
		for at: Vector2i in all[loc]:
			pairs.append(at.x)
			pairs.append(at.y)
		_send(s, Transport.Channel.BULK, Protocol.MAP_KNOWN, {"location": loc, "z": world.levels.z(loc),
			"chunks": pairs.to_byte_array()})


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
