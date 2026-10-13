class_name ServerWorld
extends RefCounted
## Authoritative world state in memory, backed by a WorldStore (ADR-0005).
##
## Requests carry a request_id chosen by the client. A request is applied
## once: a repeat (resent packet, reconnect) gets the original result and
## changes nothing. Results are acknowledged only after the batch holding
## their changes is committed, so an acknowledged change survives a crash.
##
## flush_operations() commits the changed chunks, inventories and processed
## requests in one transaction. flush_state() writes frequently changing
## entity state; the server calls it periodically, not every tick.

## Content id -> {material id: count}. Stand-in until the content registry exists.
var part_costs := {}
## Requests are remembered at least this many ticks for idempotency.
var request_memory_ticks := 20 * 60 * 30
var tick := 0
var store: WorldStore

var _chunks := {}
var _inventories := {}
var _entities := {}
var _dirty_chunks := {}
var _dirty_inventories := {}
var _dirty_entities := {}
## "actor|request_id" -> result, for requests processed in this session
var _results := {}
## [actor, request_id, result] applied but not yet committed
var _pending: Array = []
var _pending_keys := {}
## [actor, request_id, result] ready to send to clients
var _outbox: Array = []


func _init(world_store: WorldStore) -> void:
	store = world_store


static func chunk_key(location: String, cx: int, cy: int) -> String:
	return "%s|%d|%d" % [location, cx, cy]


func chunk(location: String, cx: int, cy: int) -> Chunk:
	var key := chunk_key(location, cx, cy)
	var c: Chunk = _chunks.get(key)
	if c == null:
		var data := store.get_chunk(location, cx, cy)
		c = ChunkCodec.decode(data) if not data.is_empty() else Chunk.new()
		assert(c != null, "corrupt chunk %s: %s" % [key, ChunkCodec.last_error])
		_chunks[key] = c
	return c


func inventory(owner: String) -> Inventory:
	var inv: Inventory = _inventories.get(owner)
	if inv == null:
		var data := store.get_inventory(owner)
		inv = Inventory.from_data(Cbor.decode(data).value) if not data.is_empty() else Inventory.new()
		_inventories[owner] = inv
	return inv


## Gives items outside of any request (world setup, tests).
func grant(owner: String, content_id: String, n: int) -> void:
	inventory(owner).add(content_id, n)
	_dirty_inventories[owner] = true


## Frequently changing state of an entity (position, needs...). CBOR-compatible.
func set_entity(id: String, location: String, x: int, y: int, kind: String, data: Dictionary) -> void:
	_entities[id] = [location, x, y, kind, data]
	_dirty_entities[id] = true


func handle(actor: String, request: Dictionary) -> void:
	var rid := String(request.get("request_id", ""))
	if rid == "":
		_outbox.append([actor, rid, {"ok": false, "reason": "no_request_id"}])
		return
	var key := actor + "|" + rid
	if _results.has(key):
		if not _is_pending(key):
			_outbox.append([actor, rid, _results[key]])
		return  # still pending: its acknowledgement comes with the commit
	var stored := store.get_request(actor, rid)
	if not stored.is_empty():
		var old: Dictionary = Cbor.decode(stored).value
		_results[key] = old
		_outbox.append([actor, rid, old])
		return
	var result := _apply(actor, request)
	_results[key] = result
	_pending.append([actor, rid, result])
	_pending_keys[key] = true


## Commits applied requests. Returns false (and keeps everything pending,
## acknowledging nothing) if the database refused the transaction.
func flush_operations() -> bool:
	if _pending.is_empty() and _dirty_chunks.is_empty() and _dirty_inventories.is_empty():
		return true
	if not store.begin():
		return false
	var ok := true
	for key: String in _dirty_chunks:
		var p := key.split("|")
		ok = ok and store.put_chunk(p[0], int(p[1]), int(p[2]), ChunkCodec.encode(_chunks[key]))
	for owner: String in _dirty_inventories:
		ok = ok and store.put_inventory(owner, Cbor.encode(inventory(owner).to_data()))
	for p: Array in _pending:
		ok = ok and store.put_request(p[0], p[1], tick, Cbor.encode(p[2]))
	if not ok:
		store.rollback()
		return false
	if not store.commit():
		return false
	_dirty_chunks.clear()
	_dirty_inventories.clear()
	_outbox.append_array(_pending)
	_pending.clear()
	_pending_keys.clear()
	return true


