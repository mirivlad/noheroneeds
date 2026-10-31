extends TestCase


func test_plan_round_trip_and_validation() -> void:
	var original := WorldPlan.generate(431, "small", "temperate")
	var restored := WorldPlan.from_dict(original.to_dict())
	check(restored != null, "the saved map is readable")
	eq(restored.to_dict(), original.to_dict(), "all generated data survives storage")
	eq(WorldPlan.generate(431, "small", "temperate").fields, original.fields, "generation is deterministic")
	var broken := original.to_dict()
	broken["fields"] = ""
	check(WorldPlan.from_dict(broken) == null, "truncated maps are rejected")
	broken = original.to_dict()
	var invalid := original.downstream.duplicate()
	invalid[0] = invalid.size()
	broken["downstream"] = Marshalls.raw_to_base64(invalid.to_byte_array())
	check(WorldPlan.from_dict(broken) == null, "out-of-range drainage is rejected")
	original.seed_value = 9007199254740993
	var decoded: Variant = JSON.parse_string(JSON.stringify(original.to_dict()))
	eq(WorldPlan.from_dict(decoded).seed_value, original.seed_value, "64-bit seed survives JSON without precision loss")


func test_presets_climate_and_boundaries() -> void:
	var flat := WorldPlan.generate(19, "single_continent", "temperate")
	check(flat.value(0, Vector2i(-1, 0)) < 0.0, "outside the continent map is ocean")
	var cold := WorldPlan.generate(19, "small", "cold")
	var hot := WorldPlan.generate(19, "small", "hot")
	check(cold.size != WorldPlan.PRESETS["large"], "planet sizes differ")
	var at := Vector2i(30, 30)
	eq(cold.value(0, at), cold.value(0, at + Vector2i(cold.size.x, 0)), "longitude wraps")
	eq(cold.value(0, Vector2i(10, -1)), cold.value(0, Vector2i(10 + cold.size.x / 2, 0)), "north pole reverses latitude and longitude")
	eq(cold.value(0, Vector2i(10, cold.size.y)), cold.value(0, Vector2i(10 + cold.size.x / 2, cold.size.y - 1)), "south pole reverses latitude and longitude")
	eq(cold.sample(0, Vector2i.ZERO), cold.value(0, cold.spawn), "world origin samples the stored spawn point")
	check(hot.value(1, at) > cold.value(1, at), "climate changes warmth")
	eq(hot.value(0, at), cold.value(0, at), "climate does not move the coast")


func test_continent_is_one_landmass_surrounded_by_sea() -> void:
	for seed_number in [0, 1, 19, 431, 10000]:
		var plan := WorldPlan.generate(seed_number, "single_continent", "temperate")
		var land := {}
		for y in plan.size.y:
			for x in plan.size.x:
				var p := Vector2i(x, y)
				if plan.value(0, p) > 0.0:
					land[p] = true
		check(land.has(plan.spawn), "spawn is on land")
		var queue: Array[Vector2i] = [plan.spawn]
		land.erase(plan.spawn)
		var i := 0
		while i < queue.size():
			var p := queue[i]
			i += 1
			for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var neighbor := p + d
				if land.erase(neighbor):
					queue.append(neighbor)
		eq(land.size(), 0, "all land joins the continent for seed %d" % seed_number)
		for x in plan.size.x:
			check(plan.value(0, Vector2i(x, 0)) < 0.0 and plan.value(0, Vector2i(x, plan.size.y - 1)) < 0.0, "north and south are sea")
		for y in plan.size.y:
			check(plan.value(0, Vector2i(0, y)) < 0.0 and plan.value(0, Vector2i(plan.size.x - 1, y)) < 0.0, "east and west are sea")


