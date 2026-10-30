extends TestCase
## A planet played through the world itself: one place a lap apart is one
## place for things and creatures, what is near is near across the seam, and
## all of it stays so through a save and a reload.

var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("planet.db")


func _open(plan: WorldPlan) -> ServerWorld:
	var w := ServerWorld.open(_db, _content, {"world_plan": plan.to_dict()})
	check(w != null, "the planet opens")
	return w


## The westernmost cell of the map, as a player walking west names it.
func _west(plan: WorldPlan) -> Vector2i:
	return Vector2i(-plan.spawn.x * Chunk.SIZE, 0)


## The cell one place a lap east of `cell` (the same place, named otherwise).
func _lap_east(plan: WorldPlan, cell: Vector2i) -> Vector2i:
	return cell + Vector2i(plan.size.x * Chunk.SIZE, 0)


## The cell just across the seam, east of the westernmost cell of the map.
func _across(plan: WorldPlan, cell: Vector2i) -> Vector2i:
	return cell + Vector2i(plan.size.x * Chunk.SIZE - 1, 0)


func _middle(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


## A clear field (grass, no plants) across a band of cells, as a plain would be.
func _clear(w: ServerWorld, from: Vector2i, to: Vector2i) -> void:
	var chunks := {}
	for y in range(from.y, to.y + 1):
		for x in range(from.x, to.x + 1):
			var cx := floori(float(x) / Chunk.SIZE)
			var cy := floori(float(y) / Chunk.SIZE)
			var c := w.chunk("surface", cx, cy)
			c.set_cell("ground", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, "base:grass")
			c.set_cell("cover", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, "")
			chunks[ServerWorld.chunk_key("surface", cx, cy)] = true
	for key: String in chunks:
		w._changed(key)


func _req(w: ServerWorld, actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func test_a_thing_at_the_seam_is_one_thing_from_both_sides() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var w := _open(plan)
	if w == null:
		return
	var west := _west(plan)
	var east := _lap_east(plan, west)
	var a := PortableCharacter.create("Аня", "base:human_m")
	eq(w.enter("owner", a), "")
	w.move_character(a.character_id, _middle(east))
	var id := w.place_item("surface", _middle(west), "base:plank", 1)
	check(w.items_in_chunk("surface", west.x >> 5, west.y >> 5).has(id), "the west edge holds it")
	check(w.items_in_chunk("surface", east.x >> 5, east.y >> 5).has(id), "so does the east edge: one chunk")
	eq(w.distance(_middle(west), _middle(_across(plan, west))), float(Movement.UNIT), "one cell apart, the short way")
	var r := _req(w, a.character_id, {"type": "pickup", "entity": id})
	check(r.get("ok", false), "a step across the seam is a step, not a world: %s" % [r])
	eq(w.inventory(a.character_id).count("base:plank"), 1, "picked up through the seam")
	w.close()


func test_a_creature_at_the_seam_is_found_from_either_side() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var w := _open(plan)
	if w == null:
		return
	var west := _west(plan)
	var east := _lap_east(plan, west)
	var hare := w.creatures._spawn("base:hare", "surface", east, {}, 3)
	hare.next_think = 1 << 40  # it does only what the test tells it
	var id := hare.id
	w.creatures.save_all()
	eq(w.creatures.in_chunk("surface", west.x >> 5, west.y >> 5).has(id), true, "the west edge's creatures hold it")
	w.close()
	w = _open(plan)
	check(w.chunk("surface", west.x >> 5, west.y >> 5) != null, "the west side loads the one chunk")
	check(w.creatures.get_creature(id) != null, "the hare is here, not a world away")
	w.close()


func test_a_wolf_across_the_seam_is_a_neighbour() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var w := _open(plan)
	if w == null:
		return
	var west := _west(plan)
	var east := _lap_east(plan, west)
	var me := PortableCharacter.create("Аня", "base:human_m")
	eq(w.enter("owner", me), "")
	w.move_character(me.character_id, _middle(east + Vector2i(3, 0)))
	# Four cells east of the seam; the wolf four cells west of it.
	_clear(w, west - Vector2i(12, 2), west + Vector2i(2, 2))
	_clear(w, east - Vector2i(2, 2), east + Vector2i(12, 2))
	var wolf := w.creatures._spawn("base:wolf", "surface", west - Vector2i(4, 0), {}, 5)
	wolf.next_think = 1 << 40
	var wolf_id := wolf.id
	w.creatures._perceive(wolf, _content.get_def("base:wolf"))
	var seen: Dictionary = w.creatures.get_creature(wolf_id).memory.get(me.character_id, {})
	check(not seen.is_empty(), "the wolf sees a character seven cells away across the seam: %s" % [seen])
	if not seen.is_empty():
		eq(w.distance(_middle(east + Vector2i(3, 0)), Vector2i(seen["pos"]) * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)) <= 8.0 * Movement.UNIT, true, "and where it is is near")
	# A continent has no seam: the same two are a world apart.
	var flat := PlanetTopology.new(WorldPlan.generate(431, "single_continent", "temperate"))
	check(flat.distance(_middle(west - Vector2i(4, 0)), _middle(east + Vector2i(3, 0))) > 1000.0, "flat stays far")
	w.close()


func test_a_band_of_chunks_folds_the_seam_and_the_poles() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var w := _open(plan)
	if w == null:
		return
	var west := _west(plan)
	var width := plan.size.x
	# A band running over the seam names the eastern chunks too: each once.
	var band := w.chunk_band(Vector2i((west.x >> 5) - 2, 0), Vector2i((west.x >> 5) + 2, 0))
	var names := {}
	for at: Vector2i in band:
		check(not names.has(at), "a chunk is asked about once: %s" % [at])
		names[at] = true
	check(band.any(func(at: Vector2i) -> bool: return at.x >= (west.x >> 5) + width - 2), "the east edge is in the band: %s" % [band])
	# A band over the north pole names the far side, turned half a world.
	var north := Vector2i(west.x >> 5, -plan.spawn.y)
	var over := w.chunk_band(north + Vector2i(0, -2), north + Vector2i(2, 1))
	for at: Vector2i in over:
		check(not w.topology.mirrored_chunk(at), "a canonical chunk is never itself reflected: %s" % [at])
	check(over.any(func(at: Vector2i) -> bool: return at.y == -plan.spawn.y), "the far side of the pole is in the band: %s" % [over])
	w.close()


func test_reopening_keeps_what_was_built_and_destroyed() -> void:
	var plan := WorldPlan.generate(431, "small", "temperate")
	var w := _open(plan)
	if w == null:
		return
	var west := _west(plan)
	var east := _lap_east(plan, west)
	var c := w.chunk("surface", west.x >> 5, west.y >> 5)
	c.set_cell("structure", 1, 1, "base:wood_wall")
	c.set_cell("ground", 2, 2, "base:stone")
	w.mark_chunk_dirty("surface", west.x >> 5, west.y >> 5)
	w._changed(ServerWorld.chunk_key("surface", west.x >> 5, west.y >> 5))
	w.close()
	# Opened from the east side first: the other name still finds the changes.
	w = _open(plan)
	var from_east := w.chunk("surface", east.x >> 5, east.y >> 5)
	eq(from_east.get_cell("structure", 1, 1), "base:wood_wall", "the wall built at the west edge")
	eq(from_east.get_cell("ground", 2, 2), "base:stone", "the ground laid there")
	eq(w.chunk_revision("surface", east.x >> 5, east.y >> 5), w.chunk_revision("surface", west.x >> 5, west.y >> 5),
		"a change told once, seen from either side")
	w.close()


func test_opening_twice_does_not_regenerate_the_world() -> void:
	var plan := WorldPlan.generate(431, "small", "cold")
	var w := _open(plan)
	if w == null:
		return
	var c := w.chunk("surface", 0, 0)
	c.set_cell("ground", 5, 5, "base:stone")
	w.mark_chunk_dirty("surface", 0, 0)
	w.close()
	# A different plan handed to the same file is ignored in favour of the saved one.
	var other := WorldPlan.generate(99, "small", "hot")
	w = ServerWorld.open(_db, _content, {"world_plan": other.to_dict()})
	check(w != null, "the saved world opens with another plan offered")
	eq((w.generator.geography as PlannedGeography).plan.to_dict(), plan.to_dict(), "the saved plan is the world")
	eq(w.chunk("surface", 0, 0).get_cell("ground", 5, 5), "base:stone", "and its changes are kept")
	w.close()


func test_a_continent_keeps_its_endless_ocean() -> void:
	var plan := WorldPlan.generate(431, "single_continent", "temperate")
	var w := _open(plan)
	if w == null:
		return
	var at := Vector2i(-plan.spawn.x, -plan.spawn.y)
	var c := w.chunk("surface", at.x - 30, at.y)
	var ground := c.get_cell("ground", 0, 0) if c else ""
	check(c != null and ground != "" and _content.get_def(ground).get("swim", false), "past the map is open sea, not another shore: %s" % ground)
	w.close()
