extends TestCase
## ADR-0007: ceilings make the next level, walls do not; the contour is
## exact; the height limit is a server setting; occupied ceilings stay;
## buildings merge; stairs connect levels; everything survives a restart.

var w: ServerWorld
var db := ""
const B := "builder"


func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	_open()


func after_each() -> void:
	w.close()


func _open() -> void:
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 4})
	w.grant(B, "base:plank", 500)
	w.grant(B, "base:log", 50)


func _req(r: Dictionary, actor := B) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _build(loc: String, x: int, y: int, part: String) -> Dictionary:
	return _req({"type": "build", "location": loc, "x": x, "y": y, "part": part})


func _cell(loc: String, layer: String, x: int, y: int) -> String:
	return w.chunk(loc, floori(x / 32.0), floori(y / 32.0)).get_cell(layer, posmod(x, 32), posmod(y, 32))


## GDD scenario 5: a wall around a yard makes no level and no room.
func test_walls_alone_make_no_level() -> void:
	for x in range(0, 5):
		for y in [0, 4]:
			_build("surface", x, y, "base:wood_wall")
	for y in range(1, 4):
		for x in [0, 4]:
			_build("surface", x, y, "base:wood_wall")
	eq(w.levels.info.size(), 0, "no level")
	check(not Terrain.is_covered(w.chunk("surface", 0, 0), 2, 2), "the yard is outdoors")


## GDD scenario 6: a partial ceiling gives a level exactly over its cells.
func test_partial_ceiling_and_exact_contour() -> void:
	for x in range(2, 5):
		for y in range(2, 4):
			eq(_build("surface", x, y, "base:wood_ceiling").get("ok"), true)
	eq(w.levels.info.size(), 1, "one level")
	var up: String = w.levels.info.keys()[0]
	eq(w.levels.z(up), 1)
	var floors := 0
	for x in range(0, 8):
		for y in range(0, 6):
			if _cell(up, "ground", x, y) != "":
				floors += 1
				check(x >= 2 and x < 5 and y >= 2 and y < 4, "floor only over the ceiling: %d,%d" % [x, y])
	eq(floors, 6)
	eq(_build(up, 3, 3, "base:wood_wall").get("ok"), true, "a wall on the floor")
	eq(_build(up, 6, 3, "base:wood_wall")["reason"], "no_floor", "not in the air")
	eq(_build(up, 6, 3, "base:wood_ceiling")["reason"], "no_floor", "the next level stays inside the contour")
	check(Terrain.is_covered(w.chunk("surface", 0, 0), 3, 3), "the room below is covered")


func test_height_is_a_server_setting() -> void:
	w.max_levels = 2
	_build("surface", 1, 1, "base:wood_ceiling")
	var l1: String = w.levels.level(w.levels.buildings.keys()[0], 1)
	eq(_build(l1, 1, 1, "base:wood_ceiling").get("ok"), true, "level 2")
	var l2 := w.levels.level(w.levels.building(l1), 2)
	eq(_build(l2, 1, 1, "base:wood_ceiling")["reason"], "too_high")
	w.max_levels = 1  # the administrator lowers the limit
	eq(_cell(l2, "ground", 1, 1), "base:wood_floor", "existing levels stay")
	_build("surface", 2, 1, "base:wood_ceiling")
	eq(_build(l1, 2, 1, "base:wood_ceiling")["reason"], "too_high", "only new building is limited")
	w.max_levels = 10
	eq(_build(l2, 1, 1, "base:wood_ceiling").get("ok"), true, "raised again")


func test_occupied_ceiling_cannot_be_taken_down() -> void:
	_build("surface", 1, 1, "base:wood_ceiling")
	var l1: String = w.levels.info.keys()[0]
	_build(l1, 1, 1, "base:wood_wall")
	eq(_req({"type": "dismantle", "location": "surface", "x": 1, "y": 1})["reason"], "occupied_above")
	eq(_req({"type": "dismantle", "location": l1, "x": 1, "y": 1}).get("ok"), true, "the wall above first")
	eq(_req({"type": "dismantle", "location": "surface", "x": 1, "y": 1}).get("ok"), true)
	eq(_cell(l1, "ground", 1, 1), "", "the floor above is gone with it")


