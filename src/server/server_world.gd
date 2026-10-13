class_name ServerWorld
extends RefCounted
## Authoritative world state in memory, backed by the world database (ADR-0005).
##
## Requests carry a request_id chosen by the client. A request is applied
## once: a repeat (resent packet, reconnect) gets the original result and
## changes nothing. Results are acknowledged only after the batch holding
## their changes is committed, so an acknowledged change survives a crash.
##
## The simulation never waits for the disk. commit_async() snapshots what
## changed into a batch for the StoreWriter thread; poll() releases the
## acknowledgements of committed batches. flush_state() hands frequently
## changing entity state to the writer; the server calls it periodically
## (or a slice at a time), never every tick.

const SURFACE := "surface"

var content: ContentRegistry
## Makes surface chunks nobody has visited (null if the content has no biomes).
var generator: SurfaceGenerator
var loader := ChunkLoader.new()
var world_seed := 0
## Chunks the simulation had to load or generate itself because the loader
## had not brought them yet (each one costs tick time).
var sync_loads := 0
## Requests are remembered at least this many ticks for idempotency.
var request_memory_ticks := 20 * 60 * 30
var tick := 0
## Read connection of the simulation thread.
var store: WorldStore
var writer: StoreWriter

var _chunks := {}
var _inventories := {}
var _entities := {}
var _dirty_chunks := {}
var _dirty_inventories := {}
var _dirty_entities := {}
## "actor|request_id" -> result, for requests processed in this session
var _results := {}
## [actor, request_id, result] applied but not yet handed to the writer
var _pending: Array = []
## keys of requests not yet committed (pending or in a batch being written)
var _uncommitted := {}
## batch id -> [[actor, request_id, result], ...] waiting for the commit
var _in_flight := {}
## [actor, request_id, result] ready to send to clients
var _outbox: Array = []
var _prune_before := -1
## While this many batches wait for the writer, commit_async() holds new
## changes back; they go out together in the next batch (backpressure).
var max_batches_in_flight := 2
var _closed := false

## Where characters appear the first time they enter this world.
var spawn_location := SURFACE
var spawn_position := Vector2i.ZERO
## Characters in the world right now:
## id -> {"location", "pos": Vector2i, "name", "appearance"}
var present := {}
## Characters this world knows: id -> {"owner", "data": portable data}
var _characters := {}
var _dirty_characters := {}
var _dirty_world_characters := {}
## Places of characters that left this session: their last write may still be
## on its way to the disk, and the read connection would see an older one.
var _left_places := {}
## chunk key -> revision, raised on every change; clients compare it
var _chunk_rev := {}
## chunk key -> [revision, encoded bytes], shared by all clients
var _encoded := {}


## Opens a world: a read connection here, a write connection on the writer
## thread, another read connection on the chunk loader thread.
## options: those of WorldStore.open, plus "seed" for a new world.
static func open(db_path: String, registry: ContentRegistry, options := {}) -> ServerWorld:
	var s := WorldStore.new()
	if not s.open(db_path, options):
		push_error(s.last_error)
		return null
	if s.read_meta("seed") == "":
		var seed_value := int(options.get("seed", randi()))
		if not (s.write_meta("seed", str(seed_value)) and s.write_meta("world_id", Uuid.v4())):
			push_error(s.last_error)
			s.close()
			return null
	var w := StoreWriter.new()
	if not w.start(db_path, options):
		push_error(w.last_error())
		s.close()
		return null
	var world := ServerWorld.new(s, registry, w)
	world.world_seed = int(s.read_meta("seed"))
	var g := SurfaceGenerator.new(world.world_seed, registry)
	world.generator = g if g.can_generate() else null
	var lg := SurfaceGenerator.new(world.world_seed, registry) if world.generator else null
	if not world.loader.start(db_path, lg):
		w.stop()
		s.close()
		return null
	return world


