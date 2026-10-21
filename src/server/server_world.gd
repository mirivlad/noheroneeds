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
## The geology below (ADR-0017); null if the content has none.
var underground: UndergroundGenerator
## The deepest depth one may go (a server rule; 0: no limit).
var max_depth := 0
var loader := ChunkLoader.new()
var world_seed := 0
## The seed of its weather (ADR-0033): told to clients, unlike the world's.
var weather_seed := 0
## Chunks the simulation had to load or generate itself because the loader
## had not brought them yet (each one costs tick time).
var sync_loads := 0
## Requests are remembered at least this many ticks for idempotency.
var request_memory_ticks := 20 * 60 * 30
var tick := 0
## World time: game ms since the world began (ADR-0014), saved with the state.
var world_time := Daylight.START_MS
## Game ms the clock moves a tick: the day's length is a world rule.
var time_rate := Daylight.rate_for(Daylight.DEFAULT_DAY_MINUTES)
## The time is written every this many ticks (and on every full sync).
const TIME_SAVE_TICKS := 100
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
## Bumped whenever an item appears, goes or moves (views of items cache on it).
var items_rev := 0
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
	# Things on the ground lie until the server restarts (ADR-0016): a world
	# starts with none.
	s.delete_entities_of_kind("item")
	var world := ServerWorld.new(s, registry, w)
	world.creatures = CreatureSim.new(world)
	world.combat = Combat.new(world)
	world.needs = Needs.new(world)
	world.chronicles = Chronicles.new(world)
	world.world_seed = int(s.read_meta("seed"))
	world.weather_seed = absi(hash([world.world_seed, "weather"]))
	var saved_time := s.read_meta("time")
	if saved_time.is_valid_int():
		world.world_time = int(saved_time)
	world.levels.load_rows(s.all_locations())
	var g := SurfaceGenerator.new(world.world_seed, registry)
	world.generator = g if g.can_generate() else null
	var ug := UndergroundGenerator.new(world.world_seed, registry)
	world.underground = ug if ug.can_generate() else null
	var spawn_way := world._spawn_way()
	var lg := SurfaceGenerator.new(world.world_seed, registry) if world.generator else null
	var lug := UndergroundGenerator.new(world.world_seed, registry) if world.underground else null
	for gen: UndergroundGenerator in [world.underground, lug]:
		if gen and spawn_way != NO_CELL:
			gen.extra_ways["-1|%d|%d" % [spawn_way.x, spawn_way.y]] = true
	if world.generator:
		world.generator.underground = world.underground
	if lg:
		lg.underground = lug
	if not world.loader.start(db_path, lg, lug):
		w.stop()
		s.close()
		return null
	world._open_spawn_way(spawn_way)
	return world


## Every world has a way into the underground near its spawn point (ADR-0017),
## chosen once from the seed and remembered; worlds made before caves get it
## too. NO_CELL without an underground.
func _spawn_way() -> Vector2i:
	if underground == null or generator == null:
		return NO_CELL
	var kept := store.read_meta("spawn_way")
	if kept != "":
		var p := kept.split(",")
		return Vector2i(int(p[0]), int(p[1]))
	var h := absi(hash([world_seed, "spawn_way"]))
	var at := Vector2i((14 + h % 9) * (1 if h % 2 == 0 else -1), (12 + (h / 9) % 9) * (1 if (h / 2) % 2 == 0 else -1))
	at += spawn_position / Movement.UNIT
	# Away from its chunk's edges, so its hollow below stays in one chunk.
	at.x = floori(float(at.x) / Chunk.SIZE) * Chunk.SIZE + clampi(posmod(at.x, Chunk.SIZE), 5, Chunk.SIZE - 6)
	at.y = floori(float(at.y) / Chunk.SIZE) * Chunk.SIZE + clampi(posmod(at.y, Chunk.SIZE), 5, Chunk.SIZE - 6)
	return at


## The spawn way, if its surface chunk was made before caves were: the mouth
## is put there now (once; remembered in the world's meta).
func _open_spawn_way(at: Vector2i) -> void:
	if at == NO_CELL or store.read_meta("spawn_way") != "":
		return
	var cx := floori(float(at.x) / Chunk.SIZE)
	var cy := floori(float(at.y) / Chunk.SIZE)
	if not store.get_chunk(SURFACE, cx, cy).is_empty():
		var c := chunk(SURFACE, cx, cy)
		generator.place_mouth(c, at.x - cx * Chunk.SIZE, at.y - cy * Chunk.SIZE, underground.way_down_surface)
		_changed(chunk_key(SURFACE, cx, cy))
	note_fact("spawn_way", "%d,%d" % [at.x, at.y])


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
	creatures.detach()  # they hold each other: let both go
	combat.world = null
	needs.world = null
	chronicles.world = null


## Stops without committing what is not yet handed to the writer (tests of crashes).
func abandon() -> void:
	if _closed:
		return
	_closed = true
	loader.stop()
	writer.stop()
	store.close()
	creatures.detach()
	combat.world = null
	needs.world = null
	chronicles.world = null


# --- request fields (input from the network: any type may come) ----------------

## A request's text field, or `default` if it is missing or not text.
static func rs(r: Dictionary, key: String, default := "") -> String:
	var v: Variant = r.get(key, default)
	return v if typeof(v) == TYPE_STRING else default


## A request's whole-number field (a float is cut), or `default`.
static func ri(r: Dictionary, key: String, default := 0) -> int:
	var v: Variant = r.get(key, default)
	return int(v) if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT else default


## A request's yes/no field, or `default`.
static func rb(r: Dictionary, key: String, default := false) -> bool:
	var v: Variant = r.get(key, default)
	return v if typeof(v) == TYPE_BOOL else default


static func chunk_key(location: String, cx: int, cy: int) -> String:
	return "%s|%d|%d" % [location, cx, cy]


## A chunk, loaded or generated now if the loader has not brought it yet.
## The chunk last asked for: most asks come in runs for one chunk (a
## creature's steps and sight, light around a cell), and building its key is
## the dearest part. Forgotten when chunks leave memory.
var _last_chunk: Chunk = null
## Bumped when chunks leave memory (whoever keeps a Chunk asks for it again).
var chunks_epoch := 0
var _last_chunk_at := Vector2i(1 << 30, 0)
var _last_chunk_location := ""


func chunk(location: String, cx: int, cy: int) -> Chunk:
	if _last_chunk != null and cx == _last_chunk_at.x and cy == _last_chunk_at.y and location == _last_chunk_location:
		return _last_chunk
	var c := _chunk(location, cx, cy)
	_last_chunk = c
	_last_chunk_at = Vector2i(cx, cy)
	_last_chunk_location = location
	return c


func _chunk(location: String, cx: int, cy: int) -> Chunk:
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
		elif Levels.is_depth(location) and underground:
			c = underground.generate(levels.z(location), cx, cy)
			_dirty_chunks[key] = true
		else:
			c = Chunk.new()
		_chunks[key] = c
		var rows := store.entities_in_chunk(location, cx, cy)
		_take_items(location, rows)
		creatures.take_rows(location, rows)
		creatures.on_chunk_ready(location, cx, cy, c)
		_settle_stairs(location, cx, cy, c)
		chronicles.lie_lost(location, cx, cy)  # a thing lost in a cave lies there again (ADR-0042)
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
		var it := {"location": location, "x": int(d["x"]), "y": int(d["y"]),
			"item": String(d["item"]), "count": int(d["count"])}
		if d.has("for"):
			it["for"] = String(d["for"])
			it["until"] = int(d.get("until", 0))
		_place_item(row["id"], it)


func _place_item(id: String, it: Dictionary) -> void:
	items[id] = it
	items_rev += 1
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
	for id: String in _dirty_entities:  # creatures and other state not yet handed to the writer
		var e: Array = _entities[id]  # [location, cell x, cell y, ...]
		dirty_item_chunks[chunk_key(e[0], floori(float(e[1]) / Chunk.SIZE), floori(float(e[2]) / Chunk.SIZE))] = true
	var gone := 0
	for key: String in _chunks.keys():
		if tick - int(_needed.get(key, -idle_ticks - 1)) <= idle_ticks:
			continue
		if _dirty_chunks.has(key) or dirty_item_chunks.has(key) or int(_written_by.get(key, 0)) > _last_committed:
			continue
		if not creatures.ready_to_unload(key):
			continue  # its creatures are being saved: next time
		creatures.drop_chunk(key)
		_lights_by_chunk.erase(key)
		for id: String in (_items_by_chunk.get(key, {}) as Dictionary):
			items.erase(id)
			items_rev += 1
		_items_by_chunk.erase(key)
		_chunks.erase(key)
		_last_chunk = null
		chunks_epoch += 1
		_encoded.erase(key)
		_map_tiles.erase(key)
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
		creatures.take_rows(r[0], r[5])
		creatures.on_chunk_ready(r[0], r[1], r[2], r[3])
		if not (r[6] as PackedByteArray).is_empty():
			_encoded[key] = [_chunk_rev.get(key, 0), r[6]]
		if r[4]:
			_dirty_chunks[key] = true
		_settle_stairs(r[0], r[1], r[2], r[3])  # after its encoding is kept: a change makes it stale


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
	# Only the owner's edited appearance is imported on re-entry. World-earned
	# possessions and progress remain authoritative in this world's database.
	var appearance: Dictionary = c.to_data()["appearance"]
	if data["appearance"] != appearance or data["name"] != c.name:
		data["appearance"] = appearance
		data["name"] = c.name
		_dirty_characters[id] = true
	if not data.get("outfit_given", false) and (not starter_outfit.is_empty() or not (data.get("equipment", {}) as Dictionary).is_empty()):
		if (data.get("equipment", {}) as Dictionary).is_empty() and not starter_outfit.is_empty():
			data["equipment"] = starter_outfit.duplicate()
		data["outfit_given"] = true
		_dirty_characters[id] = true
	present[id] = {"location": String(place["location"]), "pos": Vector2i(int(place["x"]), int(place["y"])),
		"name": data["name"], "appearance": shown_look(data)}
	present[id]["health"] = int(place.get("health", combat.max_health_of(id)))
	present[id]["deaths"] = int(place.get("deaths", 0))
	present[id]["satiety"] = float(place.get("satiety", Needs.FULL))
	present[id]["warmth"] = float(place.get("warmth", Needs.FULL))
	present[id]["energy"] = float(place.get("energy", Needs.FULL))
	# Its floor may have gone while it was away (the author, 16.10.2026: a
	# floor is not kept for those away — a ceiling broken, stairs opened, old
	# stairs brought to today's way): it is put on the floor below, down to
	# the ground, unhurt.
	var loc := String(place["location"])
	var cell := Movement.cell_of(present[id]["pos"])
	if levels.kind(loc) == Levels.BUILDING_LEVEL and _part_at(loc, cell.x, cell.y, "ground") == "":
		present[id]["location"] = combat.location_under(cell, levels.z(loc) - 0.5)
		present[id]["pos"] = cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
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
		_left_places[id] = {"location": p["location"], "x": p["pos"].x, "y": p["pos"].y,
			"health": p.get("health", 0), "deaths": p.get("deaths", 0), "satiety": p.get("satiety", Needs.FULL), "warmth": p.get("warmth", Needs.FULL), "energy": p.get("energy", Needs.FULL)}
		_dirty_world_characters[id] = true
		flush_state()  # its last position goes out with this batch
		present.erase(id)


# --- maps (ADR-0020) ----------------------------------------------------------

## Chunks each character has seen, by location: char -> {location -> {Vector2i: true}}.
## Kept in the world's meta ("explored|char|location", "explored|char").
var _explored := {}
var _explored_dirty := {}
## location|cx|cy -> [chunk revision, encoded MapTile]
var _map_tiles := {}


