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

const SURFACE := Levels.SURFACE
## How far a character reaches, in movement units from its feet to a cell's centre.
const USE_REACH := 2 * Movement.UNIT
const PICKUP_REACH := 2 * Movement.UNIT
const BUILD_REACH := 6 * Movement.UNIT

var content: ContentRegistry
var levels := Levels.new()
## Highest building level a new ceiling may create (ADR-0007): a server
## setting, changeable; lowering it never removes existing levels.
var max_levels := 3
## Characters moved to another location since the server last asked
## (stairs, merged buildings); the server tells their clients.
var relocated := {}
var _removed_location_chunks := {}
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

## Items every character gets on its first arrival in this world: a world
## rule set by the server, not part of the profile. Provisional, until crafts
## and gathering provide materials.
var starter_kit := {}
## Server setting: what a character wears when it wears nothing (slot ->
## item), on arrival; also dresses characters made before clothes were drawn.
var starter_outfit := {}
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
## Things lying in the world: id -> {"location", "x", "y", "item", "count"}
## (x, y in movement units). Written in operation batches with the
## inventories they come from or go to, so nothing is lost or doubled.
var items := {}
var _items_by_chunk := {}
var _dirty_items := {}
var _removed_items := {}
var _inventory_version := {}
## Unloading (unload_idle): chunk key -> last tick a player needed it.
var _needed := {}
## chunk key -> id of the last batch that writes the chunk or things on it.
var _written_by := {}
var _last_committed := 0
## Raised by any chunk change anywhere (lets the server skip unchanged views).
var revision_epoch := 0
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
	world.levels.load_rows(s.all_locations())
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
			_encoded[key] = [_chunk_rev.get(key, 0), data]
		elif location == SURFACE and generator:
			c = generator.generate(cx, cy)
			_dirty_chunks[key] = true  # generated once, then kept whole
		else:
			c = Chunk.new()
		_chunks[key] = c
		_take_items(location, store.entities_in_chunk(location, cx, cy))
		sync_loads += 1
	return c


## Ids of things lying in a chunk.
func items_in_chunk(location: String, cx: int, cy: int) -> Array:
	return (_items_by_chunk.get(chunk_key(location, cx, cy), {}) as Dictionary).keys()


func _take_items(location: String, rows: Array) -> void:
	for row: Dictionary in rows:
		if row["kind"] != "item" or items.has(row["id"]):
			continue
		var d: Dictionary = Cbor.decode(row["data"]).value
		_place_item(row["id"], {"location": location, "x": int(d["x"]), "y": int(d["y"]),
			"item": String(d["item"]), "count": int(d["count"])})


func _place_item(id: String, it: Dictionary) -> void:
	items[id] = it
	var key := _item_chunk_key(it)
	if not _items_by_chunk.has(key):
		_items_by_chunk[key] = {}
	_items_by_chunk[key][id] = true


func _item_chunk_key(it: Dictionary) -> String:
	var cell := Movement.cell_of(Vector2i(it["x"], it["y"]))
	return chunk_key(it["location"], floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE))


func has_chunk(location: String, cx: int, cy: int) -> bool:
	return _chunks.has(chunk_key(location, cx, cy))


## Players need these chunks now (keeps them from being unloaded).
func mark_needed(location: String, cx: int, cy: int) -> void:
	_needed[chunk_key(location, cx, cy)] = tick


## Unloads chunks nobody needed for `idle_ticks`, if nothing about them is
## waiting for the disk: the chunk itself is not dirty, no thing on it is
## dirty, and every batch that wrote it or its things is committed. Reading
## it back later then gives exactly what was in memory. Returns how many.
func unload_idle(idle_ticks: int) -> int:
	var dirty_item_chunks := {}
	for id: String in _dirty_items:
		dirty_item_chunks[_item_chunk_key(items[id])] = true
	var gone := 0
	for key: String in _chunks.keys():
		if tick - int(_needed.get(key, -idle_ticks - 1)) <= idle_ticks:
			continue
		if _dirty_chunks.has(key) or dirty_item_chunks.has(key) or int(_written_by.get(key, 0)) > _last_committed:
			continue
		for id: String in (_items_by_chunk.get(key, {}) as Dictionary):
			items.erase(id)
		_items_by_chunk.erase(key)
		_chunks.erase(key)
		_encoded.erase(key)
		_needed.erase(key)
		_written_by.erase(key)
		gone += 1
	return gone