## The land's connected masses of a planet, largest first, in coarse points.
## The wrap is the planet's own: a mass across the seam or a pole is one mass.
func _masses(plan: WorldPlan) -> Array[int]:
	var land := {}
	for y in plan.size.y:
		for x in plan.size.x:
			if plan.value(0, Vector2i(x, y)) > 0.0:
				land[Vector2i(x, y)] = true
	var out: Array[int] = []
	while not land.is_empty():
		var start: Vector2i = land.keys()[0]
		land.erase(start)
		var todo: Array[Vector2i] = [start]
		var size := 0
		while not todo.is_empty():
			var p: Vector2i = todo.pop_back()
			size += 1
			for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var q := p + d
				q.y = posmod(q.y, plan.size.y * 2)
				if q.y >= plan.size.y:
					q.y = plan.size.y * 2 - 1 - q.y
					q.x += plan.size.x / 2
				q.x = posmod(q.x, plan.size.x)
				if land.erase(q):
					todo.append(q)
		out.append(size)
	out.sort()
	out.reverse()
	return out


func test_planet_presets_are_continents_not_archipelagos() -> void:
	var plans := {}
	for preset_id: String in ["small", "medium", "large", "huge"]:
		plans[preset_id] = WorldPlan.generate(431, preset_id, "temperate")
	var mains := {}
	for preset_id: String in ["small", "medium", "large", "huge"]:
		var plan: WorldPlan = plans[preset_id]
		var masses := _masses(plan)
		var land := 0
		for mass in masses:
			land += mass
		var rules: Dictionary = WorldPlan.LANDS[preset_id]
		check(not masses.is_empty(), "%s has land" % preset_id)
		# Small coastal fragments and island arcs are legitimate. Count their
		# area, rather than treating a one-point islet as a continent.
		var main_area := 0
		var major_count := 0
		for mass in masses:
			if mass >= land * 0.02:
				major_count += 1
				main_area += mass
		check(major_count <= int(rules["continents"]) + 2,
			"%s has %d major landmasses" % [preset_id, major_count])
		check(float(main_area) / land >= 0.90,
			"%s keeps at least 90%% of land in major masses: %s" % [preset_id, masses])
		# The world is continents, not an archipelago. With six continents no
		# single mass has to be dominant, but one still holds at least a sixth
		# of the land; a scatter of isles would not.
		check(float(masses[0]) / float(land) >= 0.16,
			"%s's largest mass is %.0f%% of its land" % [preset_id, 100.0 * masses[0] / land])
		# The land covers about the share the preset promises (the coast detail
		# bends it a little but does not add isles).
		var share := float(land) / float(plan.size.x * plan.size.y)
		check(absf(share - float(rules["share"])) < 0.05,
			"%s's land share is %.3f, near %.3f" % [preset_id, share, float(rules["share"])])
		# The mean main mass (the preset's continents), in points.
		var main := 0
		var top := mini(int(rules["continents"]), masses.size())
		for i in top:
			main += masses[i]
		mains[preset_id] = float(main) / float(top)
	# Bigger planets get bigger continents, not more and smaller islands.
	check(mains["medium"] > mains["small"], "medium's main masses are larger than small's: %s" % mains)
	check(mains["large"] > mains["medium"], "large's are larger than medium's: %s" % mains)
	check(mains["huge"] > mains["large"], "huge's are larger than large's: %s" % mains)
	# The caption tells the presets apart before one plays, not only by size.
	eq(WorldPreview.describe(WorldPlan.generate(431, "single_continent", "temperate")),
		"Один материк в бесконечном океане", "a continent is named as one")
	var said := {"Один материк в бесконечном океане": true}
	for preset_id: String in ["small", "medium", "large", "huge"]:
		var caption := WorldPreview.describe(plans[preset_id])
		var rules: Dictionary = WorldPlan.LANDS[preset_id]
		check(caption.contains(str(int(rules["continents"]))), "%s's caption names its continents: %s" % [preset_id, caption])
		check(caption.contains(str(int(rules["isles"]))), "%s's caption names its isles: %s" % [preset_id, caption])
		check(not said.has(caption), "every preset's caption is its own: %s" % caption)
		said[caption] = true


