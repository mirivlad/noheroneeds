extends SceneTree
## Repeat material costing of the same completed, saved house. This measures
## construction CPU work only, not frame rate or the whole server tick.
## Run against a disposable copy of a closed evidence world's SQLite file.


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var db := ""
	var output := ""
	var village := "base:village@0,0#0"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--world="): db = arg.trim_prefix("--world=")
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--village="): village = arg.trim_prefix("--village=")
	if db == "" or output == "" or not FileAccess.file_exists(db):
		printerr("Pass --world=<disposable saved world copy> and --out=<JSON>")
		quit(1)
		return
	var content := ContentRegistry.load_packs(["res://content/base"])
	var world := ServerWorld.open(db, content)
	if world == null:
		printerr(ServerWorld.open_error)
		quit(1)
		return
	var state := world.settlement_life.state(village)
	if (state["homes"] as Array).is_empty():
		printerr("The saved fixture needs a completed settlement house")
		world.close()
		quit(1)
		return
	var home: Dictionary = state["homes"][0]
	var cells := {}
	var upper := {}
	for row: Array in home["cells"]:
		cells[Vector2i(int(row[0]), int(row[1]))] = row[2]
	for row: Array in home["upper"]:
		upper[Vector2i(int(row[0]), int(row[1]))] = row[2]
	var expected: Dictionary = home["cost"]
	var fingerprint := HashingContext.new()
	fingerprint.start(HashingContext.HASH_SHA256)
	fingerprint.update(Cbor.encode([home["cells"], home["upper"], expected]))
	var input_sha := fingerprint.finish().hex_encode()
	var correct := true
	for i in 20:
		correct = world.settlement_life._cost(cells, upper) == expected and correct
	var samples: Array[float] = []
	for batch in 9:
		var began := Time.get_ticks_usec()
		for i in 50:
			correct = world.settlement_life._cost(cells, upper) == expected and correct
		samples.append((Time.get_ticks_usec() - began) / 50000.0)
	var sorted := samples.duplicate()
	sorted.sort()
	var result := {"metric": "settlement.house_material_cost", "unit": "ms", "statistic": "median", "median": sorted[4],
		"samples_ms_per_call": samples, "warmup_calls": 20, "calls_per_sample": 50,
		"correct": correct, "input_sha256": input_sha, "expected_cost": expected,
		"cells": cells.size(), "upper_cells": upper.size(), "engine": Engine.get_version_info()["string"],
		"processor": OS.get_processor_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"scope": "CPU material costing of one saved house; no FPS or full-server latency claim",
		"sources": {"src/server/settlement_life.gd": FileAccess.get_sha256("res://src/server/settlement_life.gd"),
			"tools/bench_settlement_cost.gd": FileAccess.get_sha256("res://tools/bench_settlement_cost.gd"),
			"content/base/structures.json": FileAccess.get_sha256("res://content/base/structures.json"),
			"content/base/recipes.json": FileAccess.get_sha256("res://content/base/recipes.json")}}
	FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	print("COST_BENCH ", JSON.stringify(result))
	world.close()
	Art.clear()
	quit(0 if correct else 1)
