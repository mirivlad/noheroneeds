extends TestCase

class NoPlanning extends Settlements:
	var searches := 0
	func _cluster(_k: int, _dx: int, _dy: int) -> Array:
		searches += 1
		return []

class CancellableSurface extends SurfaceGenerator:
	var entered := Semaphore.new()
	var saw_cancel := false
	func generate(_cx: int, _cy: int) -> Chunk:
		entered.post()
		while not cancel_requested.call(): OS.delay_msec(1)
		saw_cancel = true
		return null

func test_prepared_plans_are_owned_by_receiver_and_avoid_foreground_generation() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var worker := SurfaceGenerator.new(4, content)
	var source := Settlements.new(4, content, func(_x: int, _y: int) -> bool: return false, 8)
	worker.settlements = source
	var expected := source.villages(0, 0, 0)
	check(not expected.is_empty(), "there are actual generated plans to transfer")
	var loader := ChunkLoader.new()
	loader._generator = worker
	var target := NoPlanning.new(4, content, func(_x: int, _y: int) -> bool: return false, 8)
	target.accept_plans(loader._planning_delta())
	eq(target.villages(0, 0, 0), expected, "same geometry after the worker handoff")
	eq(target.searches, 0, "arrival callbacks do not regenerate the cluster")
	if not expected.is_empty():
		target.villages(0, 0, 0)[0]["ownership_probe"] = true
		check(not expected[0].has("ownership_probe"), "receiver changes cannot mutate the worker's cache")
	eq(loader._planning_delta(), {}, "unchanged plans are not copied for every subsequent chunk")

func test_ready_queue_is_bounded_without_duplicate_requests() -> void:
	var loader := ChunkLoader.new()
	for x in 3:
		loader._ready.append(["surface", x, 0, Chunk.new(), false, [], PackedByteArray(), {}])
		loader._ready_keys[ServerWorld.chunk_key("surface", x, 0)] = true
	var first := loader.take_ready(1)
	eq(first.size(), 1, "one callback batch stays within its budget")
	loader.request("surface", 1, 0)
	eq(loader._queue.size(), 0, "a finished chunk waiting for adoption is not generated twice")
	var rest := loader.take_ready()
	eq(rest.size(), 2, "the public unbounded collection still returns all remaining chunks")
	eq([first[0][1], rest[0][1], rest[1][1]], [0, 1, 2], "ready chunks keep their order")
	check(loader._ready_keys.is_empty(), "taken chunks leave the ready-key guard")

func test_stopping_the_loader_cancels_an_in_progress_chunk() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("cancel.db")
	var store := WorldStore.new()
	check(store.open(path), "a disposable database opens")
	store.close()
	var source := CancellableSurface.new(4, content)
	var loader := ChunkLoader.new()
	if not check(loader.start(path, source), "the loader starts"): return
	loader.request("surface", 0, 0)
	source.entered.wait()
	loader.stop()
	check(source.saw_cancel, "stop reaches the running generator")
	check(not loader._thread.is_started(), "the worker is joined before its store is closed")
	eq(loader.take_ready(), [], "an aborted chunk is never delivered")

func test_cancellation_never_publishes_a_partial_cluster() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var source := SurfaceGenerator.new(903, content)
	var probes := [0]
	var cancel := func() -> bool:
		probes[0] += 1
		return probes[0] > 50
	source.cancel_requested = cancel
	source.settlements.cancel_requested = cancel
	source.settlements._shared_key = "cancel-probe-" + str(OS.get_process_id())
	eq(source.settlements.villages(0, 0, 0), [], "an interrupted search is not a valid cluster")
	check(source.settlements._villages.is_empty(), "no partial local cache")
	check(not Settlements._shared_clusters.has(source.settlements._shared_key + "|0|0|0"), "no partial shared cache")
	check(source.generate(0, 0) == null, "a cancelled chunk is not returned as complete")

class CancelledTowns extends Settlements:
	var road_queries := 0
	func villages(_k: int, _dx: int, _dy: int) -> Array:
		return []
	func roads_of(_k: int, _dx: int, _dy: int) -> Array:
		road_queries += 1
		var path := []
		for x in 240: path.append(Vector2i(x, 0))
		return [{"path": path}]

func test_inn_search_stops_when_cancellation_removes_its_villages() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var source := CancelledTowns.new(4, content, func(_x: int, _y: int) -> bool: return false, 8)
	eq(source.inns._make(0, 0, 0), [], "cancelled towns never leave an inn with no nearest village")
	eq(source.road_queries, 0, "cancellation does not begin more road work")