func test_planet_seeds_keep_land_share_ocean_poles_and_varied_masses() -> void:
	# The approved shape sample: every seed must keep the preset's land share,
	# leave both poles under the polar sea (a polar cap wraps the whole map into
	# one band), and still be made of a few unequal continents, not isles.
	var seeds := [7, 19, 42, 73, 108, 256, 431, 777, 1024, 2026, 4099, 9001]
	var rules: Dictionary = WorldPlan.LANDS["medium"]
	for seed: int in seeds:
		var plan := WorldPlan.generate(seed, "medium", "temperate")
		check(plan != null, "seed %d generates a planet" % seed)
		if plan == null:
			continue
		var land := 0
		for y in plan.size.y:
			for x in plan.size.x:
				if plan.value(0, Vector2i(x, y)) > 0.0:
					land += 1
		var share := float(land) / float(plan.size.x * plan.size.y)
		check(absf(share - float(rules["share"])) < 0.04,
			"seed %d keeps its land share: %.3f" % [seed, share])
		var polar := 0
		for x in plan.size.x:
			if plan.value(0, Vector2i(x, 0)) > 0.0:
				polar += 1
			if plan.value(0, Vector2i(x, plan.size.y - 1)) > 0.0:
				polar += 1
		check(polar == 0, "seed %d leaves both poles under the polar sea" % seed)
		var masses := _masses(plan)
		var major := 0
		for mass in masses:
			if mass >= land * 0.02:
				major += 1
		check(major >= 2, "seed %d has more than one major mass" % seed)
		check(major <= int(rules["continents"]) + 2,
			"seed %d has %d major masses" % [seed, major])
		var largest := 0.0 if masses.is_empty() else float(masses[0]) / float(land)
		check(largest >= 0.16, "seed %d's largest mass is %.0f%%" % [seed, 100.0 * largest])


func test_tectonic_boundaries_raise_collision_belts_and_lower_rifts() -> void:
	var warp := FastNoiseLite.new()
	var coast := FastNoiseLite.new()
	var fine := FastNoiseLite.new()
	for noise in [warp, coast, fine]:
		noise.frequency = 1.0
	var a := Vector3(1.0, 0.0, -0.5).normalized()
	var b := Vector3(1.0, 0.0, 0.5).normalized()
	var plates := [
		{"at": a, "vel": Vector3.FORWARD, "weight": 1.0, "buoyancy": 0.6, "cont": true},
		{"at": b, "vel": Vector3.BACK, "weight": 1.0, "buoyancy": 0.6, "cont": true},
		{"at": Vector3.LEFT, "vel": Vector3.ZERO, "weight": 1.0, "buoyancy": -0.5, "cont": false},
	]
	# The belt is made of crust, so the collision has to happen on a terrane:
	# a plate boundary in the open ocean raises no mountains. Two continents
	# meet at the suture, one per plate, so their margins reach the seam.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var terranes := [
		WorldPlan._terrane(rng, a, 1.15, 0.8, 9, 0),
		WorldPlan._terrane(rng, b, 1.15, 0.8, 9, 1),
	]
	var model := {
		"plates": plates, "terranes": terranes, "basins": [], "welds": [],
		"sutures": {Vector2i(0, 1): true}, "sea_level": 0.0,
	}
	var collision_sum := 0.0
	var rift_sum := 0.0
	var collision_height := 0.0
	var rift_height := 0.0
	for direction in [-1.0, 1.0]:
		plates[0]["vel"] = Vector3(0, 0, direction)
		plates[1]["vel"] = Vector3(0, 0, -direction)
		for i in 31:
			var angle := (float(i) - 15.0) * 0.02
			var point := Vector3(cos(angle), 0, sin(angle))
			var result := WorldPlan._tectonic_relief(model, point, warp, coast, fine)
			if direction > 0.0:
				collision_sum += result.y
				collision_height += result.x
			else:
				rift_sum += result.z
				rift_height += result.x
	check(collision_sum > 0.5, "convergence creates an orogenic belt")
	check(rift_sum > 0.5, "divergence creates a rift belt")
	check(collision_height > rift_height, "collision uplifts the same crust that divergence lowers")
	# A full turn in longitude and every longitude at a pole identify the same
	# direction: the generator has no map-edge special cases or polar cutout.
	for i in 16:
		var angle := float(i) * TAU / 16.0
		var point := Vector3(cos(angle), 0.2, sin(angle)).normalized()
		var again := Vector3(cos(angle + TAU), 0.2, sin(angle + TAU)).normalized()
		var first := WorldPlan._tectonic_relief(model, point, warp, coast, fine)
		var second := WorldPlan._tectonic_relief(model, again, warp, coast, fine)
		check(first.distance_to(second) < 0.0001, "continuous tectonic field closes longitude")
	check(is_finite(WorldPlan._tectonic_relief(model, Vector3.UP, warp, coast, fine).x), "north pole is finite")
	check(is_finite(WorldPlan._tectonic_relief(model, Vector3.DOWN, warp, coast, fine).x), "south pole is finite")


