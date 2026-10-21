extends TestCase
## ADR-0049: the world's geography — endless, of regions each a landmass in
## the one ocean; the same from the same seed in whatever order it is asked
## about; rivers run unbroken from their sources to the sea or a lake.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])


func test_same_seed_same_regions_another_seed_another() -> void:
	var a := GeoRegion.new(11, Vector2i(2, -1))
	var b := GeoRegion.new(11, Vector2i(2, -1))
	var c := GeoRegion.new(12, Vector2i(2, -1))
	eq(a.height, b.height, "heights")
	eq(a.river, b.river, "rivers")
	eq(a.rain, b.rain, "rain")
	check(a.height != c.height, "another seed, another land")
	eq(Geography.of(11).origin, Geography.of(11).origin, "spawn")


func test_any_order_of_chunks_makes_the_same_land() -> void:
	var near := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-3, 2), Vector2i(7, -5), Vector2i(1, 1), Vector2i(-2, -2)]
	var one := SurfaceGenerator.new(21, _content)
	var made := {}
	for at: Vector2i in near:
		made[at] = ChunkCodec.encode(one.generate(at.x, at.y))
	var reversed := near.duplicate()
	reversed.reverse()
	var other := SurfaceGenerator.new(21, _content)
	for at: Vector2i in reversed:
		eq(ChunkCodec.encode(other.generate(at.x, at.y)), made[at], "chunk %s" % at)
	# Cell by cell, asked about out of order, the land is what the chunks show.
	var third := SurfaceGenerator.new(21, _content)
	for i in 300:
		var x := (i * 7919) % 400 - 200
		var y := (i * 104729) % 400 - 200
		eq(third.land_at(x, y), one.land_at(x, y), "cell %d,%d" % [x, y])


func test_regions_meet_in_the_open_sea() -> void:
	var geo := Geography.of(31)
	for at: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, -1)]:
		var r := geo.region(at)
		var dry_near_border := 0
		for j in GeoRegion.SIZE:
			for i in GeoRegion.SIZE:
				var k := j * GeoRegion.SIZE + i
				var e := GeoRegion.from_border(i, j)
				if e == 0:
					if not check(is_equal_approx(r.height[k], GeoRegion.BORDER_DEPTH), "the same depth on both sides of a border"):
						return
				if e < GeoRegion.MARGIN / 2 and r.height[k] >= GeoRegion.SEA:
					dry_near_border += 1
				if r.river[k] > 0.0:
					check(e > 0, "no river reaches a border")
		eq(dry_near_border, 0, "the sea all along region %s's borders" % at)
	# Neighbouring regions are of a piece: heights across a border are near.
	for j in range(0, GeoRegion.SIZE, 8):
		var gj := j
		var left := geo.point_value(Geography.HEIGHT, GeoRegion.SIZE - 1, gj)
		var right := geo.point_value(Geography.HEIGHT, GeoRegion.SIZE, gj)
		check(absf(left - right) < 0.05, "smooth across the border at row %d" % j)


func test_the_world_goes_on_without_end() -> void:
	var geo := Geography.of(41)
	var land := 0.0
	var with_land := 0
	for at: Vector2i in [Vector2i(30, -20), Vector2i(-55, 12), Vector2i(3, 70), Vector2i(-8, -9), Vector2i(17, 17)]:
		var share := geo.region(at).land_share()
		land += share
		with_land += 1 if share > 0.02 else 0
	check(with_land >= 3, "far regions hold land too: %d of 5" % with_land)
	check(land / 5.0 < 0.6, "and the sea between: %.2f" % (land / 5.0))
	var gen := SurfaceGenerator.new(41, _content)
	var far := gen.generate(9000, -7000)
	check(far.layer_ids("ground").size() > 0, "a chunk far away is made like any other")


func test_spawn_is_on_mild_dry_land() -> void:
	for seed_value in [1, 2, 3, 4, 5]:
		var gen := SurfaceGenerator.new(seed_value, _content)
		var land := gen.land_at(0, 0)
		eq(land["what"], "land", "seed %d: spawn on dry land" % seed_value)
		check(float(land["height"]) < Geography.HILLS + 0.05, "seed %d: low (%.2f)" % [seed_value, land["height"]])
		var climate := gen.geography.climate_at(0, 0)
		check(climate.x > -0.35 and climate.x < 0.6, "seed %d: mild (%.2f)" % [seed_value, climate.x])
		check(gen.geography.region_at(0, 0).place == Vector2i.ZERO, "in the first region")


func test_north_is_cold_south_warm_in_bands() -> void:
	var at_spawn := GeoRegion.latitude_warmth(GeoRegion.SIZE * 0.5)
	var north := GeoRegion.latitude_warmth(GeoRegion.SIZE * 0.5 - GeoRegion.LATITUDE * 0.5)
	var south := GeoRegion.latitude_warmth(GeoRegion.SIZE * 0.5 + GeoRegion.LATITUDE * 0.35)
	check(north < at_spawn and at_spawn < south, "%.2f < %.2f < %.2f" % [north, at_spawn, south])
	check(GeoRegion.latitude_warmth(GeoRegion.SIZE * 0.5 - GeoRegion.LATITUDE * 0.6) < -0.8, "a pole to the north")
	# Past the equator it cools again; past the pole it warms: no end to it.
	var beyond := GeoRegion.SIZE * 0.5 + GeoRegion.LATITUDE * 0.4
	check(GeoRegion.latitude_warmth(beyond + GeoRegion.LATITUDE * 0.5) < GeoRegion.latitude_warmth(beyond), "beyond the equator, cooler")


