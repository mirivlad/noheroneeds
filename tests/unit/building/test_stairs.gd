extends TestCase
## Stairs and openings (ADR-0007, ADR-0013, 16.10.2026): stairs come up
## through an opening over themselves — a ceiling there is taken away when
## they are built, as taking it apart would allow — and lead onto the floor
## their top faces. Gone, they leave the opening; one jumps down through it,
## falling as far as there is no floor. Stairs of old are brought to this way
## where it is safe.

var w: ServerWorld
var db := ""
var content: ContentRegistry
const B := "builder"  # not in the world: no reach (a server tool)
const C := "someone_else"


func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	content = ContentRegistry.load_packs(["res://content/base"])
	_open()
	w.max_levels = 6


func after_each() -> void:
	w.close()


func _open() -> void:
	w = ServerWorld.open(db, content, {"seed": 4})
	w.grant(B, "base:plank", 500)
	w.grant(B, "base:log", 50)
	w.grant(C, "base:plank", 100)


func _req(r: Dictionary, actor := B) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _build(loc: String, x: int, y: int, part: String, facing := "", actor := B) -> Dictionary:
	return _req({"type": "build", "location": loc, "x": x, "y": y, "part": part, "facing": facing}, actor)


func _cell(loc: String, layer: String, x: int, y: int) -> String:
	return w.chunk(loc, floori(x / 32.0), floori(y / 32.0)).get_cell(layer, posmod(x, 32), posmod(y, 32))


func _props(loc: String, x: int, y: int) -> Dictionary:
	return w.chunk(loc, floori(x / 32.0), floori(y / 32.0)).get_props(posmod(x, 32), posmod(y, 32))


## The level z of the building over surface cell (x, y).
func _level(z: int, x := 5, y := 4) -> String:
	return w.levels.level(w._ceiling_building("surface", x, y), z)