func test_global_drainage_joins_oceans_and_survives_serialization() -> void:
	for preset_id in ["single_continent", "small"]:
		var plan := WorldPlan.generate(431, preset_id, "temperate")
		var restored := WorldPlan.from_dict(plan.to_dict())
		var count := plan.size.x * plan.size.y
		var state := PackedByteArray()
		state.resize(count)
		var river_count := 0
		var lake_count := 0
		for k in count:
			if plan.fields[k * 3] < 128:
				state[k] = 2
			river_count += 1 if plan.river[k] > 0.0 else 0
			lake_count += 1 if plan.lake[k] > 0.0 else 0
		for k in count:
			if state[k] == 2:
				continue
			var path := PackedInt32Array()
			var current := k
			while current >= 0 and state[current] == 0:
				state[current] = 1
				path.append(current)
				current = plan.downstream[current]
			check(current >= 0 and state[current] == 2, "each drainage path reaches an ocean without a cycle")
			for seen in path:
				state[seen] = 2
		check(river_count > 0 and lake_count > 0, "%s includes rivers and lakes" % preset_id)
		eq(restored.downstream, plan.downstream, "drainage is saved")
		eq(restored.river, plan.river, "rivers are saved")
		eq(restored.lake, plan.lake, "lakes are saved")


func test_huge_world_is_global_and_bounded() -> void:
	var plan := WorldPlan.generate(22, "huge", "cold")
	eq(plan.fields.size(), plan.size.x * plan.size.y * 3, "one finite coarse map")
	eq(plan.downstream.size(), plan.size.x * plan.size.y, "drainage covers the whole map")
	eq(WorldHydrology.index_at(plan, Vector2i(-1, 10)), WorldHydrology.index_at(plan, Vector2i(plan.size.x - 1, 10)), "drainage crosses the longitude seam")
	eq(WorldHydrology.index_at(plan, Vector2i(10, -1)), WorldHydrology.index_at(plan, Vector2i(10 + plan.size.x / 2, 0)), "drainage crosses the pole")


func test_surface_and_geology_use_saved_plan() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var plan := WorldPlan.generate(431, "small", "temperate")
	var saved := WorldPlan.from_dict(plan.to_dict())
	var surface := SurfaceGenerator.new(plan.seed_value, content, saved)
	check(surface.geography is PlannedGeography, "surface uses the global plan")
	var point := Vector2i(100, -200)
	eq(surface.geography.sample(Geography.HEIGHT, point.x, point.y), saved.sample(0, point), "height comes from the stored map")
	eq(surface.geography.climate_at(point.x, point.y), Vector2(saved.sample(1, point), saved.sample(2, point)), "biome climate comes from the stored map")
	var underground := UndergroundGenerator.new(plan.seed_value, content)
	underground.geography = surface.geography
	eq(underground.geography.sample(Geography.HEIGHT, point.x, point.y), saved.sample(0, point), "geology sees the same relief")
	var again := SurfaceGenerator.new(plan.seed_value, content, plan)
	eq(ChunkCodec.encode(surface.generate(2, 3)), ChunkCodec.encode(again.generate(2, 3)), "saved and original plans generate the same detail")