func _init(read_store: WorldStore, registry: ContentRegistry, store_writer: StoreWriter) -> void:
	store = read_store
	content = registry
	writer = store_writer


## Commits everything outstanding, stops the writer, closes both connections.
func close() -> void:
	if _closed:
		return
	_closed = true
	loader.stop()
	sync()
	writer.stop()
	store.close()


## Stops without committing what is not yet handed to the writer (tests of crashes).
func abandon() -> void:
	if _closed:
		return
	_closed = true
	loader.stop()
	writer.stop()
	store.close()


static func chunk_key(location: String, cx: int, cy: int) -> String:
	return "%s|%d|%d" % [location, cx, cy]


## A chunk, loaded or generated now if the loader has not brought it yet.
func chunk(location: String, cx: int, cy: int) -> Chunk:
	var key := chunk_key(location, cx, cy)
	var c: Chunk = _chunks.get(key)
	if c == null:
		var data := store.get_chunk(location, cx, cy)
		if not data.is_empty():
			c = ChunkCodec.decode(data)
			assert(c != null, "corrupt chunk %s: %s" % [key, ChunkCodec.last_error])
		elif location == SURFACE and generator:
			c = generator.generate(cx, cy)
			_dirty_chunks[key] = true  # generated once, then kept whole
		else:
			c = Chunk.new()
		_chunks[key] = c
		sync_loads += 1
	return c


func has_chunk(location: String, cx: int, cy: int) -> bool:
	return _chunks.has(chunk_key(location, cx, cy))


## Asks the loader thread for a chunk that is not in memory yet.
func prefetch(location: String, cx: int, cy: int) -> void:
	if not _chunks.has(chunk_key(location, cx, cy)):
		loader.request(location, cx, cy)


## Takes chunks the loader finished (call every tick).
func poll_loaded() -> void:
	for r: Array in loader.take_ready():
		var key := chunk_key(r[0], r[1], r[2])
		if _chunks.has(key):
			continue  # loaded meanwhile by chunk(); the same content
		_chunks[key] = r[3]
		if r[4]:
			_dirty_chunks[key] = true


func inventory(owner: String) -> Inventory:
	var inv: Inventory = _inventories.get(owner)
	if inv == null:
		var data := store.get_inventory(owner)
		inv = Inventory.from_data(Cbor.decode(data).value) if not data.is_empty() else Inventory.new()
		_inventories[owner] = inv
	return inv


## A character arrives. The first time, its profile becomes this world's copy
## (its inventory moves into the world's inventories); later the world's own
## copy is used and only the owner is checked. "" on success, else a reason.
## What a second server does with a character it already knows from
## elsewhere (move or copy) is open (Q-01); this is the single-world case.
func enter(owner: String, c: PortableCharacter) -> String:
	var id := c.character_id
	var known := _known_character(id)
	if known.is_empty():
		var data := c.to_data()
		data["inventory"] = Inventory.new().to_data()
		known = {"owner": owner, "data": data}
		_characters[id] = known
		_dirty_characters[id] = true
		for item: String in c.inventory.stacks:
			grant(id, item, c.inventory.stacks[item])
	elif known["owner"] != owner:
		return "not_owner"
	if present.has(id):
		return "already_present"
	var place := {"location": spawn_location, "x": spawn_position.x, "y": spawn_position.y}
	var stored := store.get_world_character(id)
	if _left_places.has(id):
		place = _left_places[id]
		_left_places.erase(id)
	elif not stored.is_empty():
		place = Cbor.decode(stored).value
	var data: Dictionary = known["data"]
	present[id] = {"location": String(place["location"]), "pos": Vector2i(int(place["x"]), int(place["y"])),
		"name": data["name"], "appearance": data["appearance"]}
	_dirty_world_characters[id] = true
	return ""


func leave(id: String) -> void:
	if present.has(id):
		var p: Dictionary = present[id]
		_left_places[id] = {"location": p["location"], "x": p["pos"].x, "y": p["pos"].y}
		_dirty_world_characters[id] = true
		flush_state()  # its last position goes out with this batch
		present.erase(id)