## Every river runs on, point by point, to the sea, a lake or a basin of a
## dry land; and on the ground, its water lies all along its course.
func test_rivers_run_unbroken() -> void:
	var gen := SurfaceGenerator.new(2, _content)
	var geo := gen.geography
	var r := geo.region(Vector2i.ZERO)
	var n := GeoRegion.SIZE
	var rivers := 0
	for k in n * n:
		if r.river[k] <= 0.0:
			continue
		rivers += 1
		var at := k
		var steps := 0
		while r.river[at] > 0.0 and steps < n * n:
			var to := r.down[at]
			if to < 0:
				break  # a basin of its own
			var d := Vector2i(to % n, to / n) - Vector2i(at % n, at / n)
			check(absi(d.x) <= 1 and absi(d.y) <= 1, "a river goes on to a neighbouring point")
			at = to
			steps += 1
		var end_ok := r.river[at] <= 0.0 and (r.height[at] < GeoRegion.SEA or r.is_lake(at)) or r.down[at] < 0
		if not check(end_ok, "the river from %d ends in the sea, a lake or a basin" % k):
			return
	check(rivers > 30, "rivers there are: %d points" % rivers)
	# On the ground: near the spawn, along every course, water within its winding.
	var checked := 0
	var dry_gaps := 0
	for cy in range(-4, 4):
		for cx in range(-4, 4):
			for seg: Array in geo.rivers_near(cx, cy):
				var a: Vector2 = seg[0]
				var b: Vector2 = seg[1]
				for t in 8:
					var p := a.lerp(b, t / 8.0)
					if geo.lake_level_at(int(p.x), int(p.y)) > -INF:
						continue
					checked += 1
					if not _water_near(gen, Vector2i(p), 14):
						dry_gaps += 1
	check(checked > 0, "some river near the spawn")
	eq(dry_gaps, 0, "no dry gap along %d points of courses" % checked)


func _water_near(gen: SurfaceGenerator, at: Vector2i, reach: int) -> bool:
	for dy in range(-reach, reach + 1, 2):
		for dx in range(-reach, reach + 1, 2):
			if String(gen.land_at(at.x + dx, at.y + dy)["what"]) == "water":
				return true
	return false


func test_a_changed_cell_stays_changed() -> void:
	var db := tmp_dir().path_join("world.db")
	var w := ServerWorld.open(db, _content, {"seed": 2})
	var c := w.chunk("surface", 1, 1)
	var before := c.get_cell("cover", 3, 4)
	c.set_cell("cover", 3, 4, "" if before != "" else "base:pebbles")
	var changed := c.get_cell("cover", 3, 4)
	w.mark_chunk_dirty("surface", 1, 1)
	w.handle("nobody", {"request_id": "x", "type": "noop"})
	w.close()
	var again := ServerWorld.open(db, _content)
	eq(again.chunk("surface", 1, 1).get_cell("cover", 3, 4), changed, "kept, not made again")
	again.close()


## ADR-0051: no river runs uphill; fords on rivers, shallows at the edges of
## lakes and the sea, deep water in the open sea.
func test_rivers_run_down_and_have_fords() -> void:
	for seed_value in [1, 2, 3]:
		var r := Geography.of(seed_value).region(Vector2i.ZERO)
		for k in GeoRegion.SIZE * GeoRegion.SIZE:
			if r.river[k] > 0.0 and r.down[k] >= 0:
				if not check(r.filled[r.down[k]] <= r.filled[k], "seed %d: the water's surface never rises downstream" % seed_value):
					return
	var gen := SurfaceGenerator.new(2, _content)
	var geo := gen.geography
	var fords := 0
	var found := 0
	var seen := {}
	for cy in range(-12, 12, 3):
		for cx in range(-12, 12, 3):
			for seg: Array in geo.rivers_near(cx, cy):
				var mid: Vector2 = (seg[0] + seg[1]) / 2.0
				if not seg[4] or seen.has(mid):
					continue
				seen[mid] = true
				fords += 1
				if _shallows_near(gen, Vector2i(mid), 16):
					found += 1
	check(fords >= 3, "fords near spawn: %d" % fords)
	check(found >= fords * 0.8, "shallows across the river at %d of %d fords" % [found, fords])
	# The open sea, far from any land, is deep.
	var border := Vector2i(GeoRegion.SIZE / 2, 0) * Geography.STEP - geo.origin
	eq(gen.land_at(border.x, border.y)["what"], "deep", "deep in the open sea")


func _shallows_near(gen: SurfaceGenerator, at: Vector2i, reach: int) -> bool:
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			if String(gen.land_at(at.x + dx, at.y + dy)["what"]) == "shallows":
				return true
	return false