## {location: {Vector2i(cx, cy): true}} a character has seen (read once).
func explored(character: String) -> Dictionary:
	if not _explored.has(character):
		var all := {}
		var locs := store.read_meta("explored|" + character)
		for loc: String in (locs.split(",", false) if locs != "" else PackedStringArray()):
			var cells := {}
			var pairs := Marshalls.base64_to_raw(store.read_meta("explored|%s|%s" % [character, loc])).to_int32_array()
			for i in range(0, pairs.size() - 1, 2):
				cells[Vector2i(pairs[i], pairs[i + 1])] = true
			all[loc] = cells
		_explored[character] = all
	return _explored[character]


## A character sees a chunk: true if it is new to it.
func explore(character: String, location: String, cx: int, cy: int) -> bool:
	var all := explored(character)
	var cells: Dictionary = all.get_or_add(location, {})
	var at := Vector2i(cx, cy)
	if cells.has(at):
		return false
	cells[at] = true
	_explored_dirty[character + "|" + location] = true
	return true


## Hands what characters saw since last time to the next batch (as meta).
func _flush_explored() -> void:
	for key: String in _explored_dirty:
		var p := key.split("|")
		var all: Dictionary = _explored.get(p[0], {})
		var pairs := PackedInt32Array()
		for at: Vector2i in all.get(p[1], {}):
			pairs.append(at.x)
			pairs.append(at.y)
		note_fact("explored|%s|%s" % [p[0], p[1]], Marshalls.raw_to_base64(pairs.to_byte_array()))
		note_fact("explored|" + p[0], ",".join(PackedStringArray(all.keys())))
	_explored_dirty.clear()


## A chunk as the map shows it, encoded once per revision. From memory if it
## is there, else from the store without loading it into the world (no
## creatures woken, nothing generated); empty if it was never made.
func map_tile(location: String, cx: int, cy: int) -> PackedByteArray:
	var key := chunk_key(location, cx, cy)
	var rev: int = _chunk_rev.get(key, 0)
	var cached: Array = _map_tiles.get(key, [])
	if not cached.is_empty() and cached[0] == rev:
		return cached[1]
	var c: Chunk = _chunks.get(key)
	if c == null:
		var data := store.get_chunk(location, cx, cy)
		if data.is_empty():
			return PackedByteArray()
		c = ChunkCodec.decode(data)
		if c == null:
			return PackedByteArray()
	# Shut-in ore shows as rock on the map too; chunks not in memory count as
	# solid round it (a map is no way to find veins).
	var bytes := MapTile.encode(MapTile.of(shown_chunk(location, cx, cy, c, func(x: int, y: int) -> bool:
		var k := chunk_key(location, floori(float(x) / Chunk.SIZE), floori(float(y) / Chunk.SIZE))
		return not _chunks.has(k) or is_solid(location, x, y))))
	if _map_tiles.size() > 4096:
		_map_tiles.clear()  # a cache, not a store
	_map_tiles[key] = [rev, bytes]
	return bytes


## A present character's world state changed (health...): saved soon.
func note_character(id: String) -> void:
	_dirty_world_characters[id] = true


## Puts `n` of `item` on the ground at `pos` (movement units): what a
## creature leaves, what a character drops when it dies, a fallen arrow.
## kept_for: a character only who may take it until tick `until` (what a dead
## one dropped, ADR-0016).
func place_item(location: String, pos: Vector2i, item: String, n: int, kept_for := "", until := 0) -> String:
	var id := Uuid.v4()
	var it := {"location": location, "x": pos.x, "y": pos.y, "item": item, "count": n}
	if kept_for != "":
		it["for"] = kept_for
		it["until"] = until
	_place_item(id, it)
	_dirty_items[id] = true
	return id


## Whether `who` may take a thing lying there: anyone, unless it is a dead
## one's and still kept for them (ADR-0016).
func may_take(who: String, it: Dictionary) -> bool:
	return String(it.get("for", "")) in ["", who] or tick >= int(it.get("until", 0))


## Takes a thing off the ground: into an inventory, or (null) into a
## looter's stomach, which keeps it itself. Returns what it was.
func take_item(id: String, into: Inventory) -> Dictionary:
	var it: Dictionary = items[id]
	if into:
		into.add(it["item"], it["count"])
	var key := _item_chunk_key(it)
	(_items_by_chunk[key] as Dictionary).erase(id)
	items.erase(id)
	items_rev += 1
	_dirty_items.erase(id)
	_removed_items[id] = key
	return it


## An entity leaves the world for good (a creature that died).
func remove_entity(id: String, location: String, cell: Vector2i) -> void:
	_entities.erase(id)
	_dirty_entities.erase(id)
	_removed_items[id] = chunk_key(location, cell.x >> 5, cell.y >> 5)


func touch_inventory(owner: String) -> void:
	_touch_inventory(owner)


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


## The chunk as clients receive it, encoded once per revision: what is
## shut in rock is told as the rock it looks like (shown_chunk).
func encoded_chunk(location: String, cx: int, cy: int) -> PackedByteArray:
	var key := chunk_key(location, cx, cy)
	var rev: int = _chunk_rev.get(key, 0)
	var cached: Array = _encoded.get(key, [])
	if cached.is_empty() or cached[0] != rev:
		cached = [rev, ChunkCodec.encode(shown_chunk(location, cx, cy, chunk(location, cx, cy),
			func(x: int, y: int) -> bool: return is_solid(location, x, y)))]
		_encoded[key] = cached
	return cached[1]


## A chunk as clients may know it: a part with "hidden_as" (ore in the rock)
## shut in on all four sides by solid cells (`solid`, world cells) is told as
## what it looks like there — nobody sees a vein before it is dug open, not on
## the screen, not on the map, not in what is sent.
func shown_chunk(location: String, cx: int, cy: int, c: Chunk, solid: Callable) -> Chunk:
	var hidden := {}
	for id: String in c.layer_ids("structure"):
		if id != "" and content.get_def(id).has("hidden_as"):
			hidden[id] = String(content.get_def(id)["hidden_as"])
	if hidden.is_empty():
		return c
	var out := c.snapshot()
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			var id := c.get_cell("structure", lx, ly)
			if not hidden.has(id):
				continue
			var x := cx * Chunk.SIZE + lx
			var y := cy * Chunk.SIZE + ly
			if solid.call(x, y - 1) and solid.call(x + 1, y) and solid.call(x, y + 1) and solid.call(x - 1, y):
				out.set_cell("structure", lx, ly, hidden[id])
	return out


func _known_character(id: String) -> Dictionary:
	if _characters.has(id):
		return _characters[id]
	var row := store.get_character(id)
	if row.is_empty():
		return {}
	var known := {"owner": String(row["owner"]), "data": Cbor.decode(row["data"]).value}
	_characters[id] = known
	return known


## Gives items outside of any request (world setup, tests): past the bag's
## cells too.
func grant(owner: String, content_id: String, n: int) -> void:
	inventory(owner).add(content_id, n)
	_touch_inventory(owner)


## Whether an inventory is a character's bag, of Bag.SIZE cells (ADR-0041);
## chests count their own, a dweller's goods and a looter's stomach none.
func _is_bag(owner: String) -> bool:
	return not owner.contains("|") and (present.has(owner) or not _known_character(owner).is_empty())


## How many more of an item an inventory takes.
func room_for(owner: String, item: String) -> int:
	if not _is_bag(owner):
		return 1 << 30
	return Bag.room_for(content, inventory(owner).stacks, item)


## Gives a character what was got (dug, made, refunded): into the bag as far
## as it goes, the rest on the ground at its feet (ADR-0041). Returns how
## many went into the bag. One not in the world gets all of it.
func give(owner: String, item: String, n: int) -> int:
	var fits := n if not present.has(owner) else mini(n, room_for(owner, item))
	if fits > 0:
		inventory(owner).add(item, fits)
	if n > fits:
		place_item(String(present[owner]["location"]), present[owner]["pos"], item, n - fits)
	_touch_inventory(owner)
	return fits


## Frequently changing state of an entity (position, needs...). CBOR-compatible.
func set_entity(id: String, location: String, x: int, y: int, kind: String, data: Dictionary) -> void:
	_entities[id] = [location, x, y, kind, data]
	_dirty_entities[id] = true


func handle(actor: String, request: Dictionary) -> void:
	var rid := rs(request, "request_id")
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
		var data := {"x": it["x"], "y": it["y"], "item": it["item"], "count": it["count"]}
		if it.has("for"):
			data["for"] = it["for"]
			data["until"] = it["until"]
		b.items.append([id, it["location"], floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE), "item", data])
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
	creatures.save_all()
	commit_async(true)
	flush_state()
	writer.wait_idle()
	poll()
	return writer.last_error() == ""


## The length of a day in real minutes (a world rule); the clock keeps the
## hour it shows, only its pace changes.
func set_day_minutes(minutes: float) -> void:
	time_rate = Daylight.rate_for(minutes)


## One tick of the world's clock.
func advance_time() -> void:
	world_time += time_rate
	_time_dirty = true


var _time_dirty := false
## Living creatures (ADR-0018).
var creatures: CreatureSim
## Health, blows, arrows, death (ADR-0019).
var combat: Combat
## Satiety and what else a character needs (ADR-0032).
var needs: Needs
## Villages' chronicles and their dwellers' requests (ADR-0042).
var chronicles: Chronicles
## World facts to write with the next state batch (set_meta).
var _pending_meta := {}
## Light sources by chunk, worked out when first asked, forgotten on change.
var _lights_by_chunk := {}


## A world fact written with the next state batch (meta).
func note_fact(key: String, value: String) -> void:
	_pending_meta[key] = value


## A world fact as it is now: noted and not yet written, or as kept.
func fact(key: String) -> String:
	if _pending_meta.has(key):
		return String(_pending_meta[key])
	return store.read_meta(key) if store else ""


func mark_chunk_dirty(location: String, cx: int, cy: int) -> void:
	_dirty_chunks[chunk_key(location, cx, cy)] = true


## Whether players needed a chunk within the last `ticks` ticks (they are near).
func needed_within(key: String, ticks: int) -> bool:
	return _needed.has(key) and tick - int(_needed[key]) <= ticks


## Whether a cell blocks sight (ADR-0018): a part that is not see-through
## (walls; a door unless open), or a solid plant (a tree, a bush).
## "Is this cell solid?" for one location, asked many times a tick by walking
## creatures: it keeps the chunk it last read (ServerWorld.solid_in).
class SolidIn:
	var world: ServerWorld
	var location := ""
	var empty_ground_blocks := false
	## Chunks not in memory count as solid, and are not loaded for the asking
	## (creatures: one wandering to the edge of what is loaded must not have
	## the world load, or make, a chunk in the middle of a tick).
	var loaded_only := false
	var _at := Vector2i(1 << 30, 0)
	var _epoch := -1
	var _chunk: Chunk = null

	func solid(x: int, y: int) -> bool:
		var here := Vector2i(x >> 5, y >> 5)  # Chunk.SIZE is 32
		if here != _at or _epoch != world.chunks_epoch:
			_at = here
			_epoch = world.chunks_epoch
			_chunk = world._chunks.get(ServerWorld.chunk_key(location, here.x, here.y)) if loaded_only \
				else world.chunk(location, here.x, here.y)
		if _chunk == null:
			_at = Vector2i(1 << 30, 0)  # asked again next time: it may have come by then
			return true
		return Terrain.is_solid(_chunk, x & 31, y & 31, world.content, empty_ground_blocks)


## Answers whether a cell of `location` is solid (its .solid(x, y)), as
## is_solid, but cheaper for runs of questions about nearby cells. Keep the
## object while using its method as a Callable.
func solid_in(location: String, loaded_only := false) -> SolidIn:
	var q := SolidIn.new()
	q.world = self
	q.location = location
	q.empty_ground_blocks = location != SURFACE
	q.loaded_only = loaded_only
	return q


## Whether a location has daylight at all (ADR-0014, ADR-0017): the surface
## and the levels of buildings; not underground.
func has_daylight(location: String) -> bool:
	return location == SURFACE or levels.kind(location) == Levels.BUILDING_LEVEL