func test_server_persists_the_exact_plan_and_modified_chunk() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var plan := WorldPlan.generate(431, "small", "cold")
	var world := ServerWorld.open(path, content, {"world_plan": plan.to_dict()})
	check(world != null, "planned world opens")
	var chunk := world.chunk("surface", 2, 3)
	chunk.set_cell("ground", 1, 1, "base:stone")
	world.mark_chunk_dirty("surface", 2, 3)
	world.close()
	var other := WorldPlan.generate(999, "small", "hot")
	world = ServerWorld.open(path, content, {"world_plan": other.to_dict()})
	check(world != null, "planned world reopens")
	var restored := (world.generator.geography as PlannedGeography).plan
	eq(restored.to_dict(), plan.to_dict(), "opening ignores a new plan and loads the saved one")
	eq(world.chunk("surface", 2, 3).get_cell("ground", 1, 1), "base:stone", "materialized modifications survive")
	world.close()


func test_a_planned_world_is_created_from_seed_preset_and_climate() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var world := ServerWorld.open(path, content,
		{"require_planned": true, "seed": 431, "preset": "medium", "climate": "cold"})
	check(world != null, "a planned world is created from the options")
	if world == null:
		return
	var plan := (world.generator.geography as PlannedGeography).plan
	eq(plan.seed_value, 431, "the requested seed")
	eq(plan.preset, "medium", "the requested preset")
	eq(plan.climate, "cold", "the requested climate")
	world.close()


func test_a_planned_world_refuses_an_unknown_preset_without_writing_format_6() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var world := ServerWorld.open(path, content,
		{"require_planned": true, "seed": 431, "preset": "no_such_planet"})
	check(world == null, "an unknown preset is refused")
	check(ServerWorld.open_error.contains("пресет"), "the error names the preset: " + ServerWorld.open_error)
	var store := WorldStore.new()
	check(store.open(path), "the failed attempt left a store to inspect")
	eq(store.read_meta("seed"), "", "no old-format world was written behind the failure")
	store.close()


func test_corrupt_plan_is_refused_without_overwriting_world() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var plan := WorldPlan.generate(55, "small", "temperate")
	var world := ServerWorld.open(path, content, {"world_plan": plan.to_dict()})
	world.close()
	var store := WorldStore.new()
	store.open(path)
	store.write_meta("world_plan", "broken")
	store.close()
	check(ServerWorld.open(path, content) == null, "a damaged map is refused")
	check(ServerWorld.open_error.contains("повреждён"), "the error explains the damaged plan")
	store = WorldStore.new()
	store.open(path)
	eq(store.read_meta("world_plan"), "broken", "opening does not regenerate or overwrite a damaged plan")
	store.close()


func test_canonical_world_coordinates_close_the_seam_and_poles() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	for scale: int in [1, Chunk.SIZE, Chunk.SIZE * Movement.UNIT]:
		var first := -plan.spawn * scale
		var width := plan.size.x * scale
		var height := plan.size.y * scale
		var inside := first + Vector2i(5, 7)
		eq(plan.canonical_point(inside + Vector2i(width, 0), scale), inside, "east and west identify the same coordinate")
		eq(plan.canonical_point(first + Vector2i(5, -1), scale), first + Vector2i(5 + width / 2, 0), "crossing the north pole reverses y and turns longitude")
		eq(plan.canonical_point(first + Vector2i(5, height), scale), first + Vector2i(5 + width / 2, height - 1), "crossing the south pole reverses y and turns longitude")
		var far := inside + Vector2i(width * 5, height * 4)
		eq(plan.canonical_point(far, scale), inside, "multiple circuits canonicalize")
		eq(plan.canonical_point(plan.canonical_point(far, scale), scale), inside, "canonicalization is idempotent")
	var flat := WorldPlan.generate(431, "single_continent", "cold")
	eq(flat.canonical_point(Vector2i(-99999, 99999), Chunk.SIZE), Vector2i(-99999, 99999), "the continental ocean is not wrapped")