## Writes changed entity state in one transaction.
func flush_state() -> bool:
	if _dirty_entities.is_empty():
		return true
	if not store.begin():
		return false
	for id: String in _dirty_entities:
		var e: Array = _entities[id]
		var cx := floori(float(e[1]) / Chunk.SIZE)
		var cy := floori(float(e[2]) / Chunk.SIZE)
		if not store.put_entity(id, e[0], cx, cy, e[3], Cbor.encode(e[4])):
			store.rollback()
			return false
	if not store.commit():
		return false
	_dirty_entities.clear()
	return true


## Acknowledgements ready to send: [actor, request_id, result].
func take_acks() -> Array:
	var out := _outbox
	_outbox = []
	return out


## Forgets old processed requests (memory and store).
func prune_requests() -> bool:
	var limit := tick - request_memory_ticks
	if limit <= 0:
		return true
	# Committed results are in the store; keep only the pending ones in memory.
	var keep := {}
	for key: String in _pending_keys:
		keep[key] = _results[key]
	_results = keep
	return store.prune_requests(limit)


func pending_count() -> int:
	return _pending.size()


func _is_pending(key: String) -> bool:
	return _pending_keys.has(key)


func _apply(actor: String, r: Dictionary) -> Dictionary:
	match String(r.get("type", "")):
		"build":
			return _build(actor, r)
		"dismantle":
			return _dismantle(actor, r)
		"transfer":
			return _transfer(actor, r)
	return {"ok": false, "reason": "unknown_type"}


func _cell(r: Dictionary) -> Array:
	var x := int(r.get("x", 0))
	var y := int(r.get("y", 0))
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return [String(r.get("location", "")), cx, cy, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE]


func _build(actor: String, r: Dictionary) -> Dictionary:
	var part := String(r.get("part", ""))
	if not part_costs.has(part):
		return {"ok": false, "reason": "unknown_part"}
	var at := _cell(r)
	var c := chunk(at[0], at[1], at[2])
	if c.get_cell("structure", at[3], at[4]) != "":
		return {"ok": false, "reason": "occupied"}
	var costs: Dictionary = part_costs[part]
	var inv := inventory(actor)
	if not inv.has_all(costs):
		return {"ok": false, "reason": "materials"}
	for id: String in costs:
		inv.remove(id, int(costs[id]))
	c.set_cell("structure", at[3], at[4], part)
	c.set_props(at[3], at[4], {"owner": actor})
	_dirty_chunks[chunk_key(at[0], at[1], at[2])] = true
	_dirty_inventories[actor] = true
	return {"ok": true}


func _dismantle(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var c := chunk(at[0], at[1], at[2])
	var part := c.get_cell("structure", at[3], at[4])
	if part == "":
		return {"ok": false, "reason": "empty"}
	if c.get_props(at[3], at[4]).get("owner", "") != actor:
		return {"ok": false, "reason": "not_owner"}
	c.set_cell("structure", at[3], at[4], "")
	c.set_props(at[3], at[4], {})
	var costs: Dictionary = part_costs.get(part, {})
	var inv := inventory(actor)
	for id: String in costs:
		inv.add(id, int(costs[id]))
	_dirty_chunks[chunk_key(at[0], at[1], at[2])] = true
	_dirty_inventories[actor] = true
	return {"ok": true, "part": part}


func _transfer(actor: String, r: Dictionary) -> Dictionary:
	var to := String(r.get("to", ""))
	var item := String(r.get("item", ""))
	var n := int(r.get("count", 0))
	if to == "" or to == actor or n <= 0:
		return {"ok": false, "reason": "bad_request"}
	if not inventory(actor).remove(item, n):
		return {"ok": false, "reason": "not_enough"}
	inventory(to).add(item, n)
	_dirty_inventories[actor] = true
	_dirty_inventories[to] = true
	return {"ok": true}