func loaded_chunks() -> int:
	return _chunks.size()


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
		_take_items(r[0], r[5])
		if not (r[6] as PackedByteArray).is_empty():
			_encoded[key] = [_chunk_rev.get(key, 0), r[6]]
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
		for item: String in starter_kit:
			grant(id, item, int(starter_kit[item]))
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
	if (data.get("equipment", {}) as Dictionary).is_empty() and not starter_outfit.is_empty():
		data["equipment"] = starter_outfit.duplicate()
		_dirty_characters[id] = true
	present[id] = {"location": String(place["location"]), "pos": Vector2i(int(place["x"]), int(place["y"])),
		"name": data["name"], "appearance": shown_look(data)}
	_dirty_world_characters[id] = true
	return ""


## What others see of a character: its appearance and what it wears.
static func shown_look(data: Dictionary) -> Dictionary:
	var look: Dictionary = (data["appearance"] as Dictionary).duplicate(true)
	look["worn"] = (data.get("equipment", {}) as Dictionary).duplicate()
	return look


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
	return Terrain.is_solid(chunk(location, cx, cy), x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, content, location != SURFACE)


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
	_touch_inventory(owner)


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
			and _dirty_characters.is_empty() and _dirty_items.is_empty() and _removed_items.is_empty() \
			and levels.dirty.is_empty() and levels.removed.is_empty() \
			and _prune_before < 0:
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
	for id: String in _dirty_items:
		var it: Dictionary = items[id]
		var cell := Movement.cell_of(Vector2i(it["x"], it["y"]))
		b.items.append([id, it["location"], floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE), "item",
			{"x": it["x"], "y": it["y"], "item": it["item"], "count": it["count"]}])
	_dirty_items.clear()
	b.removed_entities = _removed_items.keys()
	var touched: Array = _dirty_chunks.keys()
	for e: Array in b.items:
		touched.append(chunk_key(e[1], e[2], e[3]))
	touched.append_array(_removed_items.values())
	_removed_items.clear()
	for loc: String in levels.dirty:
		b.locations.append([loc, levels.kind(loc), levels.building(loc), levels.z(loc), {}])
	levels.dirty.clear()
	for loc: String in levels.removed:
		b.removed_locations.append([loc, _removed_location_chunks.get(loc, [])])
	levels.removed.clear()
	_removed_location_chunks.clear()
	b.prune_before = _prune_before
	_prune_before = -1
	_dirty_chunks.clear()
	_dirty_inventories.clear()
	var batch_id := writer.submit(b)
	for key: String in touched:
		_written_by[key] = batch_id
	_in_flight[batch_id] = _pending
	_pending = []


## Moves acknowledgements of committed batches to the outbox.
func poll() -> void:
	for id in writer.take_done():
		_last_committed = maxi(_last_committed, id)
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
		"use":
			return _use(actor, r)
		"climb":
			return _climb(actor, r)
		"drop":
			return _drop(actor, r)
		"pickup":
			return _pickup(actor, r)
	return {"ok": false, "reason": "unknown_type"}


## Whether a present character reaches a cell (actors not in the world, such as
## server tools, are not limited).
func _reaches(actor: String, location: String, x: int, y: int, reach: int) -> bool:
	if not present.has(actor):
		return true
	var p: Dictionary = present[actor]
	if p["location"] != location:
		return false
	var centre := Vector2(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2)
	return Vector2(p["pos"]).distance_to(centre) <= reach


