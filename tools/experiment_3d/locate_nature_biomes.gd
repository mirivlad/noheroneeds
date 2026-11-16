extends SceneTree
## Locate actual surface-biome samples and natural river banks on three seeds.
## Proposals use coarse climate; final acceptance uses the surface sampler.
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://build/nature-final/biome-locations.json")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var content := ContentRegistry.load_packs(["res://content/base"])
	var report := {}
	for seed_value in [2, 431, 991]:
		var plan := WorldPlan.generate(seed_value, "small", "temperate", content)
		var land := SurfaceGenerator.new(seed_value, content, plan)
		var points := {}
		var river_bank := []
		var candidates: Array = range(plan.size.x * plan.size.y)
		candidates.sort_custom(func(a: int, b: int) -> bool:
			return (Vector2i(a % plan.size.x, a / plan.size.x) - plan.spawn).length_squared() < (Vector2i(b % plan.size.x, b / plan.size.x) - plan.spawn).length_squared())
		for k: int in candidates:
			var id: String = plan.biome_ids[plan.biomes[k]]
			if id not in ["base:forest", "base:meadow", "base:steppe", "base:mountains", "base:swamp"] or points.has(id): continue
			var centre := (Vector2i(k % plan.size.x, k / plan.size.x) - plan.spawn) * Chunk.SIZE
			for offset: Vector2i in [Vector2i(16, 16),Vector2i(8, 8),Vector2i(24, 24),Vector2i(8, 24),Vector2i(24, 8)]:
				var at := centre + offset
				var sample := land.land_at(at.x, at.y, false)
				if sample.what != "land" or land.biome_id_at(at.x, at.y) != id: continue
				points[id] = [at.x, at.y]
				break
			if points.size() == 5: break
		for k: int in candidates:
			if plan.river[k] <= 0: continue
			var centre := (Vector2i(k % plan.size.x, k / plan.size.x) - plan.spawn) * Chunk.SIZE
			for y in range(-12, 45, 4):
				for x in range(-12, 45, 4):
					var at := centre + Vector2i(x, y)
					var sample := land.land_at(at.x, at.y, false)
					if sample.what != "land" or float(land._river_near(at.x, at.y)[0]) >= 9: continue
					if river_bank.is_empty(): river_bank = [at.x, at.y]
					if land.biome_ids[int(sample.biome)] == "base:swamp":
						points["base:swamp"] = [at.x, at.y]
						break
				if points.has("base:swamp"): break
			if points.has("base:swamp"): break
		points["river_bank"] = river_bank
		report[str(seed_value)] = {"size": [plan.size.x,plan.size.y], "points":points}
		print("BIOME_LOCATIONS ",seed_value," ",JSON.stringify(points))
	FileAccess.open(output,FileAccess.WRITE).store_string(JSON.stringify(report,"  "))
	quit()
