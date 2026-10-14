class_name StoreWriter
extends RefCounted
## Writes batches to the world database on its own thread, each batch in one
## transaction (ADR-0005). The simulation never waits for the disk: it submits
## snapshots and later polls which batches are committed. Encoding happens here.
##
## Operation batches (chunks, inventories, processed requests) are written
## strictly in order and before any waiting state batch (entity rows only);
## the two kinds touch different tables, so this reordering is safe.
##
## The writer has its own connection; the simulation keeps another one for
## reads (WAL lets them work side by side). A failed commit is retried until
## it succeeds or the writer is stopped; last_error() tells the server meanwhile.


class Batch:
	var id := 0
	## [location, cx, cy, Chunk snapshot]
	var chunks: Array = []
	## [owner, inventory data Dictionary]
	var inventories: Array = []
	## [actor, request_id, tick, result Dictionary]
	var requests: Array = []
	## [character_id, owner, portable data Dictionary]
	var characters: Array = []
	## Things lying in the world, written with the inventories they came from:
	## [id, location, cx, cy, kind, data Dictionary]
	var items: Array = []
	## Ids of entities taken out of the world (picked up...)
	var removed_entities: Array = []
	## [id, location, cx, cy, kind, data Dictionary] — a state batch has only
	## these and world_characters
	var entities: Array = []
	## [character_id, world state Dictionary]
	var world_characters: Array = []
	## Delete processed requests older than this tick (-1: no pruning).
	var prune_before := -1


var retry_delay_ms := 500
var _store := WorldStore.new()
var _thread := Thread.new()
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _ops: Array[Batch] = []
var _state: Array[Batch] = []
var _done: Array[int] = []
var _stop := false
var _busy := false
var _next_id := 1
var _error := ""
var _busy_usec := 0


func start(db_path: String, options := {}) -> bool:
	if not _store.open(db_path, options):
		_error = _store.last_error
		return false
	_thread.start(_run)
	return true


## Returns the batch id.
func submit(batch: Batch) -> int:
	_mutex.lock()
	batch.id = _next_id
	_next_id += 1
	if batch.chunks.is_empty() and batch.inventories.is_empty() and batch.requests.is_empty() \
			and batch.characters.is_empty() and batch.items.is_empty() and batch.removed_entities.is_empty() \
			and batch.prune_before < 0:
		_state.append(batch)
	else:
		_ops.append(batch)
	_mutex.unlock()
	_wake.post()
	return batch.id


## Last commit error; empty while everything is fine.
func last_error() -> String:
	_mutex.lock()
	var e := _error
	_mutex.unlock()
	return e


## Ids of batches committed since the last call, in commit order.
func take_done() -> Array[int]:
	_mutex.lock()
	var out := _done
	_done = []
	_mutex.unlock()
	return out


## Operation batches not yet committed (what backpressure looks at).
func queued_operations() -> int:
	_mutex.lock()
	var n := _ops.size()
	_mutex.unlock()
	return n


func queued() -> int:
	_mutex.lock()
	var n := _ops.size() + _state.size() + (1 if _busy else 0)
	_mutex.unlock()
	return n


## Microseconds spent writing so far (how loaded the writer is).
func busy_usec() -> int:
	_mutex.lock()
	var n := _busy_usec
	_mutex.unlock()
	return n


## Blocks until everything submitted so far is committed (tests, shutdown).
func wait_idle() -> void:
	while queued() > 0:
		OS.delay_msec(1)


## Commits what is queued, then stops the thread and closes the connection.
func stop() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stop = true
	_mutex.unlock()
	_wake.post()
	_thread.wait_to_finish()
	_store.checkpoint()
	_store.close()


func _run() -> void:
	while true:
		_wake.wait()
		while true:
			_mutex.lock()
			if _ops.is_empty() and _state.is_empty():
				var stopping := _stop
				_mutex.unlock()
				if stopping:
					return
				break
			var queue := _ops if not _ops.is_empty() else _state
			var batch: Batch = queue[0]
			_busy = true
			_mutex.unlock()
			var t := Time.get_ticks_usec()
			while not _write(batch):
				_mutex.lock()
				var give_up := _stop
				_error = _store.last_error
				_mutex.unlock()
				if give_up:
					return
				OS.delay_msec(retry_delay_ms)
			_mutex.lock()
			queue.pop_front()
			_busy_usec += Time.get_ticks_usec() - t
			_done.append(batch.id)
			_busy = false
			_error = ""
			_mutex.unlock()


func _write(b: Batch) -> bool:
	if not _store.begin():
		return false
	var ok := true
	for c: Array in b.chunks:
		ok = ok and _store.put_chunk(c[0], c[1], c[2], ChunkCodec.encode(c[3]))
	for inv: Array in b.inventories:
		ok = ok and _store.put_inventory(inv[0], Cbor.encode(inv[1]))
	for r: Array in b.requests:
		ok = ok and _store.put_request(r[0], r[1], r[2], Cbor.encode(r[3]))
	for c: Array in b.characters:
		ok = ok and _store.put_character(c[0], c[1], Cbor.encode(c[2]))
	for e: Array in b.items:
		ok = ok and _store.put_entity(e[0], e[1], e[2], e[3], e[4], Cbor.encode(e[5]))
	for id: String in b.removed_entities:
		ok = ok and _store.delete_entity(id)
	for e: Array in b.entities:
		ok = ok and _store.put_entity(e[0], e[1], e[2], e[3], e[4], Cbor.encode(e[5]))
	for wc: Array in b.world_characters:
		ok = ok and _store.put_world_character(wc[0], Cbor.encode(wc[1]))
	if b.prune_before >= 0:
		ok = ok and _store.prune_requests(b.prune_before)
	if not ok:
		_store.rollback()
		return false
	return _store.commit()