func is_opaque(location: String, x: int, y: int) -> bool:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return Terrain.is_opaque(chunk(location, cx, cy), x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, content)


## How light a cell is now, 0..1 (ADR-0014): the hour's daylight, less under a
## roof or a ceiling, and the light sources around it. What creatures can
## see will ask this; it is computed when asked, not every tick.
func light_at(location: String, cell: Vector2i) -> float:
	var cx := floori(float(cell.x) / Chunk.SIZE)
	var cy := floori(float(cell.y) / Chunk.SIZE)
	var indoors := Terrain.is_covered(chunk(location, cx, cy), cell.x - cx * Chunk.SIZE, cell.y - cy * Chunk.SIZE)
	return Lighting.level(world_time, indoors, cell, light_sources(location, cell, Lighting.MAX_RADIUS),
		has_daylight(location))


## Light sources within `radius` cells of a cell: [cell, intensity, radius].
## Each chunk's sources are found once and kept until the chunk changes.
func light_sources(location: String, around: Vector2i, radius: int) -> Array:
	var out := []
	for cy in range(floori(float(around.y - radius) / Chunk.SIZE), floori(float(around.y + radius) / Chunk.SIZE) + 1):
		for cx in range(floori(float(around.x - radius) / Chunk.SIZE), floori(float(around.x + radius) / Chunk.SIZE) + 1):
			for src: Array in _chunk_lights(location, cx, cy):
				var at: Vector2i = src[0]
				if absi(at.x - around.x) <= radius and absi(at.y - around.y) <= radius:
					out.append(src)
	return out


func _chunk_lights(location: String, cx: int, cy: int) -> Array:
	var key := chunk_key(location, cx, cy)
	if _lights_by_chunk.has(key):
		return _lights_by_chunk[key]
	var out := []
	var c := chunk(location, cx, cy)
	var cells: PackedInt32Array = c.layers.get("structure", PackedInt32Array())
	if not cells.is_empty():
		var lit := {}
		for i in c.palette.size():
			var l: Dictionary = content.get_def(c.palette[i]).get("light", {}) if c.palette[i] != "" else {}
			if not l.is_empty():
				lit[i] = l
		if not lit.is_empty():
			for i in Chunk.CELLS:
				if lit.has(cells[i]):
					var l: Dictionary = lit[cells[i]]
					out.append([Vector2i(cx * Chunk.SIZE + i % Chunk.SIZE, cy * Chunk.SIZE + i / Chunk.SIZE),
						float(l["intensity"]), float(l["radius"])])
	_lights_by_chunk[key] = out
	return out


## Hands changed entity state to the writer (encoded there). At most `limit`
## entities per call (-1: all), so the server can spread the work over ticks.
## The world time goes with it now and then, and always on a full flush.
func flush_state(limit := -1) -> void:
	if not _explored_dirty.is_empty() and (limit < 0 or tick % TIME_SAVE_TICKS == 0):
		_flush_explored()
	var with_time := _time_dirty and (limit < 0 or tick % TIME_SAVE_TICKS == 0)
	if _dirty_entities.is_empty() and _dirty_world_characters.is_empty() and not with_time and _pending_meta.is_empty():
		return
	var b := StoreWriter.Batch.new()
	if with_time:
		b.meta.append(["time", str(world_time)])
		_time_dirty = false
	for k: String in _pending_meta:
		b.meta.append([k, _pending_meta[k]])
	_pending_meta.clear()
	for id: String in _dirty_world_characters.keys():
		if present.has(id):
			var p: Dictionary = present[id]
			b.world_characters.append([id, {"location": p["location"], "x": p["pos"].x, "y": p["pos"].y,
				"health": int(p.get("health", 0)), "deaths": int(p.get("deaths", 0)), "satiety": float(p.get("satiety", Needs.FULL)), "warmth": float(p.get("warmth", Needs.FULL)), "energy": float(p.get("energy", Needs.FULL))}])
		_dirty_world_characters.erase(id)
	for id: String in _dirty_entities.keys():
		if limit >= 0 and b.entities.size() >= limit:
			break
		var e: Array = _entities[id]
		var cx := floori(float(e[1]) / Chunk.SIZE)
		var cy := floori(float(e[2]) / Chunk.SIZE)
		b.entities.append([id, e[0], cx, cy, e[3], (e[4] as Dictionary).duplicate(true)])
		_dirty_entities.erase(id)
	var batch_id := writer.submit(b)
	for e: Array in b.entities:  # their chunks may unload only once this is on disk
		_written_by[chunk_key(e[1], e[2], e[3])] = batch_id


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
	match rs(r, "type"):
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
		"attack":
			return combat.attack(actor, r)
		"jump":
			return _jump(actor, r)
		"gather":
			return _gather(actor, r)
		"look_in":
			return _look_in(actor, r)
		"hold":
			return _hold(actor, r)
		"equip":
			return _equip(actor, r, true)
		"unequip":
			return _equip(actor, r, false)
		"strike_part":
			return _strike_part(actor, r)
		"repair":
			return _repair(actor, r)
		"store":
			return _move_items(actor, r, true)
		"take":
			return _move_items(actor, r, false)
		"lock":
			return _lock(actor, r)
		"befriend":
			return _befriend(actor, r, true)
		"unfriend":
			return _befriend(actor, r, false)
		"craft":
			return _craft(actor, r)
		"till":
			return _till(actor, r)
		"sow":
			return _sow(actor, r)
		"eat":
			return _eat(actor, r)
		"feed":
			return _feed(actor, r)
		"sleep":
			return _sleep(actor, r)
		"fill":
			return _fill(actor, r)
		"talk", "promise", "report":
			return _talk(actor, r, rs(r, "type"))
		"journal":
			return chronicles.journal(actor) if present.has(actor) else {"ok": false, "reason": "not_here"}
		"trade_look":
			return _trade_look(actor, r)
		"trade":
			return _trade(actor, r)
		"pour":
			return _pour(actor, r)
		"wake":
			wake(actor)
			return {"ok": true}
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
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
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
	if opening and bool(props.get("locked", false)):
		var why := _unlocks(actor, String(props.get("owner", "")), _lock_key(at[0], x, y), r)
		if why != "":
			return {"ok": false, "reason": why}
	props["open"] = opening
	c.set_props(at[3], at[4], props)
	_changed(chunk_key(at[0], at[1], at[2]))
	creatures.noise(at[0], Vector2i(x, y))
	return {"ok": true, "open": opening}


# --- locks and friends (ADR-0016) ---------------------------------------------------

## Wrong codes one may try before waiting, and how long one waits (ticks).
const PIN_TRIES := 3
const PIN_WAIT_TICKS := 30 * Movement.TICK_RATE
## Lock key -> {"pin": "1234", "known": {character id: true}}; read once.
var _locks := {}
## Character -> [wrong tries, tick of the last].
var _pin_fails := {}
## Character -> {friend id: true}; read once.
var _friends := {}


static func _lock_key(location: String, x: int, y: int) -> String:
	return "lock|%s|%d|%d" % [location, x, y]


func _lock_of(key: String) -> Dictionary:
	if not _locks.has(key):
		var raw := store.read_meta(key)
		var d: Variant = JSON.parse_string(raw) if raw != "" else null
		_locks[key] = {"pin": String(d.get("pin", "")), "known": d.get("known", {})} if d is Dictionary else {}
	return _locks[key]


func _save_lock(key: String) -> void:
	var l: Dictionary = _locks.get(key, {})
	note_fact(key, JSON.stringify(l) if not l.is_empty() else "")


## Whether `actor` gets through a lock: the one who set it, their friends and
## whoever once gave the code (until it changes) need none; a wrong code
## counts, and after PIN_TRIES of them one waits. "" or a reason.
func _unlocks(actor: String, owner: String, key: String, r: Dictionary) -> String:
	var l := _lock_of(key)
	if l.is_empty() or actor == owner or is_friend(owner, actor) or (l["known"] as Dictionary).has(actor):
		return ""
	if not r.has("pin"):
		return "locked"
	var fails: Array = _pin_fails.get(actor, [0, 0])
	if int(fails[0]) >= PIN_TRIES and tick - int(fails[1]) < PIN_WAIT_TICKS:
		return "pin_wait"
	if rs(r, "pin") != String(l["pin"]):
		_pin_fails[actor] = [(int(fails[0]) if tick - int(fails[1]) < PIN_WAIT_TICKS else 0) + 1, tick]
		return "wrong_pin"
	_pin_fails.erase(actor)
	(l["known"] as Dictionary)[actor] = true
	_save_lock(key)
	return ""