func _use(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var x := int(r.get("x", 0))
	var y := int(r.get("y", 0))
	if not _reaches(actor, at[0], x, y, USE_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(at[0], at[1], at[2])
	var part := c.get_cell("structure", at[3], at[4])
	if part == "" or not content.get_def(part).get("openable", false):
		return {"ok": false, "reason": "nothing_to_use"}
	var props := c.get_props(at[3], at[4]).duplicate()
	var opening := not bool(props.get("open", false))
	if not opening and _someone_stands_on(at[0], x, y):
		return {"ok": false, "reason": "someone_there"}
	props["open"] = opening
	c.set_props(at[3], at[4], props)
	_changed(chunk_key(at[0], at[1], at[2]))
	return {"ok": true, "open": opening}


## Puts items from the inventory on the ground at the actor's feet (or at
## x, y in movement units for actors not in the world).
func _drop(actor: String, r: Dictionary) -> Dictionary:
	var item := String(r.get("item", ""))
	var n := int(r.get("count", 0))
	if content.kind_of(item) != "item" or n <= 0:
		return {"ok": false, "reason": "bad_request"}
	var where := {"location": String(r.get("location", "")), "x": int(r.get("x", 0)), "y": int(r.get("y", 0))}
	if present.has(actor):
		var p: Dictionary = present[actor]
		where = {"location": p["location"], "x": p["pos"].x, "y": p["pos"].y}
	if not inventory(actor).remove(item, n):
		return {"ok": false, "reason": "not_enough"}
	var id := Uuid.v4()
	_place_item(id, {"location": where["location"], "x": where["x"], "y": where["y"], "item": item, "count": n})
	_dirty_items[id] = true
	_touch_inventory(actor)
	return {"ok": true, "entity": id}


func _pickup(actor: String, r: Dictionary) -> Dictionary:
	var id := String(r.get("entity", ""))
	var it: Dictionary = items.get(id, {})
	if it.is_empty():
		return {"ok": false, "reason": "gone"}
	if present.has(actor):
		var p: Dictionary = present[actor]
		if p["location"] != it["location"] or Vector2(p["pos"]).distance_to(Vector2(it["x"], it["y"])) > PICKUP_REACH:
			return {"ok": false, "reason": "too_far"}
	inventory(actor).add(it["item"], it["count"])
	var key := _item_chunk_key(it)
	(_items_by_chunk[key] as Dictionary).erase(id)
	items.erase(id)
	_dirty_items.erase(id)
	_removed_items[id] = key
	_touch_inventory(actor)
	return {"ok": true, "item": it["item"], "count": it["count"]}


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
	revision_epoch += 1


func _touch_inventory(owner: String) -> void:
	_dirty_inventories[owner] = true
	_inventory_version[owner] = _inventory_version.get(owner, 0) + 1


## Raised whenever an inventory changes (clients get theirs only then).
func inventory_version(owner: String) -> int:
	return _inventory_version.get(owner, 0)


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
	var def := content.get_def(part)
	var role := String(def["role"])
	var at := _cell(r)
	var loc: String = at[0]
	var x := int(r.get("x", 0))
	var y := int(r.get("y", 0))
	if loc != SURFACE and levels.kind(loc) != Levels.BUILDING_LEVEL:
		return {"ok": false, "reason": "no_such_place"}
	if not _reaches(actor, loc, x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(loc, at[1], at[2])
	var on_level := loc != SURFACE
	if on_level and c.get_cell("ground", at[3], at[4]) == "":
		return {"ok": false, "reason": "no_floor"}  # the contour of the level below
	var layer := Terrain.layer_for_role(role)
	if c.get_cell(layer, at[3], at[4]) != "":
		return {"ok": false, "reason": "occupied"}
	var building := ""
	var upper := ""
	match role:
		"ceiling", "roof":
			if Terrain.is_covered(c, at[3], at[4]):
				return {"ok": false, "reason": "occupied"}
			if not on_level and bool(content.get_def(c.get_cell("ground", at[3], at[4])).get("solid", false)):
				return {"ok": false, "reason": "blocked"}
			if role == "ceiling":
				if levels.z(loc) + 1 > max_levels:
					return {"ok": false, "reason": "too_high"}  # a server setting (ADR-0007)
				building = levels.building(loc) if on_level else ""
		"stairs":
			if c.get_cell("ceiling", at[3], at[4]) == "":
				return {"ok": false, "reason": "no_opening_above"}
			if Terrain.is_solid(c, at[3], at[4], content, on_level):
				return {"ok": false, "reason": "blocked"}
		_:
			if Terrain.is_solid(c, at[3], at[4], content, on_level):
				return {"ok": false, "reason": "blocked"}  # water, a tree...
			if _someone_stands_on(loc, x, y):
				return {"ok": false, "reason": "someone_there"}
	var costs := content.structure_cost(part)
	var inv := inventory(actor)
	if not inv.has_all(costs):
		return {"ok": false, "reason": "materials"}
	for id: String in costs:
		inv.remove(id, int(costs[id]))
	_touch_inventory(actor)
	var props := {"owner": actor}
	var others: Array = []
	if role == "ceiling" and not on_level:
		# Ceilings joined side by side make one building; joining two merges them.
		var found := {}
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var b := _ceiling_building(loc, x + d.x, y + d.y)
			if b != "":
				found[b] = true
		var ids: Array = found.keys()
		ids.sort()
		building = ids[0] if not ids.is_empty() else Uuid.v4()
		others = ids.slice(1)
		props["building"] = building
	c.set_cell(layer, at[3], at[4], part)
	if layer == "structure":
		# Keep what the ceiling or roof above this cell knows about itself.
		var merged := props.duplicate()
		for k: String in ["ceiling", "roof"]:
			if c.get_props(at[3], at[4]).has(k):
				merged[k] = c.get_props(at[3], at[4])[k]
		c.set_props(at[3], at[4], merged)
	else:
		_set_layer_props(c, layer, at[3], at[4], props)
	_changed(chunk_key(loc, at[1], at[2]))
	if role == "stairs":
		_mark_stairs_down(loc, x, y, true)
	if role == "ceiling":
		var zl := levels.z(loc) + 1
		upper = levels.level(building, zl)
		if upper == "":
			upper = levels.create_level(building, zl)
		var uc := chunk(upper, at[1], at[2])
		uc.set_cell("ground", at[3], at[4], String(def["floor"]))
		_changed(chunk_key(upper, at[1], at[2]))
		for other: String in others:
			_merge_buildings(building, other)
	return {"ok": true, "level": upper} if upper != "" else {"ok": true}


## Props of a ceiling or roof are kept under the layer's name in the cell props,
## apart from those of the part standing on the cell.
func _set_layer_props(c: Chunk, layer: String, lx: int, ly: int, props: Dictionary) -> void:
	var all := c.get_props(lx, ly).duplicate()
	if props.is_empty():
		all.erase(layer)
	else:
		all[layer] = props
	c.set_props(lx, ly, all)


func _layer_props(c: Chunk, layer: String, lx: int, ly: int) -> Dictionary:
	var all := c.get_props(lx, ly)
	return all.get(layer, {}) if layer != "structure" else all


func _ceiling_building(location: String, x: int, y: int) -> String:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c := chunk(location, cx, cy)
	var lx := x - cx * Chunk.SIZE
	var ly := y - cy * Chunk.SIZE
	if c.get_cell("ceiling", lx, ly) == "":
		return ""
	return String(_layer_props(c, "ceiling", lx, ly).get("building", ""))


## Takes down what stands on the cell, else the roof, else the ceiling.
func _dismantle(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var loc: String = at[0]
	var x := int(r.get("x", 0))
	var y := int(r.get("y", 0))
	if not _reaches(actor, loc, x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(loc, at[1], at[2])
	var layer := ""
	for l: String in ["structure", "roof", "ceiling"]:
		if c.get_cell(l, at[3], at[4]) != "":
			layer = l
			break
	if layer == "":
		return {"ok": false, "reason": "empty"}
	var part := c.get_cell(layer, at[3], at[4])
	if _layer_props(c, layer, at[3], at[4]).get("owner", "") != actor:
		return {"ok": false, "reason": "not_owner"}
	if not content.has(part):
		# Its pack is gone: keep the part as it is rather than lose it unpaid.
		return {"ok": false, "reason": "unknown_part"}
	var upper := ""
	if layer == "ceiling":
		var building := levels.building(loc) if loc != SURFACE else String(_layer_props(c, "ceiling", at[3], at[4]).get("building", ""))
		upper = levels.level(building, levels.z(loc) + 1)
		if c.get_cell("structure", at[3], at[4]) != "" and content.get_def(c.get_cell("structure", at[3], at[4])).get("role") == "stairs":
			return {"ok": false, "reason": "stairs_below"}
		if upper != "" and _occupied(upper, x, y):
			return {"ok": false, "reason": "occupied_above"}  # ADR-0007: take those down first
	if layer == "structure" and _is_stairs(part):
		_mark_stairs_down(loc, x, y, false)
	c.set_cell(layer, at[3], at[4], "")
	if layer == "structure":
		var keep := c.get_props(at[3], at[4]).duplicate()
		for k: String in keep.keys():
			if k != "ceiling" and k != "roof":
				keep.erase(k)
		c.set_props(at[3], at[4], keep)
	else:
		_set_layer_props(c, layer, at[3], at[4], {})
	_changed(chunk_key(loc, at[1], at[2]))
	if upper != "":
		chunk(upper, at[1], at[2]).set_cell("ground", at[3], at[4], "")
		_changed(chunk_key(upper, at[1], at[2]))
	var costs := content.structure_cost(part)
	var inv := inventory(actor)
	for id: String in costs:
		inv.add(id, int(costs[id]))
	_touch_inventory(actor)
	return {"ok": true, "part": part}


## Anything on a cell of a level: a part, a ceiling, a roof, a thing, a person.
func _occupied(location: String, x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c := chunk(location, cx, cy)
	for l: String in ["structure", "ceiling", "roof"]:
		if c.get_cell(l, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE) != "":
			return true
	for id: String in items_in_chunk(location, cx, cy):
		if Movement.cell_of(Vector2i(items[id]["x"], items[id]["y"])) == Vector2i(x, y):
			return true
	return _someone_stands_on(location, x, y)


## Up or down a staircase next to the character (ADR-0007): up from a cell
## with stairs to the same cell of the level above; down when the cell below
## has stairs.
func _climb(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var p: Dictionary = present[actor]
	var loc: String = p["location"]
	var x := int(r.get("x", 0))
	var y := int(r.get("y", 0))
	if String(r.get("location", "")) != loc or not _reaches(actor, loc, x, y, USE_REACH):
		return {"ok": false, "reason": "too_far"}
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var lx := x - cx * Chunk.SIZE
	var ly := y - cy * Chunk.SIZE
	var here := chunk(loc, cx, cy)
	var dest := ""
	# "dir": "up" or "down" where stairs stand over stairs and both ways lead
	# on from one cell; without it, up first (older clients).
	var dir := String(r.get("dir", ""))
	if dir != "down" and _is_stairs(here.get_cell("structure", lx, ly)):
		var building := levels.building(loc) if loc != SURFACE else String(_layer_props(here, "ceiling", lx, ly).get("building", ""))
		dest = levels.level(building, levels.z(loc) + 1)
	if dest == "" and dir != "up" and loc != SURFACE:
		var below := levels.level(levels.building(loc), levels.z(loc) - 1)
		if below != "" and _is_stairs(chunk(below, cx, cy).get_cell("structure", lx, ly)):
			dest = below
	if dest == "":
		return {"ok": false, "reason": "no_stairs"}
	p["location"] = dest
	p["pos"] = Vector2i(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2)
	_dirty_world_characters[actor] = true
	relocated[actor] = true
	return {"ok": true, "location": dest, "z": levels.z(dest)}


## Marks (or unmarks) the cell above a staircase as the way down, so players
## upstairs can see where to go down.
func _mark_stairs_down(location: String, x: int, y: int, on: bool) -> void:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var here := chunk(location, cx, cy)
	var lx := x - cx * Chunk.SIZE
	var ly := y - cy * Chunk.SIZE
	var building := levels.building(location) if location != SURFACE else String(_layer_props(here, "ceiling", lx, ly).get("building", ""))
	var upper := levels.level(building, levels.z(location) + 1)
	if upper == "":
		return
	var uc := chunk(upper, cx, cy)
	var props := uc.get_props(lx, ly).duplicate()
	if on:
		props["stairs_down"] = true
	else:
		props.erase("stairs_down")
	uc.set_props(lx, ly, props)
	_changed(chunk_key(upper, cx, cy))


func _is_stairs(part: String) -> bool:
	return part != "" and content.get_def(part).get("role") == "stairs"


## Joins building `absorbed` into `survivor`: surface ceilings change owner,
## levels only the absorbed one had change owner, levels both had move their
## cells, things and people into the survivor's location.
func _merge_buildings(survivor: String, absorbed: String) -> void:
	var first := levels.level(absorbed, 1)
	if first != "":
		# The first level's floor is exactly the surface ceilings of the building.
		for xy: Vector2i in _cells_with_ground(first):
			var cx := floori(float(xy.x) / Chunk.SIZE)
			var cy := floori(float(xy.y) / Chunk.SIZE)
			var c := chunk(SURFACE, cx, cy)
			var lx := xy.x - cx * Chunk.SIZE
			var ly := xy.y - cy * Chunk.SIZE
			var props := _layer_props(c, "ceiling", lx, ly).duplicate()
			if props.get("building", "") == absorbed:
				props["building"] = survivor
				_set_layer_props(c, "ceiling", lx, ly, props)
				_changed(chunk_key(SURFACE, cx, cy))
	for pair: Array in levels.absorb(survivor, absorbed):
		_move_location(pair[0], pair[1])


func _cells_with_ground(location: String) -> Array:
	var out: Array = []
	for key: String in _location_chunk_keys(location):
		var p := key.split("|")
		var cx := int(p[1])
		var cy := int(p[2])
		var c := chunk(location, cx, cy)
		for i in Chunk.CELLS:
			if c.get_cell("ground", i % Chunk.SIZE, i / Chunk.SIZE) != "":
				out.append(Vector2i(cx * Chunk.SIZE + i % Chunk.SIZE, cy * Chunk.SIZE + i / Chunk.SIZE))
	return out


## Chunk keys of a location, in memory or on disk.
func _location_chunk_keys(location: String) -> Array:
	var keys := {}
	for row: Dictionary in store.chunks_of(location):
		keys[chunk_key(location, int(row["cx"]), int(row["cy"]))] = true
	for key: String in _chunks:
		if key.begins_with(location + "|"):
			keys[key] = true
	return keys.keys()


func _move_location(from: String, to: String) -> void:
	var gone: Array = []
	for key: String in _location_chunk_keys(from):
		var p := key.split("|")
		var cx := int(p[1])
		var cy := int(p[2])
		var src := chunk(from, cx, cy)
		var dst := chunk(to, cx, cy)
		for i in Chunk.CELLS:
			var lx := i % Chunk.SIZE
			var ly := i / Chunk.SIZE
			for layer: String in src.layers:
				var id := src.get_cell(layer, lx, ly)
				if id != "":
					dst.set_cell(layer, lx, ly, id)
			if not src.get_props(lx, ly).is_empty():
				dst.set_props(lx, ly, src.get_props(lx, ly))
		_changed(chunk_key(to, cx, cy))
		for id: String in items_in_chunk(from, cx, cy):
			var it: Dictionary = items[id]
			(_items_by_chunk[key] as Dictionary).erase(id)
			it["location"] = to
			_place_item(id, it)
			_dirty_items[id] = true
		_chunks.erase(key)
		_encoded.erase(key)
		_dirty_chunks.erase(key)
		gone.append([cx, cy])
	for id: String in present:
		if present[id]["location"] == from:
			present[id]["location"] = to
			_dirty_world_characters[id] = true
			relocated[id] = true
	_removed_location_chunks[from] = gone
	levels.forget(from)


func _transfer(actor: String, r: Dictionary) -> Dictionary:
	var to := String(r.get("to", ""))
	var item := String(r.get("item", ""))
	var n := int(r.get("count", 0))
	if to == "" or to == actor or n <= 0:
		return {"ok": false, "reason": "bad_request"}
	if not inventory(actor).remove(item, n):
		return {"ok": false, "reason": "not_enough"}
	inventory(to).add(item, n)
	_touch_inventory(actor)
	_touch_inventory(to)
	return {"ok": true}
