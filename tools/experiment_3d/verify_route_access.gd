extends SceneTree
## Actual saved chunks: roads, the guaranteed cave and nearby gatherable
## resources on three worlds. Every database is a new disposable fixture.
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://build/routes/access")
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var report := {"worlds": {}, "sources": {}}
	for path: String in ["src/world/surface_generator.gd", "src/world/settlements.gd", "src/world/bridge_routes.gd", "content/base/terrain.json"]:
		report.sources[path] = FileAccess.get_sha256("res://" + path)
	for seed_value in [2, 431, 991]:
		var plan := WorldPlan.generate(seed_value, "small", "temperate", content)
		var old := SurfaceGenerator.new(seed_value, content, plan, 19)
		var folder := output.path_join(str(seed_value) + "-" + str(Time.get_ticks_usec()))
		DirAccess.make_dir_recursive_absolute(folder)
		var world := ServerWorld.open(folder.path_join("world.db"), content, {"world_plan": plan.to_dict(), "require_planned": true})
		if world == null:
			failures.append("cannot open seed %d: %s" % [seed_value, ServerWorld.open_error])
			continue
		var generator := world.generator
		var old_villages := 0
		var old_canonical_villages := 0
		var villages := 0
		var roads := []
		var seen := {}
		for y in range(-1, 2):
			for x in range(-1, 2):
				for village: Dictionary in old.settlements.villages(0, x, y):
					old_villages += 1
					if (village["cells"] as Dictionary).keys().all(func(at: Vector2i) -> bool: return world.topology.canonical_cell(at) == at): old_canonical_villages += 1
				for village: Dictionary in generator.settlements.villages(0, x, y):
					villages += 1
					if not (village["cells"] as Dictionary).keys().all(func(at: Vector2i) -> bool: return world.topology.canonical_cell(at) == at): failures.append("new settlement crosses the stored planet boundary on seed %d" % seed_value)
				for road: Dictionary in generator.settlements.roads_of(0, x, y):
					if seen.has(road["id"]): continue
					seen[road["id"]] = true
					roads.append(road)
		var checked := 0
		var blocked := []
		# Two complete roads, including their materialized width and endpoints.
		for road: Dictionary in roads.slice(0, 2):
			for at: Vector2i in road["cells"]:
				var chunk := world.chunk("surface", at.x >> 5, at.y >> 5)
				checked += 1
				if Terrain.is_solid(chunk, at.x & 31, at.y & 31, content): blocked.append([at.x, at.y])
		if villages == 0 or roads.is_empty(): failures.append("seed %d has no settlement route in nine tested districts" % seed_value)
		if not blocked.is_empty(): failures.append("seed %d has %d blocked materialized road cells" % [seed_value, blocked.size()])
		# Connected walkable component around the ordinary spawn. Solid
		# resources are reachable when a cardinal neighbour is in it.
		var box := Rect2i(-32, -32, 96, 96)
		var reachable := {Vector2i.ZERO: true}
		var queue: Array[Vector2i] = [Vector2i.ZERO]
		var cursor := 0
		while cursor < queue.size():
			var at := queue[cursor]
			cursor += 1
			for d: Vector2i in DIRECTIONS:
				var next := at + d
				if reachable.has(next) or not box.has_point(next): continue
				var chunk := world.chunk("surface", next.x >> 5, next.y >> 5)
				if not Terrain.is_solid(chunk, next.x & 31, next.y & 31, content):
					reachable[next] = true
					queue.append(next)
		var cave := world._spawn_way()
		var cave_reached := reachable.has(cave) or DIRECTIONS.any(func(d: Vector2i) -> bool: return reachable.has(cave + d))
		if not cave_reached: failures.append("seed %d's guaranteed cave is unreachable in the spawn area" % seed_value)
		var resources := {}
		for y in range(box.position.y, box.end.y):
			for x in range(box.position.x, box.end.x):
				var chunk := world.chunk("surface", x >> 5, y >> 5)
				var id := chunk.get_cell("cover", x & 31, y & 31)
				if not content.get_def(id).has("gather"): continue
				var at := Vector2i(x, y)
				if reachable.has(at) or DIRECTIONS.any(func(d: Vector2i) -> bool: return reachable.has(at + d)):
					resources[id] = int(resources.get(id, 0)) + 1
		if resources.size() < 3: failures.append("seed %d lacks three reachable gatherable kinds near spawn" % seed_value)
		report.worlds[str(seed_value)] = {"villages19_raw": old_villages, "villages19_canonical": old_canonical_villages, "villages20": villages, "roads20": roads.size(), "roads_materialized": mini(2, roads.size()), "road_cells_checked": checked, "blocked_road_cells": blocked, "reachable_spawn_cells": reachable.size(), "cave": [cave.x, cave.y], "cave_reached": cave_reached, "reachable_resource_counts": resources}
		world.close()
		report["failures"] = failures
		FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
		print("ROUTE_ACCESS seed=", seed_value, " ", JSON.stringify(report.worlds[str(seed_value)]))
	print("ROUTE_ACCESS_DONE failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