func test_joining_ceilings_merges_buildings() -> void:
	for x in [0, 1, 4, 5]:
		_build("surface", x, 0, "base:wood_ceiling")
	eq(w.levels.buildings.size(), 2, "two buildings")
	var la := w.levels.level(_bld(0), 1)
	var lb := w.levels.level(_bld(5), 1)
	_build(la, 0, 0, "base:wood_wall")
	_build(lb, 5, 0, "base:wood_wall")
	_build("surface", 2, 0, "base:wood_ceiling")
	_build("surface", 3, 0, "base:wood_ceiling")  # joins them
	eq(w.levels.buildings.size(), 1, "one building")
	var l1 := w.levels.level(w.levels.buildings.keys()[0], 1)
	for x in range(0, 6):
		eq(_cell(l1, "ground", x, 0), "base:wood_floor", "floor at %d" % x)
	eq(_cell(l1, "structure", 0, 0), "base:wood_wall")
	eq(_cell(l1, "structure", 5, 0), "base:wood_wall")
	eq(_bld(0), _bld(5), "surface ceilings relabelled")
	w.close()
	_open()
	eq(w.levels.info.size(), 1, "one level after restart")
	eq(w.store.query_rows("SELECT count(DISTINCT location) AS n FROM chunks WHERE location != 'surface'")[0]["n"], 1, "absorbed level's chunks deleted")


func _bld(x: int) -> String:
	return String(w.chunk("surface", 0, 0).get_props(x, 0).get("ceiling", {}).get("building", ""))


func test_stairs_go_up_and_down_and_survive_restart() -> void:
	_build("surface", 5, 5, "base:wood_ceiling")
	var bad := _build("surface", 6, 6, "base:wood_stairs")
	eq(bad.get("reason", str(bad)), "no_opening_above")
	eq(_build("surface", 5, 5, "base:wood_stairs").get("ok"), true)
	var c := PortableCharacter.create("Аня", "base:humanoid_adult")
	w.enter("k", c)
	var a := c.character_id
	w.move_character(a, Vector2i(5 * 256 + 128, 4 * 256 + 128))
	var up := _req({"type": "climb", "location": "surface", "x": 5, "y": 5}, a)
	eq(up.get("ok"), true, str(up))
	eq(w.present[a]["location"], up["location"])
	eq(up["z"], 1)
	check(w.relocated.has(a), "the server will tell the client")
	eq(_req({"type": "dismantle", "location": "surface", "x": 5, "y": 5}).get("part"), "base:wood_stairs", "the stairs come down first")
	eq(_req({"type": "dismantle", "location": "surface", "x": 5, "y": 5}).get("reason"), "occupied_above", "someone stands on the hatch")
	eq(_req({"type": "climb", "location": up["location"], "x": 5, "y": 5}, a).get("reason"), "no_stairs")
	_build("surface", 5, 5, "base:wood_stairs")
	var down := _req({"type": "climb", "location": up["location"], "x": 5, "y": 5}, a)
	eq(down.get("location"), "surface")
	w.leave(a)
	w.close()
	_open()
	eq(w.levels.level(w.levels.buildings.keys()[0], 1), up["location"], "the level keeps its id")
	eq(_cell(up["location"], "ground", 5, 5), "base:wood_floor")


## Stairs over stairs: from the middle level one cell leads both ways, and
## the player chooses ("dir"); without a choice it is up, as before.
func test_stairs_over_stairs_lead_both_ways() -> void:
	_build("surface", 5, 5, "base:wood_ceiling")
	eq(_build("surface", 5, 5, "base:wood_stairs").get("ok"), true)
	var c := PortableCharacter.create("Аня", "base:humanoid_adult")
	w.enter("k", c)
	var a := c.character_id
	w.move_character(a, Vector2i(5 * 256 + 128, 4 * 256 + 128))
	var first: String = _req({"type": "climb", "location": "surface", "x": 5, "y": 5}, a)["location"]
	eq(_build(first, 5, 5, "base:wood_ceiling").get("ok"), true, "a ceiling over the first level")
	eq(_build(first, 5, 5, "base:wood_stairs").get("ok"), true, "stairs on the first level")
	var down := _req({"type": "climb", "location": first, "x": 5, "y": 5, "dir": "down"}, a)
	eq(down.get("location"), "surface", "down from the first level")
	eq(_req({"type": "climb", "location": "surface", "x": 5, "y": 5, "dir": "down"}, a).get("reason"), "no_stairs", "no way down from the surface")
	eq(_req({"type": "climb", "location": "surface", "x": 5, "y": 5}, a).get("location"), first)
	var up := _req({"type": "climb", "location": first, "x": 5, "y": 5}, a)
	eq(up.get("z"), 2, "up by default")
	eq(_req({"type": "climb", "location": up["location"], "x": 5, "y": 5, "dir": "up"}, a).get("reason"), "no_stairs", "no stairs up on the top")
	eq(_req({"type": "climb", "location": up["location"], "x": 5, "y": 5, "dir": "down"}, a).get("location"), first)