func move_character(id: String, pos: Vector2i) -> void:
	var p: Dictionary = present[id]
	if p["pos"] != pos:
		p["pos"] = pos
		_dirty_world_characters[id] = true


## Whether a cell of a location blocks walking.
func is_solid(location: String, x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return Terrain.is_solid(chunk(location, cx, cy), x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, content)


func chunk_revision(location: String, cx: int, cy: int) -> int:
	return _chunk_rev.get(chunk_key(location, cx, cy), 0)


## The chunk as clients receive it, encoded once per revision.
func encoded_chunk(location: String, cx: int, cy: int) -> PackedByteArray:
	var key := chunk_key(location, cx, cy)
	var rev: int = _chunk_rev.get(key, 0)
	var cached: Array = _encoded.get(key, [])
	if cached.is_empty() or cached[0] != rev:
		cached = [rev, ChunkCodec.encode(chunk(location, cx, cy))]
		_encoded[key] = cached
	return cached[1]


func _known_character(id: String) -> Dictionary:
	if _characters.has(id):
		return _characters[id]
	var row := store.get_character(id)
	if row.is_empty():
		return {}
	var known := {"owner": String(row["owner"]), "data": Cbor.decode(row["data"]).value}
	_characters[id] = known
	return known


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
	_uncommitted[key] = true


## Hands everything changed since the last call to the writer as one batch.
## Returns at once; acknowledgements come out of poll() after the commit.
## If the writer is behind, the changes wait for a later call unless forced.
func commit_async(force := false) -> void:
	if _pending.is_empty() and _dirty_chunks.is_empty() and _dirty_inventories.is_empty() \
			and _dirty_characters.is_empty() and _prune_before < 0:
		return
	if not force and writer.queued_operations() >= max_batches_in_flight:
		return
	var b := StoreWriter.Batch.new()
	for key: String in _dirty_chunks:
		var p := key.split("|")
		b.chunks.append([p[0], int(p[1]), int(p[2]), (_chunks[key] as Chunk).snapshot()])
	for owner: String in _dirty_inventories:
		b.inventories.append([owner, inventory(owner).to_data()])
	for p: Array in _pending:
		b.requests.append([p[0], p[1], tick, (p[2] as Dictionary).duplicate(true)])
	for id: String in _dirty_characters:
		b.characters.append([id, _characters[id]["owner"], (_characters[id]["data"] as Dictionary).duplicate(true)])
	_dirty_characters.clear()
	b.prune_before = _prune_before
	_prune_before = -1
	_dirty_chunks.clear()
	_dirty_inventories.clear()
	_in_flight[writer.submit(b)] = _pending
	_pending = []


## Moves acknowledgements of committed batches to the outbox.
func poll() -> void:
	for id in writer.take_done():
		for p: Array in _in_flight.get(id, []):
			_uncommitted.erase(p[0] + "|" + p[1])
			_outbox.append(p)
		_in_flight.erase(id)


## Commits everything and waits for it (tests, shutdown, before backups).
## False if the database keeps refusing (see writer.last_error()).
func sync() -> bool:
	commit_async(true)
	flush_state()
	writer.wait_idle()
	poll()
	return writer.last_error() == ""


## Hands changed entity state to the writer (encoded there). At most `limit`
## entities per call (-1: all), so the server can spread the work over ticks.
func flush_state(limit := -1) -> void:
	if _dirty_entities.is_empty() and _dirty_world_characters.is_empty():
		return
	var b := StoreWriter.Batch.new()
	for id: String in _dirty_world_characters.keys():
		if present.has(id):
			var p: Dictionary = present[id]
			b.world_characters.append([id, {"location": p["location"], "x": p["pos"].x, "y": p["pos"].y}])
		_dirty_world_characters.erase(id)
	for id: String in _dirty_entities.keys():
		if limit >= 0 and b.entities.size() >= limit:
			break
		var e: Array = _entities[id]
		var cx := floori(float(e[1]) / Chunk.SIZE)
		var cy := floori(float(e[2]) / Chunk.SIZE)
		b.entities.append([id, e[0], cx, cy, e[3], (e[4] as Dictionary).duplicate(true)])
		_dirty_entities.erase(id)
	writer.submit(b)


## Acknowledgements ready to send: [actor, request_id, result].
func take_acks() -> Array:
	var out := _outbox
	_outbox = []
	return out


## Forgets old processed requests: in memory now, in the store with the next batch.
func prune_requests() -> void:
	var limit := tick - request_memory_ticks
	if limit <= 0:
		return
	# Committed results are in the store; keep only the uncommitted ones here.
	var keep := {}
	for key: String in _uncommitted:
		keep[key] = _results[key]
	_results = keep
	_prune_before = limit


func uncommitted_count() -> int:
	return _uncommitted.size()


func dirty_entity_count() -> int:
	return _dirty_entities.size()


func _is_pending(key: String) -> bool:
	return _uncommitted.has(key)


func _apply(actor: String, r: Dictionary) -> Dictionary:
	match String(r.get("type", "")):
		"build":
			return _build(actor, r)
		"dismantle":
			return _dismantle(actor, r)
		"transfer":
			return _transfer(actor, r)
	return {"ok": false, "reason": "unknown_type"}


func _someone_stands_on(location: String, x: int, y: int) -> bool:
	for id: String in present:
		var p: Dictionary = present[id]
		var pos: Vector2i = p["pos"]
		if p["location"] == location \
				and pos.x + Movement.HALF_X > x * Movement.UNIT and pos.x - Movement.HALF_X < (x + 1) * Movement.UNIT \
				and pos.y + Movement.HALF_Y > y * Movement.UNIT and pos.y - Movement.HALF_Y < (y + 1) * Movement.UNIT:
			return true
	return false


func _changed(key: String) -> void:
	_dirty_chunks[key] = true
	_chunk_rev[key] = _chunk_rev.get(key, 0) + 1


func _cell(r: Dictionary) -> Array:
	var x := int(r.get("x", 0))
	var y := int(r.get("y", 0))
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return [String(r.get("location", "")), cx, cy, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE]


func _build(actor: String, r: Dictionary) -> Dictionary:
	var part := String(r.get("part", ""))
	if content.kind_of(part) != "structure":
		return {"ok": false, "reason": "unknown_part"}
	var at := _cell(r)
	var c := chunk(at[0], at[1], at[2])
	if c.get_cell("structure", at[3], at[4]) != "":
		return {"ok": false, "reason": "occupied"}
	if Terrain.is_solid(c, at[3], at[4], content):
		return {"ok": false, "reason": "blocked"}  # water, a tree...
	if _someone_stands_on(at[0], int(r.get("x", 0)), int(r.get("y", 0))):
		return {"ok": false, "reason": "someone_there"}
	var costs := content.structure_cost(part)
	var inv := inventory(actor)
	if not inv.has_all(costs):
		return {"ok": false, "reason": "materials"}
	for id: String in costs:
		inv.remove(id, int(costs[id]))
	c.set_cell("structure", at[3], at[4], part)
	c.set_props(at[3], at[4], {"owner": actor})
	_changed(chunk_key(at[0], at[1], at[2]))
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
	if not content.has(part):
		# Its pack is gone: keep the part as it is rather than lose it unpaid.
		return {"ok": false, "reason": "unknown_part"}
	c.set_cell("structure", at[3], at[4], "")
	c.set_props(at[3], at[4], {})
	_changed(chunk_key(at[0], at[1], at[2]))
	var costs := content.structure_cost(part)
	var inv := inventory(actor)
	for id: String in costs:
		inv.add(id, int(costs[id]))
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