func test_old_world_is_refused_before_any_migration() -> void:
	var path := tmp_dir().path_join("old.db")
	var store := WorldStore.new()
	check(store.open(path, {"migrations": WorldStore.MIGRATIONS.slice(0, 1)}), "an old schema")
	store.write_meta("seed", "12")
	store.write_meta("world_format", "6")
	store.close()
	var before := FileAccess.get_sha256(path)
	var content := ContentRegistry.load_packs(["res://content/base"])
	check(ServerWorld.open(path, content, {"require_planned": true}) == null, "old generation is refused")
	check(ServerWorld.open_error.contains("старый тип генерации"), "reason identifies the old generation")
	eq(FileAccess.get_sha256(path), before, "refusal does not change the old database")
	store = WorldStore.new()
	check(store.open(path, {"migrations": WorldStore.MIGRATIONS.slice(0, 1)}), "the old schema is still readable")
	eq(store.schema_version(), 1, "no migration happened")
	store.close()


func test_spawn_is_chosen_after_water_and_climate() -> void:
	for preset in ["single_continent", "small", "medium"]:
		for seed_number in [0, 19, 431, 10000]:
			var plan := WorldPlan.generate(seed_number, preset, "cold")
			var k := plan.spawn.y * plan.size.x + plan.spawn.x
			check(plan.value(0, plan.spawn) > 0.05, "spawn is inland")
			eq(plan.lake[k], 0.0, "spawn is not in a lake")
			eq(plan.river[k], 0.0, "spawn is not in a river")


func test_climate_changes_generated_biomes_and_vegetation() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var cold := WorldPlan.generate(431, "small", "cold")
	var hot := WorldPlan.generate(431, "small", "hot")
	var cold_surface := SurfaceGenerator.new(431, content, cold)
	var hot_surface := SurfaceGenerator.new(431, content, hot)
	var cold_snow := 0
	var hot_snow := 0
	var cold_desert := 0
	var hot_desert := 0
	for y in range(0, cold.size.y, 3):
		for x in range(0, cold.size.x, 3):
			var p := Vector2i(x, y)
			var h := cold.value(0, p)
			if h < 0.04 or h > 0.38:
				continue
			var a := (p - cold.spawn) * Chunk.SIZE
			var b := (p - hot.spawn) * Chunk.SIZE
			var cold_biome: String = cold_surface.biome_ids[cold_surface._biome_at(a.x, a.y, h, false)]
			var hot_biome: String = hot_surface.biome_ids[hot_surface._biome_at(b.x, b.y, h, false)]
			cold_snow += 1 if cold_biome == "base:tundra" else 0
			hot_snow += 1 if hot_biome == "base:tundra" else 0
			cold_desert += 1 if cold_biome in ["base:desert", "base:steppe"] else 0
			hot_desert += 1 if hot_biome in ["base:desert", "base:steppe"] else 0
	check(cold_snow > hot_snow, "cold climate increases snowy tundra")
	check(hot_desert > cold_desert, "hot climate increases dry biomes")
	check(content.get_def("base:tundra")["cover_density"] != content.get_def("base:steppe")["cover_density"], "these biomes carry different vegetation")


func test_preview_colors_are_the_stored_biomes_and_water() -> void:
	var plan := WorldPlan.generate(19, "small", "cold")
	var image := WorldPreview.map_image(plan)
	var land_seen := false
	var water_seen := false
	for k in plan.size.x * plan.size.y:
		var p := Vector2i(k % plan.size.x, k / plan.size.x)
		if plan.value(0, p) < 0.0:
			eq(image.get_pixel(p.x, p.y), Color("195474"), "sea color represents sea")
			water_seen = true
		elif plan.lake[k] <= 0.0 and plan.river[k] <= 0.0:
			var biome: String = plan.biome_ids[plan.biomes[k]]
			var color := Color(String(WorldPreview.BIOME_COLORS.get(biome, "7f9e69")))
			eq(image.get_pixel(p.x, p.y), color, "land color represents its stored biome")
			land_seen = true
		if land_seen and water_seen:
			break
	check(land_seen and water_seen, "preview includes land and sea")