## The one who set up a door puts a lock with a code of four digits on it,
## changes the code (those who knew the old one must give the new one) or,
## with an empty code, takes the lock off.
func _lock(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, at[0], x, y, USE_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(at[0], at[1], at[2])
	var part := c.get_cell("structure", at[3], at[4])
	if part == "" or not content.get_def(part).get("openable", false):
		return {"ok": false, "reason": "nothing_to_use"}
	var props := c.get_props(at[3], at[4]).duplicate()
	if String(props.get("owner", "")) != actor:
		return {"ok": false, "reason": "not_owner"}
	var pin := rs(r, "pin")
	if (r.has("pin") and typeof(r["pin"]) != TYPE_STRING) or pin != "" and not (pin.length() == 4 and pin.is_valid_int() and not pin.contains("-") and not pin.contains("+")):
		return {"ok": false, "reason": "bad_pin"}
	var key := _lock_key(at[0], x, y)
	_locks[key] = {"pin": pin, "known": {}} if pin != "" else {}
	_save_lock(key)
	if pin != "":
		props["locked"] = true
	else:
		props.erase("locked")
	c.set_props(at[3], at[4], props)
	_changed(chunk_key(at[0], at[1], at[2]))
	return {"ok": true, "locked": pin != ""}


## A door's lock goes with the door.
func _forget_lock(location: String, x: int, y: int) -> void:
	var key := _lock_key(location, x, y)
	if not _lock_of(key).is_empty():
		_locks[key] = {}
		_save_lock(key)


func friends_of(character: String) -> Dictionary:
	if not _friends.has(character):
		var raw := store.read_meta("friends|" + character)
		var f := {}
		for id: String in (raw.split(",", false) if raw != "" else PackedStringArray()):
			f[id] = true
		_friends[character] = f
	return _friends[character]


## Whether `who` is among `character`'s friends (a list of its own: one-way).
func is_friend(character: String, who: String) -> bool:
	return character != "" and friends_of(character).has(who)


func _befriend(actor: String, r: Dictionary, add: bool) -> Dictionary:
	var who := rs(r, "character")
	if who == "" or who == actor or (add and not present.has(who) and _known_character(who).is_empty()):
		return {"ok": false, "reason": "bad_request"}
	var f := friends_of(actor)
	if add:
		f[who] = true
	else:
		f.erase(who)
	note_fact("friends|" + actor, ",".join(PackedStringArray(f.keys())))
	_touch_inventory(actor)  # the own private part goes out again, friends with it
	return {"ok": true, "friends": f.keys()}


## Puts items from the inventory on the ground at the actor's feet (or at
## x, y in movement units for actors not in the world).
func _drop(actor: String, r: Dictionary) -> Dictionary:
	var item := rs(r, "item")
	var n := ri(r, "count", 0)
	if content.kind_of(item) != "item" or n <= 0:
		return {"ok": false, "reason": "bad_request"}
	var where := {"location": rs(r, "location"), "x": ri(r, "x", 0), "y": ri(r, "y", 0)}
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
	var id := rs(r, "entity")
	var it: Dictionary = items.get(id, {})
	if it.is_empty():
		return {"ok": false, "reason": "gone"}
	if present.has(actor):
		var p: Dictionary = present[actor]
		if p["location"] != it["location"] or Vector2(p["pos"]).distance_to(Vector2(it["x"], it["y"])) > PICKUP_REACH:
			return {"ok": false, "reason": "too_far"}
	if not may_take(actor, it):
		return {"ok": false, "reason": "kept_for_dead", "seconds": ceili(float(int(it["until"]) - tick) / Movement.TICK_RATE)}
	var fits := mini(int(it["count"]), room_for(actor, String(it["item"])))
	if fits <= 0:
		return {"ok": false, "reason": "full"}
	if fits < int(it["count"]):  # what the bag takes; the rest stays lying
		it["count"] = int(it["count"]) - fits
		_dirty_items[id] = true
		inventory(actor).add(String(it["item"]), fits)
		_touch_inventory(actor)
		return {"ok": true, "item": it["item"], "count": fits, "left": it["count"]}
	take_item(id, inventory(actor))
	_touch_inventory(actor)
	chronicles.picked(actor, String(it["item"]))
	return {"ok": true, "item": it["item"], "count": it["count"]}


func _someone_stands_on(location: String, x: int, y: int) -> bool:
	for id: String in present:
		var p: Dictionary = present[id]
		if p["location"] == location and BuildRules.stands_on(p["pos"], x, y):
			return true
	return false


# The server's view for BuildRules: the world as it is.
func build_chunk(location: String, cx: int, cy: int) -> Chunk:
	return chunk(location, cx, cy)


func build_kind(location: String) -> String:
	return levels.kind(location)


func build_z(location: String) -> int:
	return levels.z(location)


func build_max_levels() -> int:
	return max_levels


func build_someone_on(location: String, x: int, y: int) -> bool:
	return _someone_stands_on(location, x, y)


func _changed(key: String) -> void:
	_dirty_chunks[key] = true
	_lights_by_chunk.erase(key)
	_chunk_rev[key] = _chunk_rev.get(key, 0) + 1
	revision_epoch += 1
	# Underground, digging at a chunk's edge may lay open ore in the next one
	# (shown_chunk): those are told again too (not saved: nothing in them changed).
	var parts := key.rsplit("|", true, 2)
	if parts.size() == 3 and levels.kind(parts[0]) != Levels.BUILDING_LEVEL and parts[0] != SURFACE:
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next := chunk_key(parts[0], int(parts[1]) + d.x, int(parts[2]) + d.y)
			if _chunk_rev.has(next) or _chunks.has(next):
				_chunk_rev[next] = _chunk_rev.get(next, 0) + 1


func _touch_inventory(owner: String) -> void:
	_dirty_inventories[owner] = true
	_inventory_version[owner] = _inventory_version.get(owner, 0) + 1
	# What is no longer carried is no longer in the hands (dropped, put into a
	# chest, lost in death): others see empty hands at once (ADR-0021).
	if present.has(owner):
		var held := String(present[owner].get("held", ""))
		if held != "" and inventory(owner).count(held) <= 0:
			present[owner]["held"] = ""


## What a character has in its hands (ADR-0021): the server's word, set by
## hold, and always something it carries ("" empty hands).
func held_of(actor: String) -> String:
	if not present.has(actor):
		return ""
	var held := String(present[actor].get("held", ""))
	return held if held != "" and inventory(actor).count(held) > 0 else ""


## An action that names the item it is done with must name what is in the
## hands: "" if so (or if it names none), else "not_held".
func check_held(actor: String, r: Dictionary) -> String:
	if not r.has("item"):
		return ""
	return "" if typeof(r["item"]) == TYPE_STRING and String(r["item"]) == held_of(actor) else "not_held"


## Raised whenever an inventory changes (clients get theirs only then).
func inventory_version(owner: String) -> int:
	return _inventory_version.get(owner, 0)


func _cell(r: Dictionary) -> Array:
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return [rs(r, "location"), cx, cy, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE]


func _build(actor: String, r: Dictionary) -> Dictionary:
	var part := rs(r, "part")
	if content.kind_of(part) != "structure":
		return {"ok": false, "reason": "unknown_part"}
	var def := content.get_def(part)
	var role := String(def["role"])
	var at := _cell(r)
	var loc: String = at[0]
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, loc, x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	# The rules the client also shows its blueprints by (BuildRules).
	var why := BuildRules.check(self, content, part, loc, x, y, _facing(def, r), actor)
	if why != "":
		return {"ok": false, "reason": why}
	var c := chunk(loc, at[1], at[2])
	var on_level := loc != SURFACE
	var layer := Terrain.layer_for_role(role)
	var building := ""
	var upper := ""
	if role == "ceiling":
		building = levels.building(loc) if on_level else ""
	var costs := content.structure_cost(part)
	var inv := inventory(actor)
	if not inv.has_all(costs):
		return {"ok": false, "reason": "materials"}
	if role == "shaft":
		var below := _open_below(loc, Vector2i(x, y), part, true)
		if below != "":
			return {"ok": false, "reason": below}
	# Stairs: the landing must be free to stand on, and a ceiling over them
	# goes only as taking it apart would let it go (nothing over it, no
	# stairs through it) — all asked before anything changes.
	var opening := false
	if role == "stairs":
		var landing := _stairs_arrival(loc, x, y, _facing(def, r))
		var up := _upper_of(loc, landing)
		if up == "" or is_solid(up, landing.x, landing.y):
			return {"ok": false, "reason": "landing_blocked"}
		if c.get_cell("ceiling", at[3], at[4]) != "":
			var above := _above(loc, c, at, "ceiling")
			if above[0] != "":
				return {"ok": false, "reason": above[0]}
			opening = true
	for id: String in costs:
		inv.remove(id, int(costs[id]))
	_touch_inventory(actor)
	var props := {"owner": actor}
	if def.has("container"):
		props["store"] = Uuid.v4()  # its contents are an inventory of their own
	if not (def["rotations"] as Array).is_empty():
		props["facing"] = _facing(def, r)
	if role == "stairs":
		# Where it leads is settled now, so the way down above, the climb and
		# the landing it needs agree whatever is built around it later.
		var arrive := _stairs_arrival(loc, x, y, _facing(def, r))
		props["arrive"] = [arrive.x, arrive.y]
		if opening:
			# The ceiling over it is taken apart by its builder (checked above):
			# its cost comes back, the floor it made above goes — an opening.
			var ceiling := c.get_cell("ceiling", at[3], at[4])
			for id: String in content.structure_cost(ceiling):
				give(actor, id, int(content.structure_cost(ceiling)[id]))
			_take_down(loc, c, at, "ceiling", ceiling, _above(loc, c, at, "ceiling")[1])
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
	if role == "shaft":
		_open_below(loc, Vector2i(x, y), part, false)
	creatures.noise(loc, Vector2i(x, y))  # building is heard around
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
	if opening:
		return {"ok": true, "opened": true}
	return {"ok": true, "level": upper} if upper != "" else {"ok": true}


## The level above `loc` that a cell `cell` of it is a floor of (its ceiling's
## building's next level); "" if none.
func _upper_of(loc: String, cell: Vector2i) -> String:
	if cell == NO_CELL:
		return ""
	var building := levels.building(loc) if loc != SURFACE else _ceiling_building(loc, cell.x, cell.y)
	return levels.level(building, levels.z(loc) + 1) if building != "" else ""


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


## Opens a closed door for one who is not a player (a dweller, ADR-0039):
## not a locked one.
func open_door(location: String, cell: Vector2i) -> void:
	var cx := floori(float(cell.x) / Chunk.SIZE)
	var cy := floori(float(cell.y) / Chunk.SIZE)
	var c := chunk(location, cx, cy)
	var lx := cell.x - cx * Chunk.SIZE
	var ly := cell.y - cy * Chunk.SIZE
	var props := c.get_props(lx, ly).duplicate()
	if props.get("open", false) or props.get("locked", false):
		return
	props["open"] = true
	c.set_props(lx, ly, props)
	_changed(chunk_key(location, cx, cy))


## Whether a roof or a ceiling is over a cell (ADR-0034: out of the rain and the night).
func sheltered(location: String, x: int, y: int) -> bool:
	return _part_at(location, x, y, "ceiling") != "" or _part_at(location, x, y, "roof") != ""


## The part standing on a cell ("" none).
func part_at(location: String, x: int, y: int) -> String:
	return _part_at(location, x, y, "structure")


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
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, loc, x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(loc, at[1], at[2])
	# The layer asked for (ADR-0021: the player points at a roof, a ceiling,
	# a wall); older clients: what stands there, else the roof, the ceiling.
	var layer := rs(r, "layer")
	if layer != "" and not layer in ["structure", "roof", "ceiling"]:
		return {"ok": false, "reason": "bad_request"}
	if layer != "" and c.get_cell(layer, at[3], at[4]) == "":
		return {"ok": false, "reason": "empty"}
	if layer == "":
		for l: String in ["structure", "roof", "ceiling"]:
			if c.get_cell(l, at[3], at[4]) != "":
				layer = l
				break
	if layer == "":
		return {"ok": false, "reason": "empty"}
	var part := c.get_cell(layer, at[3], at[4])
	if layer == "structure" and content.get_def(part).get("natural", false):
		return {"ok": false, "reason": "natural"}
	# Taken apart whole, all it cost back, at once: only by the one who set it
	# up (ADR-0016). Others break it — and stone takes long; were it not so, a
	# lock or a castle wall would mean nothing.
	if _layer_props(c, layer, at[3], at[4]).get("owner", "") != actor:
		return {"ok": false, "reason": "not_owner"}
	if not content.has(part):
		# Its pack is gone: keep the part as it is rather than lose it unpaid.
		return {"ok": false, "reason": "unknown_part"}
	if layer == "structure" and String(c.get_props(at[3], at[4]).get("store", "")) != "" \
			and not inventory("store|" + String(c.get_props(at[3], at[4])["store"])).stacks.is_empty():
		return {"ok": false, "reason": "not_empty"}  # empty it first: nothing is lost
	var above := _above(loc, c, at, layer)
	if above[0] != "":
		return {"ok": false, "reason": above[0]}
	_take_down(loc, c, at, layer, part, above[1])
	creatures.noise(loc, Vector2i(x, y))
	var costs := content.structure_cost(part)
	for id: String in costs:
		give(actor, id, int(costs[id]))
	return {"ok": true, "part": part}


## What keeps a part from going (ADR-0007, ADR-0016: nothing is left hanging):
## a ceiling goes only with nothing on the level above it there — no part,
## thing or person — and no stairs coming up through it. [reason or "", the
## level above (for its floor to go too) or ""].
func _above(loc: String, c: Chunk, at: Array, layer: String) -> Array:
	if layer != "ceiling":
		return ["", ""]
	var x: int = at[1] * Chunk.SIZE + at[3]
	var y: int = at[2] * Chunk.SIZE + at[4]
	var building := levels.building(loc) if loc != SURFACE else String(_layer_props(c, "ceiling", at[3], at[4]).get("building", ""))
	var upper := levels.level(building, levels.z(loc) + 1)
	if _stairs_leading_to(loc, Vector2i(x, y)) != NO_CELL:
		return ["stairs_below", upper]  # stairs come up through it
	if upper != "" and _occupied(upper, x, y):
		return ["occupied_above", upper]  # take those down first, from the top
	return ["", upper]


## A part leaves its cell (taken apart or broken): its marks and lock go, a
## shaft leaves its hole, a ceiling takes the floor it made above.
func _take_down(loc: String, c: Chunk, at: Array, layer: String, part: String, upper: String) -> void:
	var x: int = at[1] * Chunk.SIZE + at[3]
	var y: int = at[2] * Chunk.SIZE + at[4]
	if layer == "structure" and _is_stairs(part):
		_mark_stairs_down(loc, x, y, false)
	if layer == "structure" and bool(content.get_def(part).get("openable", false)):
		_forget_lock(loc, x, y)
	c.set_cell(layer, at[3], at[4], "")
	if layer == "structure" and content.get_def(part).get("role") == "shaft":
		# The equipment goes, the hole stays (ADR-0017): the way and what is
		# below are not lost, nobody is shut in.
		c.set_cell(layer, at[3], at[4], "base:shaft_hole")
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


## Gets what a part or a plant holds (ADR-0017, ADR-0021): rock dug, a tree
## felled — {"layer": "structure", "cover" or "ground", "item": what one
## holds}. The thing's "gather" says which kind of tool it takes; the item
## held must be carried and be that kind of tool. A part or a plant is gone
## then, ground stays (fish caught, the water is still there); what it held
## goes to the one who got it.
func _gather(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var loc: String = at[0]
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	var layer := rs(r, "layer", "structure")
	if not layer in ["structure", "cover", "ground"]:
		return {"ok": false, "reason": "bad_request"}
	if not _reaches(actor, loc, x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(loc, at[1], at[2])
	var thing := c.get_cell(layer, at[3], at[4])
	var g: Dictionary = content.get_def(thing).get("gather", {}) if thing != "" else {}
	if g.is_empty():
		return {"ok": false, "reason": "nothing_to_gather"}
	# Something solid (rock, a tree) is reached as Reach says: the first
	# solid from the digger toward the aim, within three cells.
	if layer != "ground" and present.has(actor) and is_solid(loc, x, y):
		var aim := Vector2(float(r.get("ax", x * Movement.UNIT + Movement.UNIT / 2)), float(r.get("ay", y * Movement.UNIT + Movement.UNIT / 2))) \
			if typeof(r.get("ax")) in [TYPE_INT, TYPE_FLOAT] and typeof(r.get("ay")) in [TYPE_INT, TYPE_FLOAT] \
			else Vector2(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2)
		var hit := Reach.first_solid(present[actor]["pos"], aim, func(sx: int, sy: int) -> bool: return is_solid(loc, sx, sy))
		if hit != Vector2i(x, y):
			return {"ok": false, "reason": "too_far" if hit == Reach.NONE else "in_the_way"}
	var why := check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := held_of(actor)
	# A crop is gathered ripe only (ADR-0027).
	var crop := content.get_def(thing)
	if crop.has("crop") and not Crops.ripe(crop, float(_layer_props(c, layer, at[3], at[4]).get("planted", 0)), world_time,
			weather_seed if has_daylight(loc) else -1):
		return {"ok": false, "reason": "not_ripe"}
	var tool := String(g["tool"])
	if tool != "" and (item == "" or not (content.get_def(item).get("tools", []) as Array).has(tool)):
		return {"ok": false, "reason": "no_tool"}  # the tool must be in the hands, not in the bag
	# Work takes blows (a tree by its size and wood), at the tool's pace; how
	# far it has gone is kept with the thing (props of its layer).
	var work := int(g.get("work", 1))
	if work > 1:
		var pace: Dictionary = content.get_def(item).get("weapon", {}) if item != "" else {}
		if not combat.ready(actor, float(pace.get("cooldown_ms", 700))):
			return {"ok": false, "reason": "not_ready"}
	if g.has("chance") and not combat.ready(actor, float((content.get_def(item).get("weapon", {}) if item != "" else {}).get("cooldown_ms", 700))):
		return {"ok": false, "reason": "not_ready"}
	combat.swung(actor, Vector2i(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2))
	creatures.noise(loc, Vector2i(x, y))
	if g.has("chance"):
		return _gather_by_luck(actor, c, at, thing, g)
	# A better tool does more a blow ("power": an iron axe fells sooner).
	var power := maxi(1, int(content.get_def(item).get("power", 1))) if item != "" else 1
	var done := int(_layer_props(c, layer, at[3], at[4]).get("work", 0)) + power
	if done < work:
		var props := _layer_props(c, layer, at[3], at[4]).duplicate()
		props["work"] = done
		if layer == "structure":
			c.set_props(at[3], at[4], props)
		else:
			_set_layer_props(c, layer, at[3], at[4], props)
		_changed(chunk_key(loc, at[1], at[2]))
		return {"ok": true, "thing": thing, "work": mini(done, work), "of": work}
	if layer != "structure":
		_set_layer_props(c, layer, at[3], at[4], {})
	if layer != "ground":
		c.set_cell(layer, at[3], at[4], String(g.get("becomes", "")))  # gone, or what it is after (a bush picked)
	_changed(chunk_key(loc, at[1], at[2]))
	var drops: Dictionary = g.get("drops", {})
	for id: String in drops:
		give(actor, id, int(drops[id]))
	return {"ok": true, "thing": thing, "drops": drops}


## A gather by luck (ADR-0031: fishing): every try has the ground's
## "chance" of a catch, better at dawn and dusk, less where much was taken
## lately (its "stock", back one every "restock_hours"); a catch is one of
## "pick" by weight. The ground stays; what was taken is in its props.
func _gather_by_luck(actor: String, c: Chunk, at: Array, thing: String, g: Dictionary) -> Dictionary:
	var props := _layer_props(c, "ground", at[3], at[4]).duplicate()
	var taken := maxf(0.0, float(props.get("taken", 0.0))
		- float(world_time - int(props.get("at", world_time))) / (float(g["restock_hours"]) * Daylight.HOUR_MS))
	var chance := float(g["chance"]) * bite_hour(world_time) * maxf(0.0, 1.0 - taken / float(g["stock"]))
	if has_daylight(at[0]):
		chance *= 1.0 + 0.3 * Weather.rain(weather_seed, world_time)  # fish bite in the rain
	var roll := float(absi(hash([world_seed, actor, at[0], at[1], at[2], at[3], at[4], tick])) % 100003) / 100003.0
	if roll >= chance:
		return {"ok": true, "thing": thing, "bite": false, "chance": chance}
	var pick: Dictionary = g["pick"]
	var total := 0.0
	for id: String in pick:
		total += float(pick[id])
	var r := float(absi(hash([roll, world_seed, tick])) % 100003) / 100003.0 * total
	var got := ""
	for id: String in pick:
		got = id
		r -= float(pick[id])
		if r < 0.0:
			break
	props["taken"] = taken + 1.0
	props["at"] = world_time
	_set_layer_props(c, "ground", at[3], at[4], props)
	_changed(chunk_key(at[0], at[1], at[2]))
	give(actor, got, 1)
	return {"ok": true, "thing": thing, "bite": true, "drops": {got: 1}}


## How well fish bite at an hour: best at dawn and dusk, worst at noon and midnight.
static func bite_hour(time_ms: int) -> float:
	var h := Daylight.hour_of(time_ms)
	if (h >= 5.0 and h < 8.0) or (h >= 18.0 and h < 21.0):
		return 1.5
	if (h >= 11.0 and h < 15.0) or h >= 23.0 or h < 3.0:
		return 0.7
	return 1.0


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
	return _someone_stands_on(location, x, y)  # one away is let down when back (enter)


## Up or down a staircase next to the character (ADR-0007, ADR-0013): up
## from a cell with stairs onto their landing on the level above (stairs of
## old not yet brought to today's way: their own cell); down from the
## opening over stairs below, or from their landing, onto those stairs.
## Off the edge of a level (ADR-0019, GDD scenario 12): into the next cell,
## {"dx", "dy"} from where one stands, down to the first floor under it (the
## street from a walkway, a lower floor of a building), hurt by the height
## fallen (the body plan's "fall_damage", by levels). Not into a wall, not
## onto a roof.
func _jump(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var p: Dictionary = present[actor]
	var loc: String = p["location"]
	if levels.kind(loc) != Levels.BUILDING_LEVEL:
		return {"ok": false, "reason": "nothing_to_jump_from"}
	var d := Vector2i(clampi(ri(r, "dx", 0), -1, 1), clampi(ri(r, "dy", 0), -1, 1))
	if d == Vector2i.ZERO:
		return {"ok": false, "reason": "bad_request"}
	var to := Movement.cell_of(p["pos"]) + d
	if _part_at(loc, to.x, to.y, "ground") != "":
		return {"ok": false, "reason": "not_an_edge"}  # the floor goes on: walk
	var z := levels.z(loc)
	var below := combat.location_under(to, z - 0.5)
	if is_solid(below, to.x, to.y):
		return {"ok": false, "reason": "blocked"}
	if _part_at(below, to.x, to.y, "roof") != "":
		return {"ok": false, "reason": "roof_below"}
	var fallen := z - levels.z(below)
	p["location"] = below
	p["pos"] = Vector2i(to.x * Movement.UNIT + Movement.UNIT / 2, to.y * Movement.UNIT + Movement.UNIT / 2)
	_dirty_world_characters[actor] = true
	relocated[actor] = true
	var fall: Array = content.get_def(String((p["appearance"] as Dictionary).get("body_plan", ""))).get("fall_damage", [0, 2, 6, 12, 20])
	var hurt := int(fall[mini(fallen, fall.size() - 1)]) if not fall.is_empty() else 0
	creatures.noise(below, to)
	if hurt > 0:
		combat.hurt(actor, hurt, "")
	return {"ok": true, "location": below, "z": levels.z(below), "hurt": hurt}


func _climb(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var p: Dictionary = present[actor]
	var loc: String = p["location"]
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if rs(r, "location") != loc or not _reaches(actor, loc, x, y, USE_REACH):
		return {"ok": false, "reason": "too_far"}
	var shaft := _part_at(loc, x, y, "structure")
	if shaft != "" and content.get_def(shaft).get("role") == "shaft":
		return _through_shaft(actor, p, loc, Vector2i(x, y), shaft)
	var dest := ""
	var to := Vector2i(x, y)
	# "dir": "up" or "down" where stairs stand over stairs and both ways lead
	# on from one cell; without it, up first (older clients).
	var dir := rs(r, "dir")
	if dir != "down" and _is_stairs(_part_at(loc, x, y, "structure")):
		var arrive := _arrival_of(loc, x, y)
		dest = _upper_of(loc, arrive)
		to = arrive
		if dest != "" and is_solid(dest, to.x, to.y):
			return {"ok": false, "reason": "landing_blocked"}  # something built on the landing since
	if dest == "" and dir != "up" and loc != SURFACE:
		# Down: the stairs under the opening asked for, or those leading up
		# onto the landing asked for.
		var below := levels.level(levels.building(loc), levels.z(loc) - 1)
		var from := NO_CELL
		if below != "" and _is_stairs(_part_at(below, x, y, "structure")) \
				and _upper_of(below, _arrival_of(below, x, y)) == loc:
			from = Vector2i(x, y)
		elif below != "":
			from = _stairs_leading_to(below, Vector2i(x, y))
		if from != NO_CELL:
			dest = below
			to = from
	if dest == "":
		return {"ok": false, "reason": "no_stairs"}
	p["location"] = dest
	p["pos"] = Vector2i(to.x * Movement.UNIT + Movement.UNIT / 2, to.y * Movement.UNIT + Movement.UNIT / 2)
	_dirty_world_characters[actor] = true
	relocated[actor] = true
	return {"ok": true, "location": dest, "z": levels.z(dest)}


const NO_CELL := Vector2i(1 << 30, 1 << 30)


## The depth a shaft at `loc` leads to (ADR-0017): down from the surface to
## -1, from a depth to the next; up to the depth above, from -1 to the surface.
## "" where it may not lead (beyond the server's deepest depth).
func _shaft_leads(loc: String, part: String) -> String:
	var down := String(content.get_def(part).get("leads", "down")) == "down"
	var z := levels.z(loc) if Levels.is_depth(loc) else 0
	if loc != SURFACE and not Levels.is_depth(loc):
		return ""
	var to := z - 1 if down else z + 1
	if to >= 0:
		return SURFACE
	if max_depth > 0 and to < -max_depth:
		return ""
	return Levels.depth_id(to)


func _through_shaft(actor: String, p: Dictionary, loc: String, at: Vector2i, part: String) -> Dictionary:
	var dest := _shaft_leads(loc, part)
	if dest == "":
		return {"ok": false, "reason": "too_deep"}
	if is_solid(dest, at.x, at.y):
		return {"ok": false, "reason": "blocked"}
	p["location"] = dest
	p["pos"] = Vector2i(at.x * Movement.UNIT + Movement.UNIT / 2, at.y * Movement.UNIT + Movement.UNIT / 2)
	_dirty_world_characters[actor] = true
	relocated[actor] = true
	return {"ok": true, "location": dest, "z": levels.z(dest)}


## A shaft built down (a mine shaft, a headframe): the depth below gets a
## working round the same cell, its rock cut away, and a ladder up in it.
## Refused if something built stands there below.
func _open_below(loc: String, at: Vector2i, part: String, check_only: bool) -> String:
	var dest := _shaft_leads(loc, part)
	if dest == "" or dest == SURFACE:
		return "too_deep"
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := at + Vector2i(dx, dy)
			var cx := floori(float(c.x) / Chunk.SIZE)
			var cy := floori(float(c.y) / Chunk.SIZE)
			var ch := chunk(dest, cx, cy)
			var lx := c.x - cx * Chunk.SIZE
			var ly := c.y - cy * Chunk.SIZE
			var there := ch.get_cell("structure", lx, ly)
			var natural := there == "" or bool(content.get_def(there).get("natural", false))
			if dx == 0 and dy == 0 and (not natural or ch.get_cell("ground", lx, ly) == "base:water"):
				if not (there != "" and content.get_def(there).get("role") == "shaft"):
					return "blocked_below"
			if check_only:
				continue
			var is_shaft: bool = there != "" and content.get_def(there).get("role") == "shaft"
			if there != "" and content.get_def(there).get("role") == "rock":
				ch.set_cell("structure", lx, ly, "")
			if dx == 0 and dy == 0 and not is_shaft:
				ch.set_cell("structure", lx, ly, "base:mine_ladder")
			_changed(chunk_key(dest, cx, cy))
	return ""


## The facing a part is built in: the one asked for if the part allows it,
## else its default (the first it lists); "" for parts that do not turn.
func _facing(def: Dictionary, r: Dictionary) -> String:
	return BuildRules.facing_of(def, rs(r, "facing"))


## Where stairs at (x, y) facing `facing` would lead on the level above: the
## landing their top faces (BuildRules.stairs_arrival); NO_CELL if none.
func _stairs_arrival(loc: String, x: int, y: int, facing: String) -> Vector2i:
	return BuildRules.stairs_arrival(self, loc, x, y, facing)


## Where built stairs lead (stairs built before they remembered it: their
## own cell, which was then the only way).
func _arrival_of(loc: String, x: int, y: int) -> Vector2i:
	var a: Variant = _props_at(loc, x, y).get("arrive")
	if typeof(a) == TYPE_ARRAY and (a as Array).size() == 2:
		return Vector2i(int(a[0]), int(a[1]))
	return Vector2i(x, y)


## The stairs on `loc` that lead up to `cell` (on the level above), else NO_CELL.
func _stairs_leading_to(loc: String, cell: Vector2i) -> Vector2i:
	for d: Vector2i in [Vector2i.ZERO, Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]:
		var at := cell + d
		if _is_stairs(_part_at(loc, at.x, at.y, "structure")) and _arrival_of(loc, at.x, at.y) == cell:
			return at
	return NO_CELL


func _part_at(loc: String, x: int, y: int, layer: String) -> String:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return chunk(loc, cx, cy).get_cell(layer, x - cx * Chunk.SIZE, y - cy * Chunk.SIZE)


func _props_at(loc: String, x: int, y: int) -> Dictionary:
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	return chunk(loc, cx, cy).get_props(x - cx * Chunk.SIZE, y - cy * Chunk.SIZE)


## Marks (or unmarks) the way down on the level above: the opening over the
## stairs at (x, y), where they are seen coming up (for stairs of old, their
## own cell, which is also where they lead).
func _mark_stairs_down(location: String, x: int, y: int, on: bool) -> void:
	_mark_way_down(_upper_of(location, _arrival_of(location, x, y)), Vector2i(x, y), on)


func _mark_way_down(upper: String, cell: Vector2i, on: bool) -> void:
	if upper == "":
		return
	var cx := floori(float(cell.x) / Chunk.SIZE)
	var cy := floori(float(cell.y) / Chunk.SIZE)
	var uc := chunk(upper, cx, cy)
	var lx := cell.x - cx * Chunk.SIZE
	var ly := cell.y - cy * Chunk.SIZE
	var props := uc.get_props(lx, ly).duplicate()
	if on:
		props["stairs_down"] = true
	else:
		props.erase("stairs_down")
	uc.set_props(lx, ly, props)
	_changed(chunk_key(upper, cx, cy))


## Stairs built before 16.10.2026 came up through a ceiling over themselves,
## onto their own cell (or, ADR-0013, onto the next cell, marked there). As
## their chunk comes into memory they are brought to today's way where that
## is safe: the ceiling over them is taken away (its cost to its builder),
## they lead onto the floor their top faces, the way down is marked over
## them. Not safe — no floor there to land on, something or someone in the
## world on the cell above, other stairs leading onto it — they stay as they
## were and still work so (a compatibility kept until they are rebuilt);
## tried again next time. One away who stood there is let down by enter().
func _settle_stairs(location: String, cx: int, cy: int, c: Chunk) -> void:
	if location != SURFACE and levels.kind(location) != Levels.BUILDING_LEVEL:
		return
	for i: int in c.props.keys():
		var lx := i % Chunk.SIZE
		var ly := i / Chunk.SIZE
		if not _is_stairs(c.get_cell("structure", lx, ly)):
			continue
		var at := [location, cx, cy, lx, ly]
		var own := Vector2i(cx * Chunk.SIZE + lx, cy * Chunk.SIZE + ly)
		var arrive := _arrival_of(location, own.x, own.y)
		var top := own + (ContentRegistry.FACINGS.get(String(c.get_props(lx, ly).get("facing", "n")), Vector2i(0, -1)) as Vector2i)
		var covered := c.get_cell("ceiling", lx, ly) != ""
		if arrive != own and not covered:
			# Today's way, or ADR-0013's: the mark of the way down goes over them.
			var landing := _upper_of(location, arrive)
			if landing != "" and bool(_props_at(landing, arrive.x, arrive.y).get("stairs_down", false)) \
					and _stairs_leading_to(location, arrive) == own:
				_mark_way_down(landing, arrive, false)
				_mark_way_down(landing, own, true)
			continue
		if not covered or arrive != own and arrive != top:
			continue
		var up := _upper_of(location, top)
		if up == "" or is_solid(up, top.x, top.y) or _part_at(location, top.x, top.y, "ceiling") == "":
			continue  # nowhere to land beside: as it was
		if up != "" and _occupied(up, own.x, own.y):
			continue  # something over it: not taken away under it
		var others := false
		for d: Vector2i in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]:
			var o := own + d
			if _is_stairs(_part_at(location, o.x, o.y, "structure")) and _arrival_of(location, o.x, o.y) == own:
				others = true
		if others:
			continue
		var ceiling := c.get_cell("ceiling", lx, ly)
		var builder := String((c.get_props(lx, ly).get("ceiling", {}) as Dictionary).get("owner", ""))
		_mark_way_down(_upper_of(location, own), own, false)
		if arrive == top:
			_mark_way_down(up, top, false)  # ADR-0013's mark on its landing
		var props := c.get_props(lx, ly).duplicate()
		props["arrive"] = [top.x, top.y]
		c.set_props(lx, ly, props)
		_take_down(location, c, at, "ceiling", ceiling, up)
		if builder != "" and content.has(ceiling):
			var cost := content.structure_cost(ceiling)
			for id: String in cost:
				give(builder, id, int(cost[id]))
		_mark_way_down(up, own, true)


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
		_last_chunk = null
		chunks_epoch += 1
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


# --- containers (chests) ---------------------------------------------------------

## The container at a request's cell, if the actor may use it: [inventory
## owner key, its definition's "container", ""] or [..., ..., reason].
func _container(actor: String, r: Dictionary) -> Array:
	var at := _cell(r)
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, at[0], x, y, USE_REACH):
		return ["", {}, "too_far"]
	var c := chunk(at[0], at[1], at[2])
	var part := c.get_cell("structure", at[3], at[4])
	var spec: Dictionary = content.get_def(part).get("container", {}) if part != "" else {}
	var props := c.get_props(at[3], at[4])
	if spec.is_empty() or String(props.get("store", "")) == "":
		return ["", {}, "not_a_container"]
	# Whose things are whose (ADR-0016): the owner and the owner's friends open
	# it; others can only break it.
	var owner := String(props.get("owner", ""))
	if owner != actor and not is_friend(owner, actor):
		return ["", {}, "not_owner"]
	return ["store|" + String(props["store"]), spec, ""]


func _look_in(actor: String, r: Dictionary) -> Dictionary:
	var c := _container(actor, r)
	if c[2] != "":
		return {"ok": false, "reason": c[2]}
	return {"ok": true, "contents": inventory(c[0]).stacks.duplicate(), "slots": int(c[1]["slots"])}


## Puts into (store) or takes out of (take) a container {"item", "count"}.
func _move_items(actor: String, r: Dictionary, putting: bool) -> Dictionary:
	var c := _container(actor, r)
	if c[2] != "":
		return {"ok": false, "reason": c[2]}
	var item := rs(r, "item")
	var n := ri(r, "count", 0)
	if content.kind_of(item) != "item" or n <= 0:
		return {"ok": false, "reason": "bad_request"}
	var box := inventory(c[0])
	var from := inventory(actor) if putting else box
	var to := box if putting else inventory(actor)
	if from.count(item) < n:
		return {"ok": false, "reason": "not_enough"}
	if not putting:
		n = mini(n, room_for(actor, item))  # what the bag takes
		if n <= 0:
			return {"ok": false, "reason": "full"}
	if putting:
		var after := box.stacks.duplicate()
		after[item] = int(after.get(item, 0)) + n
		if Bag.used(content, after) > int(c[1]["slots"]):
			return {"ok": false, "reason": "box_full"}
	from.remove(item, n)
	to.add(item, n)
	_touch_inventory(actor)
	_touch_inventory(c[0])
	return {"ok": true, "contents": box.stacks.duplicate(), "slots": int(c[1]["slots"])}


# --- crafts and food (ADR-0026) ---------------------------------------------------

## Makes a recipe `count` times, at a station of its kind within reach (none
## for one made in the hands), from what one carries: all of it or nothing.
func _craft(actor: String, r: Dictionary) -> Dictionary:
	var id := rs(r, "recipe")
	var d := content.get_def(id)
	var n := ri(r, "count", 1)
	if d.get("kind") != "recipe" or n < 1 or n > 100:
		return {"ok": false, "reason": "bad_request"}
	var station := String(d.get("station", ""))
	if station != "" and not station_near(actor, station):
		return {"ok": false, "reason": "no_station", "station": station}
	var bag := inventory(actor)
	var need := {}
	for item: String in d["inputs"]:
		need[item] = int(d["inputs"][item]) * n
	if not bag.has_all(need):
		return {"ok": false, "reason": "not_enough"}
	for item: String in need:
		bag.remove(item, need[item])
	var made := {}
	for item: String in d["outputs"]:
		made[item] = int(d["outputs"][item]) * n
		give(actor, item, made[item])
	_touch_inventory(actor)
	return {"ok": true, "made": made}


## Whether a station of a kind ("station" of a part) stands within reach of
## a present character, on its own location.
func station_near(actor: String, station: String) -> bool:
	if not present.has(actor):
		return false
	var p: Dictionary = present[actor]
	var loc := String(p["location"])
	var at := Movement.cell_of(p["pos"])
	var r := ceili(float(USE_REACH) / Movement.UNIT)
	for y in range(at.y - r, at.y + r + 1):
		for x in range(at.x - r, at.x + r + 1):
			var part := chunk(loc, x >> 5, y >> 5).get_cell("structure", x & 31, y & 31)
			if part != "" and content.get_def(part).get("station") == station and _reaches(actor, loc, x, y, USE_REACH):
				return true
	return false


## Eats one of a food one carries: it heals, up to one's most health.
func _eat(actor: String, r: Dictionary) -> Dictionary:
	var item := rs(r, "item")
	var food: Dictionary = content.get_def(item).get("food", {})
	if food.is_empty():
		return {"ok": false, "reason": "not_food"}
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	if inventory(actor).count(item) < 1:
		return {"ok": false, "reason": "not_enough"}
	var health := combat.health_of(actor)
	var most := combat.max_health_of(actor)
	# Eaten when hurt or not full (ADR-0032): it heals and fills.
	if health >= most and needs.satiety_of(actor) > Needs.FULL - 5.0:
		return {"ok": false, "reason": "not_hungry"}
	inventory(actor).remove(item, 1)
	_touch_inventory(actor)
	combat.heal(actor, int(food.get("heal", 0)))
	needs.set_satiety(actor, needs.satiety_of(actor) + float(food.get("satiety", 0)))
	var out := {"ok": true, "health": combat.health_of(actor), "satiety": needs.shown(actor)["satiety"]}
	var empty := String(content.get_def(item).get("liquid", {}).get("empty", ""))
	if empty != "":  # drunk: the container is left (a bucket of milk)
		give(actor, empty, 1)
		out["now"] = empty
	return out


# --- fields (ADR-0027) ------------------------------------------------------------

## Turns the ground of a cell over with a tilling tool in the hands: it
## becomes what its ground is "tilled" to (a field), if nothing grows or
## stands on it.
func _till(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, at[0], x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var why := check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := held_of(actor)
	if item == "" or not (content.get_def(item).get("tools", []) as Array).has("tilling"):
		return {"ok": false, "reason": "no_tool"}
	var c := chunk(at[0], at[1], at[2])
	var into := String(content.get_def(c.get_cell("ground", at[3], at[4])).get("tilled", ""))
	if into == "":
		return {"ok": false, "reason": "not_tillable"}
	if c.get_cell("structure", at[3], at[4]) != "" or c.get_cell("cover", at[3], at[4]) != "":
		return {"ok": false, "reason": "occupied"}
	combat.swung(actor, Vector2i(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2))
	c.set_cell("ground", at[3], at[4], into)
	_changed(chunk_key(at[0], at[1], at[2]))
	return {"ok": true}


# --- trade (ADR-0040) ------------------------------------------------------------

const COIN := "base:coin"


## The dweller one trades with, checked: [creature, its trade] or [null, reason].
func _trader(actor: String, r: Dictionary) -> Array:
	if not present.has(actor) or typeof(r.get("creature")) != TYPE_STRING:
		return [null, "bad_request"]
	var c := creatures.get_creature(String(r["creature"]))
	if c == null or c.job.is_empty():
		return [null, "nothing_there"]
	var trade: Dictionary = content.get_def(String(c.job.get("profession", ""))).get("trade", {})
	if trade.is_empty():
		return [null, "no_trade"]
	var p: Dictionary = present[actor]
	if p["location"] != c.location or Vector2(p["pos"]).distance_to(Vector2(c.pos)) > USE_REACH + float(combat.size_of(c.id)["radius"]):
		return [null, "too_far"]
	if c.asleep or c.state == "flee":
		return [null, "not_now"]
	if chronicles.bears_grudge(c, actor):
		return [null, "grudge"]
	# Each morning the stock and the purse are as the trade says.
	var day := world_time / Daylight.DAY_MS
	if int(c.job.get("stocked", -1)) != day:
		var stock := inventory("trade|" + c.id)
		for item: String in stock.stacks.keys():
			stock.remove(item, int(stock.stacks[item]))
		for item: String in trade.get("sells", {}):
			stock.add(item, int(trade["sells"][item][0]))
		_touch_inventory("trade|" + c.id)
		c.job["stocked"] = day
		c.job["purse"] = int(trade.get("purse", 0))
		c.changed()
	return [c, trade]


## Talk with a dweller (ADR-0042): what it says and asks ("talk"), taking
## its request on ("promise"), telling it is done ("report").
func _talk(actor: String, r: Dictionary, what: String) -> Dictionary:
	if not present.has(actor) or typeof(r.get("creature")) != TYPE_STRING:
		return {"ok": false, "reason": "bad_request"}
	var c := creatures.get_creature(String(r["creature"]))
	if c == null or not c.job.has("village"):
		return {"ok": false, "reason": "nothing_there"}
	var p: Dictionary = present[actor]
	if p["location"] != c.location or Vector2(p["pos"]).distance_to(Vector2(c.pos)) > USE_REACH + float(combat.size_of(c.id)["radius"]):
		return {"ok": false, "reason": "too_far"}
	if c.asleep:
		return {"ok": false, "reason": "not_now"}
	match what:
		"promise":
			return chronicles.promise(actor, c)
		"report":
			return chronicles.report(actor, c)
	return chronicles.talk(actor, c)


func _goods(c: Creature, trade: Dictionary) -> Dictionary:
	var stock := inventory("trade|" + c.id)
	var sells := {}
	for item: String in trade.get("sells", {}):
		sells[item] = [stock.count(item), int(trade["sells"][item][1])]
	return {"ok": true, "profession": String(c.job.get("profession", "")), "sells": sells,
		"buys": (trade.get("buys", {}) as Dictionary).duplicate(), "purse": int(c.job.get("purse", 0))}


func _trade_look(actor: String, r: Dictionary) -> Dictionary:
	var t := _trader(actor, r)
	if t[0] == null:
		return {"ok": false, "reason": t[1]}
	return _goods(t[0], t[1])


## Buys from a dweller (coins for its goods, as its stock has) or sells to it
## (goods it buys, for coins as its purse has) — all or nothing.
func _trade(actor: String, r: Dictionary) -> Dictionary:
	var t := _trader(actor, r)
	if t[0] == null:
		return {"ok": false, "reason": t[1]}
	var c: Creature = t[0]
	var trade: Dictionary = t[1]
	var item := rs(r, "item")
	var n := ri(r, "count", 1)
	if n < 1 or n > 999:
		return {"ok": false, "reason": "bad_request"}
	var inv := inventory(actor)
	var stock := inventory("trade|" + c.id)
	if bool(r.get("buy", true)):
		if not (trade.get("sells", {}) as Dictionary).has(item):
			return {"ok": false, "reason": "not_sold"}
		var price := int(trade["sells"][item][1]) * n
		if stock.count(item) < n:
			return {"ok": false, "reason": "sold_out"}
		if inv.count(COIN) < price:
			return {"ok": false, "reason": "no_money"}
		var after := inv.stacks.duplicate()
		after[COIN] = int(after[COIN]) - price
		if after[COIN] == 0:
			after.erase(COIN)
		if Bag.room_for(content, after, item) < n:
			return {"ok": false, "reason": "full"}
		inv.remove(COIN, price)
		stock.remove(item, n)
		inv.add(item, n)
		c.job["purse"] = int(c.job.get("purse", 0)) + price
	else:
		if not (trade.get("buys", {}) as Dictionary).has(item):
			return {"ok": false, "reason": "not_bought"}
		var price := int(trade["buys"][item]) * n
		if inv.count(item) < n:
			return {"ok": false, "reason": "not_carried"}
		if int(c.job.get("purse", 0)) < price:
			return {"ok": false, "reason": "no_money_there"}
		inv.remove(item, n)
		give(actor, COIN, price)
		c.job["purse"] = int(c.job.get("purse", 0)) - price
	c.changed()
	_touch_inventory(actor)
	_touch_inventory("trade|" + c.id)
	return _goods(c, trade)


# --- liquids (ADR-0037) ---------------------------------------------------------

## Fills the empty container in the hands from a ground (water) or one's own
## animal (a cow) whose "fills" takes it: it becomes the filled thing.
func _fill(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var why := check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := held_of(actor)
	if item == "":
		return {"ok": false, "reason": "not_held"}
	var into := ""
	if typeof(r.get("creature")) == TYPE_STRING:
		var c := creatures.get_creature(String(r["creature"]))
		if c == null:
			return {"ok": false, "reason": "nothing_there"}
		var def := content.get_def(c.kind)
		into = String(def.get("fills", {}).get(item, ""))
		if into == "":
			return {"ok": false, "reason": "nothing_to_fill"}
		var p: Dictionary = present[actor]
		if p["location"] != c.location or Vector2(p["pos"]).distance_to(Vector2(c.pos)) > USE_REACH + float(combat.size_of(c.id)["radius"]):
			return {"ok": false, "reason": "too_far"}
		if c.owner != actor:
			return {"ok": false, "reason": "not_yours"}
		if c.filled_at >= 0 and world_time - c.filled_at < int(float(def.get("fill_hours", 12.0)) * Daylight.HOUR_MS):
			return {"ok": false, "reason": "not_yet"}
		c.filled_at = world_time
		c.changed()
	else:
		var at := _cell(r)
		if not _reaches(actor, at[0], ri(r, "x", 0), ri(r, "y", 0), USE_REACH):
			return {"ok": false, "reason": "too_far"}
		into = String(content.get_def(chunk(at[0], at[1], at[2]).get_cell("ground", at[3], at[4])).get("fills", {}).get(item, ""))
		if into == "":
			return {"ok": false, "reason": "nothing_to_fill"}
	var inv := inventory(actor)
	if not inv.remove(item, 1):
		return {"ok": false, "reason": "not_carried"}
	give(actor, into, 1)
	return {"ok": true, "now": into}


## How long a watered crop is helped, and how much.
const WATERED_HOURS := 12.0
const WATER_GROWS := 6.0


## Pours out the liquid in the hands: the container is empty again. On a
## crop, water waters it (as six hours of growing, once in twelve).
func _pour(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var why := check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := held_of(actor)
	var liquid: Dictionary = content.get_def(item).get("liquid", {}) if item != "" else {}
	if liquid.is_empty():
		return {"ok": false, "reason": "not_a_liquid"}
	var watered := false
	if r.has("x") and r.has("y") and bool(liquid.get("waters", false)):
		var at := _cell(r)
		if not _reaches(actor, at[0], ri(r, "x", 0), ri(r, "y", 0), USE_REACH):
			return {"ok": false, "reason": "too_far"}
		var c := chunk(at[0], at[1], at[2])
		var crop := c.get_cell("cover", at[3], at[4])
		if crop != "" and content.get_def(crop).has("crop"):
			var props := _layer_props(c, "cover", at[3], at[4]).duplicate()
			if not props.has("watered_at") or world_time - int(props["watered_at"]) >= int(WATERED_HOURS * Daylight.HOUR_MS):
				props["planted"] = int(props.get("planted", world_time)) - int(WATER_GROWS * Daylight.HOUR_MS)
				props["watered_at"] = world_time
				_set_layer_props(c, "cover", at[3], at[4], props)
				_changed(chunk_key(at[0], at[1], at[2]))
				watered = true
	var inv := inventory(actor)
	if not inv.remove(item, 1):
		return {"ok": false, "reason": "not_carried"}
	give(actor, String(liquid["empty"]), 1)
	return {"ok": true, "now": String(liquid["empty"]), "watered": watered}


## Lies down in a bed within reach (ADR-0035): one sleeps on it, energy
## coming back, until full, until one moves or is struck. A bed sleeps one.
func _sleep(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var at := _cell(r)
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, at[0], x, y, USE_REACH):
		return {"ok": false, "reason": "too_far"}
	if not content.get_def(part_at(at[0], x, y)).get("bed", false):
		return {"ok": false, "reason": "not_a_bed"}
	if needs.energy_of(actor) > Needs.FULL - 10.0:
		return {"ok": false, "reason": "not_tired"}
	for id: String in present:
		if id != actor and present[id].has("asleep") and present[id]["asleep"] == Vector2i(x, y) and present[id]["location"] == at[0]:
			return {"ok": false, "reason": "someone_there"}
	present[actor]["asleep"] = Vector2i(x, y)
	move_character(actor, Vector2i(x, y) * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2))
	return {"ok": true}


## Up from a bed (moved, struck, rested, asked).
func wake(id: String) -> void:
	if present.has(id) and present[id].has("asleep"):
		present[id].erase("asleep")
		note_character(id)


## Feeds an animal what it eats, held in the hands (ADR-0030): a wild one
## fed its "tame" feeds becomes the feeder's; one's own (anyone's) is fed
## for its produce and young, not again while full.
const FULL_HOURS := 6.0


func _feed(actor: String, r: Dictionary) -> Dictionary:
	if typeof(r.get("creature")) != TYPE_STRING:
		return {"ok": false, "reason": "bad_request"}
	var c := creatures.get_creature(String(r["creature"]))
	if c == null or not present.has(actor):
		return {"ok": false, "reason": "nothing_there"}
	var tame: Dictionary = content.get_def(c.kind).get("tame", {})
	if tame.is_empty():
		return {"ok": false, "reason": "not_tameable"}
	var p: Dictionary = present[actor]
	if p["location"] != c.location or Vector2(p["pos"]).distance_to(Vector2(c.pos)) > USE_REACH + float(combat.size_of(c.id)["radius"]):
		return {"ok": false, "reason": "too_far"}
	var why := check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := held_of(actor)
	if not (tame["food"] as Array).has(item):
		return {"ok": false, "reason": "not_its_food"}
	if c.owner != "" and c.fed_at >= 0 and world_time - c.fed_at < int(FULL_HOURS * Daylight.HOUR_MS):
		return {"ok": false, "reason": "fed_already"}
	if not inventory(actor).remove(item, 1):
		return {"ok": false, "reason": "not_enough"}
	_touch_inventory(actor)
	var tamed := creatures.fed_by(c, actor)
	return {"ok": true, "tamed": tamed, "fed": c.fed, "of": int(tame["feeds"]), "owner": c.owner}


## Sows a seed one carries (an item that "plants" a crop) in a field: the
## crop takes the cell, sown now (its props: "planted", world ms).
func _sow(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	if not _reaches(actor, at[0], x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var item := rs(r, "item")
	var crop := String(content.get_def(item).get("plants", ""))
	if crop == "" or content.kind_of(crop) != "plant":
		return {"ok": false, "reason": "not_a_seed"}
	if inventory(actor).count(item) < 1:
		return {"ok": false, "reason": "not_carried"}
	var c := chunk(at[0], at[1], at[2])
	if not content.get_def(c.get_cell("ground", at[3], at[4])).get("farmland", false):
		return {"ok": false, "reason": "not_a_field"}
	if c.get_cell("structure", at[3], at[4]) != "" or c.get_cell("cover", at[3], at[4]) != "":
		return {"ok": false, "reason": "occupied"}
	inventory(actor).remove(item, 1)
	_touch_inventory(actor)
	c.set_cell("cover", at[3], at[4], crop)
	_set_layer_props(c, "cover", at[3], at[4], {"planted": world_time})
	_changed(chunk_key(at[0], at[1], at[2]))
	return {"ok": true}


# --- wear and repair of parts (ADR-0021) -------------------------------------------

## Whether one may hurt someone else's building (ADR-0016: a world rule apart
## from PvP). The author's default: buildings are nobody's to defend but by
## what they are made of — anyone breaks anything; a server may forbid it.
var break_others := true


## How much of a blow a part takes: the blow's damage, times what the thing
## held does to the part's material ("against") or else the part's
## "toughness" (stone: a pick goes through it slowly, an axe or a fist
## hardly at all).
func blow_on(part_def: Dictionary, weapon: Dictionary, item_def: Dictionary) -> float:
	var damage := float(weapon["damage"]) if not weapon.is_empty() else 1.0
	var against: Dictionary = item_def.get("against", {}) if not weapon.is_empty() else {}
	var material := String(part_def.get("material", ""))
	return damage * float(against.get(material, part_def.get("toughness", 1.0)))


## A blow at a part, with what one holds: one standing on a cell
## ("structure"), or a ceiling or a roof ("layer") with nothing left over it
## (ADR-0016: taken down from the top). Its damage grows; at its durability
## it breaks and half of what it cost falls there, with whatever a chest
## held. Anyone's, unless the world forbids breaking others' things.
func _strike_part(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var loc: String = at[0]
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	var layer := rs(r, "layer", "structure")
	if not layer in ["structure", "ceiling", "roof"]:
		return {"ok": false, "reason": "bad_request"}
	var why := check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := held_of(actor)
	var w: Dictionary = content.get_def(item).get("weapon", {}) if item != "" else {}
	if w.get("kind") != "melee" or rb(r, "unarmed", false):
		w = {}  # the free hand
	var reach := int((float(w.get("reach", 1.0)) + 0.8) * Movement.UNIT)
	if not _reaches(actor, loc, x, y, reach):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(loc, at[1], at[2])
	var part := c.get_cell(layer, at[3], at[4])
	var def := content.get_def(part) if part != "" else {}
	var durability := int(def.get("durability", 0))
	if part == "" or durability <= 0:
		return {"ok": false, "reason": "unbreakable"}
	var props := _layer_props(c, layer, at[3], at[4]).duplicate()
	if String(props.get("owner", "")) != actor and not break_others:
		return {"ok": false, "reason": "not_owner"}
	var above := _above(loc, c, at, layer)
	if above[0] != "":
		return {"ok": false, "reason": above[0]}
	if not combat.ready(actor, float(w.get("cooldown_ms", 500))):
		return {"ok": false, "reason": "not_ready"}
	combat.swung(actor, Vector2i(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2))
	var damage := float(props.get("damage", 0)) + blow_on(def, w, content.get_def(item) if item != "" else {})
	creatures.noise(loc, Vector2i(x, y))
	if damage < durability:
		props["damage"] = damage
		if layer == "structure":
			c.set_props(at[3], at[4], props)
		else:
			_set_layer_props(c, layer, at[3], at[4], props)
		_changed(chunk_key(loc, at[1], at[2]))
		return {"ok": true, "damage": floori(damage), "durability": durability}
	# Broken: gone, half of what it cost lies there, and what a chest held.
	var centre := Vector2i(x * Movement.UNIT + Movement.UNIT / 2, y * Movement.UNIT + Movement.UNIT / 2)
	if String(props.get("store", "")) != "":
		var box := inventory("store|" + String(props["store"]))
		for it: String in box.stacks.keys():
			place_item(loc, centre, it, int(box.stacks[it]))
			box.remove(it, int(box.stacks[it]))
		_touch_inventory("store|" + String(props["store"]))
	_take_down(loc, c, at, layer, part, above[1])
	var cost := content.structure_cost(part)
	for m: String in cost:
		var half := int(cost[m]) / 2
		if half > 0:
			place_item(loc, centre, m, half)
	return {"ok": true, "broken": part}


## Mends a damaged part (a ceiling, a roof with "layer"), anyone's
## (ADR-0016): it costs its materials in proportion to the damage (at least
## one of the first).
func _repair(actor: String, r: Dictionary) -> Dictionary:
	var at := _cell(r)
	var loc: String = at[0]
	var x := ri(r, "x", 0)
	var y := ri(r, "y", 0)
	var layer := rs(r, "layer", "structure")
	if not layer in ["structure", "ceiling", "roof"]:
		return {"ok": false, "reason": "bad_request"}
	if not _reaches(actor, loc, x, y, BUILD_REACH):
		return {"ok": false, "reason": "too_far"}
	var c := chunk(loc, at[1], at[2])
	var part := c.get_cell(layer, at[3], at[4])
	var props := _layer_props(c, layer, at[3], at[4]).duplicate()
	var damage := float(props.get("damage", 0))
	if part == "" or damage <= 0.0:
		return {"ok": false, "reason": "not_damaged"}
	var durability := maxi(1, int(content.get_def(part).get("durability", 1)))
	var cost := content.structure_cost(part)
	var need := {}
	for m: String in cost:
		need[m] = ceili(float(cost[m]) * damage / durability)
	var inv := inventory(actor)
	if not inv.has_all(need):
		return {"ok": false, "reason": "materials"}
	for m: String in need:
		if int(need[m]) > 0:
			inv.remove(m, int(need[m]))
	_touch_inventory(actor)
	props.erase("damage")
	if layer == "structure":
		c.set_props(at[3], at[4], props)
	else:
		_set_layer_props(c, layer, at[3], at[4], props)
	_changed(chunk_key(loc, at[1], at[2]))
	creatures.noise(loc, Vector2i(x, y))
	return {"ok": true, "spent": need}


## What a character holds, for others to see (ADR-0021): an item it carries,
## or "" (empty hands). Actions name the item they use themselves.
func _hold(actor: String, r: Dictionary) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	if r.has("item") and typeof(r["item"]) != TYPE_STRING:
		return {"ok": false, "reason": "bad_request"}
	var item := rs(r, "item")
	if item != "" and (content.kind_of(item) != "item" or inventory(actor).count(item) <= 0):
		present[actor]["held"] = ""  # what it meant to take is not there: empty hands, not the old thing
		return {"ok": false, "reason": "not_carried"}
	present[actor]["held"] = item
	return {"ok": true}


## Clothes leave the bag while worn; replacing them returns the old item.
## Both changes enter the same durable batch as the idempotent request result.
func _equip(actor: String, r: Dictionary, putting: bool) -> Dictionary:
	if not present.has(actor):
		return {"ok": false, "reason": "not_here"}
	if (putting and typeof(r.get("item")) != TYPE_STRING) or (not putting and typeof(r.get("slot")) != TYPE_STRING):
		return {"ok": false, "reason": "bad_request"}
	var data: Dictionary = _known_character(actor)["data"]
	var equipment: Dictionary = data.get("equipment", {})
	var item := rs(r, "item") if putting else ""
	var slot := String(content.get_def(item).get("equip_slot", "")) if putting else rs(r, "slot")
	var plan := content.get_def(String(data["appearance"]["body_plan"]))
	if slot == "" or slot in ["main_hand", "off_hand"] or not (plan.get("slots", []) as Array).has(slot):
		return {"ok": false, "reason": "not_wearable"}
	var before := String(equipment.get(slot, ""))
	var inv := inventory(actor)
	if putting:
		if not inv.remove(item, 1):
			return {"ok": false, "reason": "not_carried"}
		equipment[slot] = item
	else:
		if before == "":
			return {"ok": false, "reason": "empty_slot"}
		if room_for(actor, before) < 1:
			return {"ok": false, "reason": "full"}  # it stays on rather than falls
		equipment.erase(slot)
	if before != "":
		give(actor, before, 1)
	data["equipment"] = equipment
	_dirty_characters[actor] = true
	present[actor]["appearance"] = shown_look(data)
	_touch_inventory(actor)
	return {"ok": true}


## Worn things follow the world's existing death-drops rule too.
func drop_equipment(actor: String, until: int) -> void:
	var data: Dictionary = _known_character(actor)["data"]
	for item: String in (data.get("equipment", {}) as Dictionary).values():
		place_item(String(present[actor]["location"]), present[actor]["pos"], item, 1, actor, until)
	data["equipment"] = {}
	present[actor]["appearance"] = shown_look(data)
	_dirty_characters[actor] = true


func _transfer(actor: String, r: Dictionary) -> Dictionary:
	var to := rs(r, "to")
	var item := rs(r, "item")
	var n := ri(r, "count", 0)
	if to == "" or to == actor or n <= 0:
		return {"ok": false, "reason": "bad_request"}
	if room_for(to, item) < n:
		return {"ok": false, "reason": "full"}
	if not inventory(actor).remove(item, n):
		return {"ok": false, "reason": "not_enough"}
	inventory(to).add(item, n)
	_touch_inventory(actor)
	_touch_inventory(to)
	return {"ok": true}
