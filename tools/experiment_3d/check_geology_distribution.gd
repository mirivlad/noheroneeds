extends SceneTree
## Compare complete generated chunks, including settlement/road stamping,
## rather than just the mineral proposal. No real save is opened or written.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://build/geology/distribution")
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var report := {"old_version": 18, "new_version": SurfaceGenerator.VERSION, "worlds": {}}
	for seed_value in [2, 431, 991]:
		var plan := WorldPlan.generate(seed_value, "small", "temperate", content)
		var old := SurfaceGenerator.new(seed_value, content, plan, 18)
		var next := SurfaceGenerator.new(seed_value, content, plan)
		var chosen := {"mountains": [], "plains": []}
		var candidates: Array = range(plan.size.x * plan.size.y)
		candidates.sort_custom(func(a: int, b: int) -> bool: return hash([a, seed_value, 313]) < hash([b, seed_value, 313]))
		for k: int in candidates:
			var id: String = plan.biome_ids[plan.biomes[k]]
			var group := "mountains" if id in ["base:rocky", "base:mountains"] else ("plains" if id in ["base:meadow", "base:steppe"] else "")
			if group == "" or chosen[group].size() >= (18 if group == "mountains" else 6): continue
			var chunk := Vector2i(k % plan.size.x, k / plan.size.x) - plan.spawn
			chosen[group].append(chunk)
			if chosen["mountains"].size() == 18 and chosen["plains"].size() == 6: break
		var counts := {}
		var snapshots := {}
		for group: String in chosen:
			var before := {}
			var after := {}
			var clustered := [0, 0]
			for at: Vector2i in chosen[group]:
				var a := old.generate(at.x, at.y)
				var b := next.generate(at.x, at.y)
				if a.layer_ids("ground") != b.layer_ids("ground") or a.layer_ids("structure") != b.layer_ids("structure"):
					failures.append("terrain changed at seed %d %s" % [seed_value, at])
				for i in Chunk.CELLS:
					var x := i % Chunk.SIZE
					var y := i / Chunk.SIZE
					var ca := a.get_cell("cover", x, y)
					var cb := b.get_cell("cover", x, y)
					if ca != "" and ca not in SurfaceGenerator.MINERAL_COVER and ca != cb:
						failures.append("non-mineral resource changed at seed %d %s" % [seed_value, at * Chunk.SIZE + Vector2i(x, y)])
					for row: Array in [[ca, before], [cb, after]]:
						if row[0] in SurfaceGenerator.MINERAL_COVER: row[1][row[0]] = int(row[1].get(row[0], 0)) + 1
					if cb in SurfaceGenerator.MINERAL_COVER:
						clustered[1] += 1
						for d: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
							if x + d.x < 0 or x + d.x >= Chunk.SIZE or y + d.y < 0 or y + d.y >= Chunk.SIZE: continue
							if b.get_cell("cover", x + d.x, y + d.y) in SurfaceGenerator.MINERAL_COVER:
								clustered[0] += 1
								break
				snapshots[str(at)] = Hash.sha256(ChunkCodec.encode(b)).hex_encode()
				print("GEOLOGY_CHUNK seed=", seed_value, " group=", group, " chunk=", at)
			counts[group] = {"chunks": chosen[group].size(), "before": before, "after": after, "with_adjacent_mineral_after": clustered}
		report["worlds"][str(seed_value)] = {"counts": counts, "snapshots": snapshots}
		report["failures"] = failures
		FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
		print("GEOLOGY_WORLD seed=", seed_value, " ", JSON.stringify(counts))
	print("GEOLOGY_DISTRIBUTION_DONE failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