func test_planet_chunks_across_the_seam_share_saved_changes() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var plan := WorldPlan.generate(431, "small", "temperate")
	var world := ServerWorld.open(path, content, {"world_plan": plan.to_dict()})
	var first := Vector2i(-plan.spawn.x, 0)
	var alias := first + Vector2i(plan.size.x, 0)
	world.prefetch("surface", alias.x, alias.y)
	var chunk := world.chunk("surface", first.x, first.y)
	chunk.set_cell("ground", 0, 0, "base:stone")
	world._changed(ServerWorld.chunk_key("surface", alias.x, alias.y))
	eq(world.chunk_revision("surface", alias.x, alias.y), world.chunk_revision("surface", first.x, first.y), "a change has one shared revision")
	var encoded := ChunkCodec.decode(world.encoded_chunk("surface", alias.x, alias.y))
	eq(encoded.get_cell("ground", 0, 0), "base:stone", "the client receives the changed canonical chunk")
	eq(world.chunk("surface", alias.x, alias.y).get_cell("ground", 0, 0), "base:stone", "the seam names the same live cell")
	eq(world.storage_key("surface", first.x, first.y), world.storage_key("surface", alias.x, alias.y), "one storage key")
	world.close()
	world = ServerWorld.open(path, content)
	eq(world.chunk("surface", alias.x, alias.y).get_cell("ground", 0, 0), "base:stone", "the same cell is restored through either side")
	world.close()


func test_planet_chunk_views_reflect_at_the_poles() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir().path_join("world.db")
	var plan := WorldPlan.generate(431, "small", "cold")
	var world := ServerWorld.open(path, content, {"world_plan": plan.to_dict()})
	var beyond := Vector2i(0, -plan.spawn.y - 1)
	var canonical := plan.canonical_point(beyond, 1)
	var normal := world.chunk("surface", canonical.x, canonical.y)
	normal.set_cell("ground", 2, 31, "base:stone")
	world._changed(ServerWorld.chunk_key("surface", canonical.x, canonical.y))
	var reflected := world.chunk("surface", beyond.x, beyond.y)
	eq(reflected.get_cell("ground", 2, 0), "base:stone", "north pole reverses local rows")
	normal.set_props(2, 31, {"test": "updated"})
	reflected = world.chunk("surface", beyond.x, beyond.y)
	eq(reflected.props.get(Chunk.cell_index(2, 0), {}).get("test"), "updated", "reflected direct property view refreshes after canonical changes")
	reflected.set_cell("ground", 3, 1, "base:dirt")
	world._changed(ServerWorld.chunk_key("surface", beyond.x, beyond.y))
	eq(normal.get_cell("ground", 3, 30), "base:dirt", "writes go to the same canonical chunk")
	var encoded := ChunkCodec.decode(world.encoded_chunk("surface", beyond.x, beyond.y))
	eq(encoded.get_cell("ground", 3, 1), "base:dirt", "the client sees the reflected row")
	var tiles := MapTile.decode(world.map_tile("surface", beyond.x, beyond.y))
	eq(tiles["palette"][tiles["cells"][Chunk.cell_index(3, 1)]], "base:dirt", "the map sees the reflected row")
	eq(world.chunk("surface", canonical.x, canonical.y).get_cell("ground", 3, 30), "base:dirt", "the canonical view is unchanged")
	world.close()
	world = ServerWorld.open(path, content)
	eq(world.chunk("surface", beyond.x, beyond.y).get_cell("ground", 3, 1), "base:dirt", "the reflected view survives reload")
	var south := Vector2i(0, plan.size.y - plan.spawn.y)
	var south_canonical := plan.canonical_point(south, 1)
	var south_normal := world.chunk("surface", south_canonical.x, south_canonical.y)
	south_normal.set_cell("ground", 4, 31, "base:stone")
	eq(world.chunk("surface", south.x, south.y).get_cell("ground", 4, 0), "base:stone", "south pole also reflects rows")
	world.close()
