extends TestCase
## ADR-0015: sight on the plan with the heights of what is in the way;
## windows and loopholes only for one standing at them, in their sector and
## range; walkways and open roofs see over fences, closed rooms do not.

var w: ServerWorld
const B := "builder"
const O := Vector2i(170, 170)  # a cleared field around here


func before_each() -> void:
	w = ServerWorld.open(tmp_dir().path_join("world.db"), ContentRegistry.load_packs(["res://content/base"]), {"seed": 4})
	w.grant(B, "base:plank", 500)
	w.grant(B, "base:log", 50)
	w.grant(B, "base:stone", 50)
	var c := w.chunk("surface", 5, 5)
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")


func after_each() -> void:
	w.close()


func _build(loc: String, at: Vector2i, part: String, facing := "") -> Dictionary:
	var r := {"request_id": Uuid.v4(), "type": "build", "location": loc, "x": O.x + at.x, "y": O.y + at.y, "part": part}
	if facing != "":
		r["facing"] = facing
	w.handle(B, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _sees(la: String, a: Vector2i, lb: String, b: Vector2i) -> bool:
	return Sight.clear(w, la, O + a, lb, O + b)


func test_on_the_ground_walls_block_and_plants_by_their_height() -> void:
	check(_sees("surface", Vector2i(0, 0), "surface", Vector2i(8, 0)), "an open field")
	_build("surface", Vector2i(4, 0), "base:wood_wall")
	check(not _sees("surface", Vector2i(0, 0), "surface", Vector2i(8, 0)), "a wall in the way")
	w.chunk("surface", 5, 5).set_cell("cover", O.x + 4 - 160, O.y + 12 - 160, "base:bush")
	check(not _sees("surface", Vector2i(0, 12), "surface", Vector2i(8, 12)), "a bush hides one on the ground")


func test_a_window_lets_through_one_standing_at_it_within_its_sector_and_range() -> void:
	for x in range(-3, 4):
		check(_build("surface", Vector2i(x, 0), "base:wood_window" if x == 0 else "base:wood_wall", "s" if x == 0 else "").get("ok", false), "built %d" % x)
	var inner := Vector2i(0, -1)
	check(_sees("surface", inner, "surface", Vector2i(0, 8)), "at the window, straight out")
	check(_sees("surface", inner, "surface", Vector2i(4, 8)), "and to the side, within its sector")
	check(not _sees("surface", inner, "surface", Vector2i(12, 2)), "not outside its sector")
	check(not _sees("surface", inner, "surface", Vector2i(0, 16)), "nor beyond its range")
	check(not _sees("surface", Vector2i(1, -2), "surface", Vector2i(-1, 8)), "not from the room behind")
	check(_sees("surface", Vector2i(0, 8), "surface", inner), "the one outside sees the one at the window")
	check(not _sees("surface", Vector2i(0, 8), "surface", Vector2i(0, -3)), "but not into the room")
	# A loophole looks along a narrower sector, farther.
	for x in range(-3, 4):
		_build("surface", Vector2i(x, 20), "base:loophole" if x == 0 else "base:stone_wall", "n" if x == 0 else "")
	check(_sees("surface", Vector2i(0, 21), "surface", Vector2i(0, 4)), "through the loophole, far")
	check(not _sees("surface", Vector2i(0, 21), "surface", Vector2i(-6, 12)), "but narrow")


func test_from_a_walkway_over_the_fence_not_from_a_closed_room() -> void:
	# A wall with a walkway on top (ceilings over it) and a fence in the yard.
	var level := ""
	for x in range(-2, 3):
		_build("surface", Vector2i(x, 0), "base:wood_wall")
		level = _build("surface", Vector2i(x, 0), "base:wood_ceiling").get("level", level)
		_build("surface", Vector2i(x, -1), "base:wood_ceiling")
	check(level != "", "a level above")
	_build("surface", Vector2i(0, 3), "base:wood_wall")
	check(not _sees("surface", Vector2i(0, -2), "surface", Vector2i(0, 8)), "the wall hides the field from the ground")
	check(_sees(level, Vector2i(0, 0), "surface", Vector2i(0, 8)), "from the walkway, over the fence")
	check(_sees("surface", Vector2i(0, 8), level, Vector2i(0, 0)), "and one in the field sees the one up there")
	check(not _sees("surface", Vector2i(0, 8), "surface", Vector2i(0, -2)), "but not the one behind the wall")
	# Walls upstairs: a closed room sees nothing out.
	_build(level, Vector2i(0, 0), "base:wood_wall")
	check(not _sees(level, Vector2i(0, -1), "surface", Vector2i(0, 8)), "a wall upstairs is in the way")
	check(not _sees("surface", Vector2i(0, 8), level, Vector2i(0, -1)), "both ways")


func test_a_roof_hides_what_is_behind_it_from_up_high() -> void:
	var level := ""
	for x in range(-1, 2):
		level = _build("surface", Vector2i(x, 0), "base:wood_ceiling").get("level", level)
	check(_sees(level, Vector2i(0, 0), "surface", Vector2i(0, 5)), "the ground in front")
	_build("surface", Vector2i(0, 3), "base:thatch_roof")
	check(not _sees(level, Vector2i(0, 0), "surface", Vector2i(0, 5)), "a roof in the way")
	check(_sees("surface", Vector2i(-3, 5), "surface", Vector2i(3, 5)), "on the ground, the roof is above the line")


func test_other_spaces_are_not_seen() -> void:
	check(not Sight.same_space(w, "surface", "depth:-1"), "underground is another plan")
	check(not _sees("surface", Vector2i(0, 0), "depth:-1", Vector2i(0, 1)), "nor anyone there")
