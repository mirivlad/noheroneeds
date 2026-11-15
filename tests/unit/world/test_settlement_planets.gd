extends TestCase
## The old density test used legacy geography; these cases use saved-planet
## terrain, including the player's enormous temperate M.I.R.V. planet.
var content: ContentRegistry
var mirv: WorldPlan

func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])

func _mirv_generator() -> SurfaceGenerator:
	if mirv == null:
		mirv = WorldPlan.generate(WorldLibrary.seed_of({"seed": "M.I.R.V."}), "huge", "temperate", content)
	return SurfaceGenerator.new(mirv.seed_value, content, mirv)

func _check_parcels(g: SurfaceGenerator, villages: Array) -> void:
	var adaptive := 0
	for village: Dictionary in villages:
		if not village.get("adaptive", false): continue
		adaptive += 1
		var terrain := TerrainShape3D.new(g)
		for area: Rect2i in [village.square, village.parking_yard, village.parking_reserve]:
			var expected := terrain.natural(area.get_center()) + .04
			for at: Vector2i in [area.get_center(), area.position + Vector2i.ONE]:
				check(absf(terrain.height(at) - expected) < .001, "each public parcel stands on its own terrain level")
		for rect: Rect2i in village.plots + village.fields + [village.square, village.parking_yard, village.parking_reserve]:
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if not check(g.land_at(x, y).what == "land", "an actual parcel is dry at %s" % Vector2i(x, y)): return
	check(adaptive > 0, "terrain fitting is actually used")

func test_huge_mirv_has_a_northern_cluster() -> void:
	var g := _mirv_generator()
	var villages := g.settlements.villages(0, 0, -1)
	check(villages.size() >= 2, "the northern district has a real cluster")
	_check_parcels(g, villages)

func test_huge_mirv_has_a_western_cluster() -> void:
	var g := _mirv_generator()
	var villages := g.settlements.villages(0, -1, 0)
	check(villages.size() >= 3, "the western district has several villages")
	_check_parcels(g, villages)

func test_huge_mirv_start_has_neighbours_and_real_roads() -> void:
	var g := _mirv_generator()
	check(g.settlements.villages(0, 0, 0).size() >= 3, "the start is not an isolated settlement")
	var home := g.settlements.home_plan()
	var roads := g.settlements.roads_of(0, 0, 0)
	check(roads.any(func(r: Dictionary) -> bool: return r.from == home.id or r.to == home.id), "the starting village has a real road")
	for road: Dictionary in roads:
		for at: Vector2i in road.path:
			var sample := g.land_at(at.x, at.y)
			if not check(sample.what != "deep" and not (sample.what == "rock" and not sample.get("cliff", false)), "roads avoid the sea and true crags"): return

func test_lake_plan_has_a_northern_cluster_and_is_order_independent() -> void:
	var plan := WorldPlan.generate(1278862159, "small", "temperate", content)
	var g := SurfaceGenerator.new(plan.seed_value, content, plan)
	var first := g.settlements.villages(0, 0, -1)
	check(first.size() >= 2, "the lake-region regression finds a cluster to the north")
	# No shared cache in this copy: calculate the same district independently.
	var other := SurfaceGenerator.new(plan.seed_value, content, plan)
	var independent := Settlements.new(plan.seed_value, content, other.is_unfit, other._clearing, other.biome_id_at, other.land_at)
	independent.villages(0, 1, -1)
	eq(independent.villages(0, 0, -1), first, "district traversal order does not move plots or paths")