func _person(name: String, loc: String, cell: Vector2i) -> String:
	var c := PortableCharacter.create(name, "base:human_m")
	w.enter("k-" + name, c)
	w.present[c.character_id]["location"] = loc
	w.move_character(c.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	return c.character_id


func _where(id: String) -> Array:
	return [w.present[id]["location"], Movement.cell_of(w.present[id]["pos"])]


## A floor over (5, 4) and a ceiling over (5, 5), where stairs go.
func _room() -> void:
	_build("surface", 5, 4, "base:wood_ceiling")
	_build("surface", 5, 5, "base:wood_ceiling")


# 1, 7, 8, 9, 11, 12 and the whole cycle of the task: built, opened, up,
# broken, jumped down, built again on the opening, taken apart, closed.
func test_the_whole_cycle() -> void:
	_room()
	var planks := w.inventory(B).count("base:plank")
	var r := _build("surface", 5, 5, "base:wood_stairs")
	eq(r.get("opened"), true, "the ceiling over them made an opening")
	eq(planks - w.inventory(B).count("base:plank"), 4 - 2, "stairs paid, the ceiling's planks back")
	eq(_cell("surface", "ceiling", 5, 5), "", "no ceiling over them")
	var l1 := _level(1)
	eq(_cell(l1, "ground", 5, 5), "", "no floor over them: an opening")
	eq(_props("surface", 5, 5).get("arrive"), [5, 4], "they lead onto the floor north of them")
	eq(_props(l1, 5, 5).get("stairs_down"), true, "the way down is marked over them")
	var a := _person("Аня", "surface", Vector2i(5, 6))
	eq(_req({"type": "climb", "location": "surface", "x": 5, "y": 5}, a).get("z"), 1)
	eq(_where(a), [l1, Vector2i(5, 4)], "up onto the landing")
	eq(_req({"type": "climb", "location": l1, "x": 5, "y": 5, "dir": "down"}, a).get("location"), "surface",
		"down through the opening")
	eq(_where(a), ["surface", Vector2i(5, 5)], "onto the stairs")
	_req({"type": "climb", "location": "surface", "x": 5, "y": 5}, a)
	# Someone breaks the stairs while Аня is upstairs.
	var e := _person("Враг", "surface", Vector2i(5, 6))
	w.grant(e, "base:axe", 1)
	_req({"type": "hold", "item": "base:axe"}, e)
	var p := _props("surface", 5, 5).duplicate()
	p["damage"] = 776.0
	w.chunk("surface", 0, 0).set_props(5, 5, p)
	eq(_req({"type": "strike_part", "location": "surface", "x": 5, "y": 5}, e).get("broken"), "base:wood_stairs")
	eq(_cell("surface", "ceiling", 5, 5), "", "the opening stays")
	eq(_cell(l1, "ground", 5, 5), "", "no floor comes back")
	check(not _props(l1, 5, 5).has("stairs_down"), "nothing to go down by")
	eq(_where(a), [l1, Vector2i(5, 4)], "Аня is where she was")
	eq(_req({"type": "climb", "location": l1, "x": 5, "y": 5, "dir": "down"}, a).get("reason"), "no_stairs")
	eq(w.inventory(a).stacks.keys().filter(func(i: String) -> bool:
		return content.get_def(i).has("tools") or content.get_def(i).has("weapon")), [], "no tools at all")
	var j := _req({"type": "jump", "dx": 0, "dy": 1}, a)
	eq(j.get("location"), "surface", "she jumps down through the opening: %s" % j)
	eq(j.get("hurt"), 2, "a level's fall")
	eq(_where(a), ["surface", Vector2i(5, 5)])
	eq(_build("surface", 5, 5, "base:wood_stairs").get("opened"), null, "new stairs use the opening there")
	eq(_props(l1, 5, 5).get("stairs_down"), true)
	eq(_req({"type": "dismantle", "location": "surface", "x": 5, "y": 5}).get("part"), "base:wood_stairs")
	eq(_cell(l1, "ground", 5, 5), "", "taken apart: the opening stays too")
	w.move_character(a, Vector2i(5 * 256 + 128, 7 * 256 + 128))
	check(_build("surface", 5, 5, "base:wood_ceiling").get("ok", false), "the opening closed with a ceiling")
	eq(_cell(l1, "ground", 5, 5), "base:wood_floor", "a floor again")


# 2, 3, 5, 6: where stairs lead by their facing; no landing — refused, and
# a refusal changes nothing.
func test_facings_landings_and_refusals() -> void:
	_build("surface", 6, 5, "base:wood_ceiling")
	_build("surface", 4, 7, "base:wood_ceiling")
	eq(_build("surface", 5, 5, "base:wood_stairs", "e").get("ok"), true, "up east onto (6, 5): the opening there already")
	eq(_props("surface", 5, 5).get("arrive"), [6, 5])
	eq(_build("surface", 5, 7, "base:wood_stairs", "w").get("ok"), true, "up west")
	eq(_props("surface", 5, 7).get("arrive"), [4, 7])
	_build("surface", 8, 5, "base:wood_ceiling")
	var before := w.inventory(B).stacks.duplicate()
	for f: String in ["n", "e", "w"]:
		eq(_build("surface", 8, 5, "base:wood_stairs", f).get("reason"), "no_landing", "a ceiling over, no floor beside (%s)" % f)
	eq(_cell("surface", "ceiling", 8, 5), "base:wood_ceiling", "the ceiling stays")
	eq(_cell("surface", "structure", 8, 5), "", "no stairs")
	eq(w.inventory(B).stacks, before, "nothing paid, nothing given back")
	eq(_build("surface", 9, 9, "base:wood_stairs", "s").get("reason"), "no_landing", "south is not a facing: north, nothing there")


# 4, 5, 15: the opening goes only as taking that ceiling apart would let it:
# not with something over it, not someone else's; a refusal changes nothing.
func test_an_opening_is_no_way_round_the_rules() -> void:
	_room()
	var l1 := _level(1)
	_build(l1, 5, 5, "base:wood_wall")
	var before := w.inventory(B).stacks.duplicate()
	eq(_build("surface", 5, 5, "base:wood_stairs").get("reason"), "occupied_above", "a wall stands over it")
	eq(w.inventory(B).stacks, before, "nothing paid")
	eq(_cell("surface", "ceiling", 5, 5), "base:wood_ceiling", "the ceiling stays")
	_req({"type": "dismantle", "location": l1, "x": 5, "y": 5})
	var thing := w.place_item(l1, Vector2i(5 * 256 + 100, 5 * 256 + 100), "base:stone", 1)
	eq(_build("surface", 5, 5, "base:wood_stairs").get("reason"), "occupied_above", "a thing lies over it")
	w.take_item(thing, w.inventory(B))
	var a := _person("Аня", l1, Vector2i(5, 5))
	eq(_build("surface", 5, 5, "base:wood_stairs").get("reason"), "occupied_above", "someone stands over it")
	w.move_character(a, Vector2i(5 * 256 + 128, 4 * 256 + 128))
	_build("surface", 7, 4, "base:wood_ceiling", "", C)
	_build("surface", 7, 5, "base:wood_ceiling", "", C)
	before = w.inventory(B).stacks.duplicate()
	eq(_build("surface", 7, 5, "base:wood_stairs").get("reason"), "ceiling_not_yours", "someone else's ceiling: broken, not opened")
	eq(w.inventory(B).stacks, before)
	eq(_cell("surface", "ceiling", 7, 5), "base:wood_ceiling")
	_build(_level(1, 7, 4), 7, 4, "base:wood_wall")
	eq(_build("surface", 7, 5, "base:wood_stairs", "", C).get("reason"), "landing_blocked", "a wall on the landing")
	_build("surface", 9, 4, "base:wood_ceiling")
	_build("surface", 9, 5, "base:thatch_roof")
	eq(_build("surface", 9, 5, "base:wood_stairs").get("reason"), "roof_above")


# 14, 17 and the landing: no ceiling over working stairs; their landing
# cannot be taken from under them; an occupied ceiling is not broken.
func test_what_stairs_need_stays() -> void:
	_room()
	_build("surface", 5, 5, "base:wood_stairs")
	eq(_build("surface", 5, 5, "base:wood_ceiling").get("reason"), "stairs_here", "not closed over working stairs")
	eq(_req({"type": "dismantle", "location": "surface", "x": 5, "y": 4}).get("reason"), "stairs_below",
		"the landing stays while the stairs lead there")
	var e := _person("Враг", "surface", Vector2i(5, 3))
	_req({"type": "hold", "item": ""}, e)
	eq(_req({"type": "strike_part", "location": "surface", "x": 5, "y": 4, "layer": "ceiling"}, e).get("reason"),
		"stairs_below", "nor broken")
	_build("surface", 6, 4, "base:wood_ceiling")
	_build(_level(1), 6, 4, "base:wood_wall")
	eq(_req({"type": "strike_part", "location": "surface", "x": 6, "y": 4, "layer": "ceiling"}, e).get("reason"),
		"occupied_above", "a ceiling with a wall over it is not broken")


# 16: walls break whatever stands over them; nothing falls.
func test_walls_break_under_floors() -> void:
	_build("surface", 6, 5, "base:wood_wall")
	_build("surface", 6, 5, "base:wood_ceiling")
	_build(_level(1, 6, 5), 6, 5, "base:wood_ceiling")
	_build(_level(2, 6, 5), 6, 5, "base:wood_wall")
	var e := _person("Враг", "surface", Vector2i(6, 6))
	var p := _props("surface", 6, 5).duplicate()
	p["damage"] = 1039.5
	w.chunk("surface", 0, 0).set_props(5 + 1, 5, p)
	eq(_req({"type": "strike_part", "location": "surface", "x": 6, "y": 5}, e).get("broken"), "base:wood_wall")
	eq(_cell("surface", "ceiling", 6, 5), "base:wood_ceiling", "the floor above stays")
	eq(_cell(_level(2, 6, 5), "structure", 6, 5), "base:wood_wall", "and what is two levels up")


# 13, 6: a five-storey house, stairs on each level turned different ways,
# each opening the ceiling over it; the stairs gone, one goes down through
# the openings level by level; openings one over another are fallen through
# together, never past a floor.
func test_a_five_storey_house() -> void:
	# [stairs cell, facing, landing] for levels 0..4, over a room x 3..7, y 3..7.
	var plan := [[Vector2i(5, 5), "n", Vector2i(5, 4)], [Vector2i(3, 4), "e", Vector2i(4, 4)],
		[Vector2i(6, 6), "w", Vector2i(5, 6)], [Vector2i(7, 4), "n", Vector2i(7, 3)], [Vector2i(4, 6), "e", Vector2i(5, 6)]]
	var locs := ["surface"]
	for z in 5:
		var loc: String = locs[z]
		for y in range(3, 8):
			for x in range(3, 8):
				_build(loc, x, y, "base:wood_ceiling")  # where there is floor (not over the openings below)
		var r := _build(loc, plan[z][0].x, plan[z][0].y, "base:wood_stairs", plan[z][1])
		eq(r.get("opened"), true, "stairs on level %d open the ceiling over them: %s" % [z, r])
		locs.append(_level(z + 1))
	eq(w.levels.z(locs[5]), 5)
	var a := _person("Аня", "surface", Vector2i(5, 6))
	for z in 5:
		w.present[a]["location"] = locs[z]
		w.move_character(a, (plan[z][0] as Vector2i) * Movement.UNIT + Vector2i(128, 128))
		var up := _req({"type": "climb", "location": locs[z], "x": plan[z][0].x, "y": plan[z][0].y, "dir": "up"}, a)
		eq(up.get("z"), z + 1, "up from %d: %s" % [z, up])
		eq(_where(a), [locs[z + 1], plan[z][2]], "onto the landing")
	for z in 5:
		_req({"type": "dismantle", "location": locs[z], "x": plan[z][0].x, "y": plan[z][0].y})
	# Down level by level: from the landing into the opening beside it.
	for z in range(5, 0, -1):
		w.present[a]["location"] = locs[z]
		w.move_character(a, (plan[z - 1][2] as Vector2i) * Movement.UNIT + Vector2i(128, 128))
		var d: Vector2i = plan[z - 1][0] - plan[z - 1][2]
		var j := _req({"type": "jump", "dx": d.x, "dy": d.y}, a)
		eq(j.get("z"), z - 1, "from %d one level down, not past the floor there: %s" % [z, j])
		eq(j.get("hurt"), 2)
	# The first stairs' opening goes up through every level: fallen through whole.
	w.present[a]["location"] = locs[5]
	w.move_character(a, Vector2i(5 * 256 + 128, 4 * 256 + 128))
	var fall := _req({"type": "jump", "dx": 0, "dy": 1}, a)
	eq(fall.get("location"), "surface", "down through all the openings: %s" % fall)
	eq(fall.get("hurt"), 20, "five levels' fall")


# 18, 20: kept over a restart; a request repeated is applied once; two
# players at the same opening at once leave one consistent state.
func test_restart_repeats_and_races() -> void:
	_room()
	var r := {"type": "build", "location": "surface", "x": 5, "y": 5, "part": "base:wood_stairs", "request_id": "same"}
	var planks := w.inventory(B).count("base:plank")
	w.handle(B, r.duplicate())
	w.handle(B, r.duplicate())
	w.sync()
	w.take_acks()
	eq(planks - w.inventory(B).count("base:plank"), 2, "paid and given back once")
	w.flush_state()
	w.close()
	_open()
	var l1 := _level(1)
	eq(_cell("surface", "ceiling", 5, 5), "", "the opening kept over a restart")
	eq(_cell(l1, "ground", 5, 5), "")
	eq(_props("surface", 5, 5).get("arrive"), [5, 4])
	var a := _person("Аня", "surface", Vector2i(5, 6))
	eq(_req({"type": "climb", "location": "surface", "x": 5, "y": 5}, a).get("z"), 1, "and climbed")
	# A race: stairs that would open a ceiling, and a wall on the floor over it,
	# asked in the same tick: whichever comes first, the other is refused.
	_build("surface", 7, 4, "base:wood_ceiling")
	_build("surface", 7, 5, "base:wood_ceiling")
	w.handle(B, {"request_id": "stairs", "type": "build", "location": "surface", "x": 7, "y": 5, "part": "base:wood_stairs"})
	w.handle(B, {"request_id": "wall", "type": "build", "location": l1, "x": 7, "y": 5, "part": "base:wood_wall"})
	w.sync()
	var got := {}
	for ack: Array in w.take_acks():
		got[ack[1]] = ack[2]
	eq(got["stairs"].get("ok"), true)
	eq(got["wall"].get("reason"), "no_floor", "the opening came first: no floor for the wall")
	eq(_cell(l1, "structure", 7, 5), "", "no wall hanging over the opening")


# 19: stairs of old — up through a ceiling over themselves onto their own
# cell — are brought to today's way as their chunk loads, where it is safe;
# elsewhere they still work as they did. Nobody in the world has the floor
# taken from under them; one away is put on the floor below on return.
func test_stairs_of_old() -> void:
	# Four stairs as old worlds have them: no "arrive", a ceiling over them,
	# the way down marked over them.
	for x in [5, 8, 11, 14]:
		_build("surface", x, 5, "base:wood_ceiling", "", C)
	for x in [5, 11, 14]:
		_build("surface", x, 4, "base:wood_ceiling")  # a floor beside: not for the second
	_build(_level(1, 11, 5), 11, 5, "base:wood_column")  # something over the third
	var c := w.chunk("surface", 0, 0)
	for x in [5, 8, 11, 14]:
		c.set_cell("structure", x, 5, "base:wood_stairs")
		var p := c.get_props(x, 5).duplicate()
		p.merge({"owner": C})
		c.set_props(x, 5, p)
		w._mark_way_down(w.levels.level(w._ceiling_building("surface", x, 5), 1), Vector2i(x, 5), true)
	w.mark_chunk_dirty("surface", 0, 0)
	var a := _person("Аня", "surface", Vector2i(8, 6))
	var off := _person("Боря", _level(1, 14, 5), Vector2i(14, 5))
	w.leave(off)  # away, standing over the fourth stairs
	var planks := w.inventory(C).count("base:plank")
	w.flush_state()
	w.leave(a)
	w.close()
	_open()
	w.chunk("surface", 0, 0)
	var l1 := _level(1, 5, 4)
	eq(_props("surface", 5, 5).get("arrive"), [5, 4], "the first: onto the floor beside")
	eq(_cell("surface", "ceiling", 5, 5), "", "the ceiling over it gone")
	eq(_cell(l1, "ground", 5, 5), "")
	eq(_props(l1, 5, 5).get("stairs_down"), true, "the way down still marked over it")
	eq(w.inventory(C).count("base:plank") - planks - 100, 4, "the ceilings' planks (the first and the fourth) to their builder (100 more granted on opening)")
	eq(_cell("surface", "ceiling", 8, 5), "base:wood_ceiling", "the second: no floor beside — as it was")
	check(not _props("surface", 8, 5).has("arrive"), "")
	eq(_cell("surface", "ceiling", 11, 5), "base:wood_ceiling", "the third: something over it — as it was")
	eq(_cell("surface", "ceiling", 14, 5), "", "the fourth: Боря, away, stood over it — it goes all the same")
	var back := PortableCharacter.from_data(w._known_character(off)["data"])
	w.enter(w._known_character(off)["owner"], back)
	eq(_where(off), ["surface", Vector2i(14, 5)], "Боря back, put on the floor below (here the stairs), unhurt")
	eq(w.combat.health_of(off), 20)
	back = PortableCharacter.from_data(w._known_character(a)["data"])
	w.enter(w._known_character(a)["owner"], back)
	var up := _req({"type": "climb", "location": "surface", "x": 8, "y": 5}, a)
	eq(up.get("z"), 1, "old stairs still lead up: %s" % up)
	eq(_where(a)[1], Vector2i(8, 5), "the old way, onto their own cell")
	eq(_req({"type": "climb", "location": up["location"], "x": 8, "y": 5, "dir": "down"}, a).get("location"), "surface")


## The author, 16.10.2026: a floor is not kept for one away; on return one
## is put on the floor below, down to the ground, unhurt.
func test_a_floor_goes_from_under_one_away() -> void:
	_build("surface", 6, 4, "base:wood_ceiling")
	_build("surface", 6, 3, "base:wood_ceiling")
	var l1 := _level(1, 6, 4)
	_build(l1, 6, 4, "base:wood_ceiling")
	var l2 := _level(2, 6, 4)
	var off := _person("Боря", l2, Vector2i(6, 4))
	var high := _person("Вера", l1, Vector2i(6, 3))
	w.leave(off)
	w.leave(high)
	eq(_req({"type": "dismantle", "location": l1, "x": 6, "y": 4, "layer": "ceiling"}).get("ok"), true, "under Боря, away")
	eq(_req({"type": "dismantle", "location": "surface", "x": 6, "y": 3, "layer": "ceiling"}).get("ok"), true, "under Вера")
	w.enter(w._known_character(off)["owner"], PortableCharacter.from_data(w._known_character(off)["data"]))
	eq(_where(off), [l1, Vector2i(6, 4)], "Боря on the floor below")
	w.enter(w._known_character(high)["owner"], PortableCharacter.from_data(w._known_character(high)["data"]))
	eq(_where(high), ["surface", Vector2i(6, 3)], "Вера on the ground")
	eq([w.combat.health_of(off), w.combat.health_of(high)], [20, 20], "unhurt")
