extends TestCase
## The one topology of a finite world: the same place has one name, reaches
## and sight go the short way round the seam, and the poles are an end, not a
## shortcut. A continent stays flat throughout.


func test_chunk_names_close_the_seam_and_the_poles() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var topo := PlanetTopology.new(plan)
	check(topo.wraps(), "a planet folds")
	var across := plan.size.x
	for at: Vector2i in [Vector2i(0, 0), Vector2i(3, 4), Vector2i(-1, 2), Vector2i(across, 5), Vector2i(-across * 3 + 2, 7)]:
		eq(topo.canonical_chunk(topo.canonical_chunk(at)), topo.canonical_chunk(at), "folding twice changes nothing")
		eq(topo.canonical_chunk(at + Vector2i(across, 0)), topo.canonical_chunk(at), "a lap of longitude is the same chunk")
	eq(topo.canonical_chunk(Vector2i(0, -plan.spawn.y - 1)), topo.canonical_chunk(Vector2i(across / 2, -plan.spawn.y)), "past the north pole is the far side, turned half a world")
	eq(topo.canonical_chunk(Vector2i(0, -plan.spawn.y + plan.size.y)), topo.canonical_chunk(Vector2i(across / 2, -plan.spawn.y + plan.size.y - 1)), "past the south pole too")
	check(topo.mirrored_chunk(Vector2i(0, -plan.spawn.y - 1)), "a chunk past a pole has its rows reversed")
	check(not topo.mirrored_chunk(Vector2i(0, -plan.spawn.y)), "a chunk in the middle does not")


func test_distance_goes_the_short_way_round_the_seam() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var topo := PlanetTopology.new(plan)
	var width := plan.size.x * Chunk.SIZE
	var left := Vector2i(-plan.spawn.x * Chunk.SIZE + 2, 40) * Movement.UNIT
	var right := Vector2i(-plan.spawn.x * Chunk.SIZE + width - 3, 40) * Movement.UNIT
	eq(topo.distance(left, right), 5.0 * Movement.UNIT, "five cells apart across the seam, not a world")
	eq(topo.distance(right, left), topo.distance(left, right), "the same either way")
	eq(topo.delta(left, right), Vector2i(-5 * Movement.UNIT, 0), "the way across the seam points west")
	eq(int(topo.cell_distance(Vector2i(0, 0), Vector2i(0, 0))), 0, "a place is nowhere from itself")
	# Nothing shortens the way through a pole: the poles are the ends.
	var north := Vector2i(0, -plan.spawn.y * Chunk.SIZE)
	var south := Vector2i(0, -plan.spawn.y * Chunk.SIZE + plan.size.y * Chunk.SIZE - 1)
	check(topo.distance(north, south) > float(plan.size.y * Chunk.SIZE / 2), "the poles are far apart")


func test_a_continent_never_folds() -> void:
	var plan := WorldPlan.generate(431, "single_continent", "temperate")
	var topo := PlanetTopology.new(plan)
	check(not topo.wraps(), "a continent is flat")
	for at: Vector2i in [Vector2i(0, 0), Vector2i(-99999, 99999), Vector2i(1000000, -3)]:
		eq(topo.canonical_chunk(at), at, "a chunk keeps its own name")
		eq(topo.distance(at * Movement.UNIT, at * Movement.UNIT + Vector2i(Movement.UNIT, 0)), float(Movement.UNIT), "distance is plain")
	eq(topo.canonical_chunk(Vector2i(0, -1)), Vector2i(0, -1), "past a pole there is no far side to come out at")


func test_no_topology_means_a_plain_world() -> void:
	var topo := PlanetTopology.new()
	check(not topo.wraps(), "an old world folds nothing")
	eq(topo.canonical_chunk(Vector2i(7, -8)), Vector2i(7, -8), "and keeps its names")
