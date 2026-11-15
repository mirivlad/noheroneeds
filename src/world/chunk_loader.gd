class_name ChunkLoader
extends RefCounted
## Loads chunks from the store, or generates them, ahead of need on its own
## thread with its own read connection, so the simulation does not pay
## ~0.3 ms per load or a few ms per generated chunk. The simulation asks with
## request() and collects with take_ready(); a chunk it needs before the
## loader is done it loads itself (ServerWorld.chunk()).

var _store := WorldStore.new()
var _generator: SurfaceGenerator
var _underground: UndergroundGenerator
var _thread := Thread.new()
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _queue: Array = []
var _queued := {}
var _ready: Array = []
var _ready_keys := {}
var _sent_plans := {}
var _stop := false


## generator may be null (then missing surface chunks come back empty).
func start(db_path: String, generator: SurfaceGenerator, underground: UndergroundGenerator = null) -> bool:
	_underground = underground
	if not _store.open(db_path):
		return false
	_generator = generator
	if _generator:
		_generator.cancel_requested = _stopping
		_generator.settlements.cancel_requested = _stopping
	_thread.start(_run)
	return true


func request(location: String, cx: int, cy: int) -> void:
	var key := ServerWorld.chunk_key(location, cx, cy)
	_mutex.lock()
	if not _queued.has(key) and not _ready_keys.has(key):
		_queued[key] = true
		_queue.append([location, cx, cy])
		_wake.post()
	_mutex.unlock()


## [[location, cx, cy, Chunk, generated: bool, entity rows, encoded bytes, plans], ...]
## The bytes are what clients receive, so the simulation never encodes an
## unchanged chunk: stored ones come as stored, new ones are encoded here.
func take_ready(limit := -1) -> Array:
	_mutex.lock()
	var count := _ready.size() if limit < 0 else mini(limit, _ready.size())
	var out := _ready.slice(0, count)
	_ready = _ready.slice(count)
	for row: Array in out: _ready_keys.erase(ServerWorld.chunk_key(row[0], row[1], row[2]))
	_mutex.unlock()
	return out


func waiting() -> int:
	_mutex.lock()
	var n := _queued.size()
	_mutex.unlock()
	return n


func stop() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stop = true
	_mutex.unlock()
	_wake.post()
	_thread.wait_to_finish()
	_store.close()


func _run() -> void:
	while true:
		_wake.wait()
		while true:
			_mutex.lock()
			if _stop or _queue.is_empty():
				var stopping := _stop
				_mutex.unlock()
				if stopping:
					return
				break
			var r: Array = _queue.pop_front()
			_mutex.unlock()
			var data := _store.get_chunk(r[0], r[1], r[2])
			var c: Chunk = null
			var generated := false
			if not data.is_empty():
				c = ChunkCodec.decode(data)
				if r[0] == ServerWorld.SURFACE and _generator:
					# Saved cells do not need regeneration, but the simulation's
					# population/upper-floor callbacks still need their plans.
					_generator.settlements.plans_touching(r[1], r[2])
					_generator.settlements.roads_touching(r[1], r[2])
					_generator.settlements.camps.plans_touching(r[1], r[2])
					_generator.settlements.inns.plans_touching(r[1], r[2])
			elif r[0] == ServerWorld.SURFACE and _generator:
				c = _generator.generate(r[1], r[2])
				if c:
					data = ChunkCodec.encode(c)
					generated = true
			elif Levels.is_depth(r[0]) and _underground:
				c = _underground.generate(int(String(r[0]).substr(Levels.DEPTH_PREFIX.length())), r[1], r[2])
				data = ChunkCodec.encode(c)
				generated = true
			else:
				c = Chunk.new()
			var rows := _store.entities_in_chunk(r[0], r[1], r[2]) if not data.is_empty() else []
			var plans := _planning_delta() if r[0] == ServerWorld.SURFACE and _generator and not _stopping() else {}
			_mutex.lock()
			_queued.erase(ServerWorld.chunk_key(r[0], r[1], r[2]))
			if c and not _stop:
				_ready.append([r[0], r[1], r[2], c, generated, rows, data, plans])
				_ready_keys[ServerWorld.chunk_key(r[0], r[1], r[2])] = true
			_mutex.unlock()


## Only new entries are copied, on the worker, before ownership crosses
## threads. The main thread never touches the worker's mutable dictionaries.
func _planning_delta() -> Dictionary:
	var out := {}
	var caches := _generator.settlements.planning_cache()
	for family: String in caches:
		var cache: Dictionary = caches[family]
		var sent: Dictionary = _sent_plans.get_or_add(family, {})
		if cache.size() < sent.size(): sent.clear()  # the generator evicted its cache
		var added := {}
		for key: String in cache:
			if sent.has(key): continue
			added[key] = cache[key].duplicate(true)
			sent[key] = true
		if not added.is_empty(): out[family] = added
	return out


func _stopping() -> bool:
	_mutex.lock()
	var stopping := _stop
	_mutex.unlock()
	return stopping
