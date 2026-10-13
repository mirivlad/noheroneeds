class_name ChunkLoader
extends RefCounted
## Loads chunks from the store, or generates them, ahead of need on its own
## thread with its own read connection, so the simulation does not pay
## ~0.3 ms per load or a few ms per generated chunk. The simulation asks with
## request() and collects with take_ready(); a chunk it needs before the
## loader is done it loads itself (ServerWorld.chunk()).

var _store := WorldStore.new()
var _generator: SurfaceGenerator
var _thread := Thread.new()
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _queue: Array = []
var _queued := {}
var _ready: Array = []
var _stop := false


## generator may be null (then missing surface chunks come back empty).
func start(db_path: String, generator: SurfaceGenerator) -> bool:
	if not _store.open(db_path):
		return false
	_generator = generator
	_thread.start(_run)
	return true


func request(location: String, cx: int, cy: int) -> void:
	var key := ServerWorld.chunk_key(location, cx, cy)
	_mutex.lock()
	if not _queued.has(key):
		_queued[key] = true
		_queue.append([location, cx, cy])
		_wake.post()
	_mutex.unlock()


## [[location, cx, cy, Chunk, generated: bool], ...]
func take_ready() -> Array:
	_mutex.lock()
	var out := _ready
	_ready = []
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
			elif r[0] == ServerWorld.SURFACE and _generator:
				c = _generator.generate(r[1], r[2])
				generated = true
			else:
				c = Chunk.new()
			_mutex.lock()
			_queued.erase(ServerWorld.chunk_key(r[0], r[1], r[2]))
			if c:
				_ready.append([r[0], r[1], r[2], c, generated])
			_mutex.unlock()
