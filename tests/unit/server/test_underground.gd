extends TestCase
## ADR-0017: one geology for the world, made chunk by chunk and kept; a way
## down near the spawn point; climbing down and up; digging with a pick;
## shafts to the next depth; a headframe from the surface into the same
## depth as everyone's; the hole stays when the equipment goes; darkness.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry
const B := "builder"


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 21})


func after_each() -> void:
	w.close()


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _player(cell: Vector2i, location := "surface") -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.present[c.character_id]["location"] = location
	w.move_character(c.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	return c.character_id


func _part(loc: String, cell: Vector2i) -> String:
	return w._part_at(loc, cell.x, cell.y, "structure")


func _spawn_way() -> Vector2i:
	return w._spawn_way()


## Rock nearest to `from` on a depth, beside open floor (where one can stand).
func _rock_beside_floor(loc: String, from: Vector2i, kind := "") -> Array:
	for r in range(1, 30):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := from + Vector2i(dx, dy)
				var part := _part(loc, c)
				if part == "" or _content.get_def(part).get("role") != "rock" or (kind != "" and part != kind):
					continue
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if _part(loc, c + d) == "" and not w.is_solid(loc, c.x + d.x, c.y + d.y):
						return [c, c + d]
	return []


func test_the_same_seed_makes_the_same_geology_and_it_is_kept() -> void:
	var a := w.chunk("depth:-2", 3, -1)
	var other := ServerWorld.open(tmp_dir().path_join("other.db"), _content, {"seed": 21})
	check(a.same_as(other.chunk("depth:-2", 3, -1)), "one seed, one geology")
	check(not a.same_as(other.chunk("depth:-3", 3, -1)), "another depth, other rock")
	other.close()
	w.sync()
	check(not w.store.get_chunk("depth:-2", 3, -1).is_empty(), "made once and stored at once")
	eq(w.levels.kind("depth:-2"), Levels.DEPTH)
	eq(w.levels.z("depth:-2"), -2)


func test_a_way_down_near_the_spawn_point_and_back_up() -> void:
	var way := _spawn_way()
	eq(_part("surface", way), "base:cave_mouth", "a cave mouth on the surface")
	eq(_part("depth:-1", way), "base:cave_climb", "and a way up below it")
	check(not w.is_solid("depth:-1", way.x + 1, way.y), "in a hollow")
	var p := _player(way)
	var r := _req(p, {"type": "climb", "location": "surface", "x": way.x, "y": way.y})
	eq(r.get("location"), "depth:-1", "down")
	eq(w.present[p]["location"], "depth:-1")
	r = _req(p, {"type": "climb", "location": "depth:-1", "x": way.x, "y": way.y})
	eq(r.get("location"), "surface", "and up again")
	w.close()
	w = ServerWorld.open(_db, _content)
	eq(_spawn_way(), way, "the same way after a restart")
	eq(_part("surface", way), "base:cave_mouth")


func test_digging_needs_a_pick_in_hand_and_gives_what_the_rock_holds() -> void:
	var way := _spawn_way()
	var at := _rock_beside_floor("depth:-1", way)
	check(not at.is_empty(), "rock beside the hollow")
	var rock: String = _part("depth:-1", at[0])
	var p := _player(at[1], "depth:-1")
	eq(_req(p, {"type": "gather", "location": "depth:-1", "x": at[0].x, "y": at[0].y, "item": ""}).get("reason"), "no_tool",
		"not with bare hands")
	eq(_req(p, {"type": "gather", "location": "depth:-1", "x": at[0].x, "y": at[0].y, "item": "base:pickaxe"}).get("reason"),
		"not_held", "a pick one has in the hands")
	eq(_req(p, {"type": "dismantle", "location": "depth:-1", "x": at[0].x, "y": at[0].y}).get("reason"), "natural",
		"rock is dug, not taken apart")
	w.grant(p, "base:pickaxe", 1)
	w.grant(p, "base:axe", 1)
	eq(_req(p, {"type": "gather", "location": "depth:-1", "x": at[0].x, "y": at[0].y, "item": "base:pickaxe"}).get("reason"),
		"not_held", "carried is not enough: the pick must be in the hands")
	_req(p, {"type": "hold", "item": "base:axe"})
	eq(_req(p, {"type": "gather", "location": "depth:-1", "x": at[0].x, "y": at[0].y, "item": "base:axe"}).get("reason"),
		"no_tool", "an axe does not dig")
	_req(p, {"type": "hold", "item": "base:pickaxe"})
	var stone := w.inventory(p).count("base:stone")
	var r := _req(p, {"type": "gather", "location": "depth:-1", "x": at[0].x, "y": at[0].y, "item": "base:pickaxe"})
	check(r.get("ok", false), "dug: %s" % r)
	eq(_part("depth:-1", at[0]), "", "the cell is open now")
	check(w.inventory(p).count("base:stone") > stone or rock != "base:rock", "stone from rock")
	w.close()
	w = ServerWorld.open(_db, _content)
	eq(_part("depth:-1", at[0]), "", "still dug after a restart")
	# Ore gives ore: put a vein's rock beside one and dig it.
	var q := _player(at[1], "depth:-1")
	w.grant(q, "base:pickaxe", 1)
	_req(q, {"type": "hold", "item": "base:pickaxe"})
	var c := w.chunk("depth:-1", floori(at[0].x / 32.0), floori(at[0].y / 32.0))
	c.set_cell("structure", posmod(at[0].x, 32), posmod(at[0].y, 32), "base:iron_ore_rock")
	_req(q, {"type": "gather", "location": "depth:-1", "x": at[0].x, "y": at[0].y, "item": "base:pickaxe"})
	eq(w.inventory(q).count("base:iron_ore"), 1, "iron ore from its vein")


func test_a_shaft_to_the_next_depth_opens_a_working_with_a_ladder() -> void:
	var way := _spawn_way()
	var spot := way + Vector2i(1, 1)
	var p := _player(way, "depth:-1")
	w.grant(p, "base:plank", 20)
	w.grant(p, "base:log", 5)
	w.present[p]["location"] = "surface"  # up there for a moment
	eq(_req(p, {"type": "build", "location": "surface", "x": way.x + 1, "y": way.y + 1, "part": "base:mine_shaft"}).get("reason"),
		"wrong_place", "a mine shaft is dug underground")
	w.present[p]["location"] = "depth:-1"
	var r := _req(p, {"type": "build", "location": "depth:-1", "x": spot.x, "y": spot.y, "part": "base:mine_shaft"})
	check(r.get("ok", false), "built: %s" % r)
	eq(_part("depth:-2", spot), "base:mine_ladder", "a ladder up in the depth below")
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, -1)]:
		check(not w.is_solid("depth:-2", spot.x + d.x, spot.y + d.y), "a small working round it")
	w.move_character(p, spot * Movement.UNIT + Vector2i(128, 128))
	eq(_req(p, {"type": "climb", "location": "depth:-1", "x": spot.x, "y": spot.y}).get("location"), "depth:-2", "down the shaft")
	eq(_req(p, {"type": "climb", "location": "depth:-2", "x": spot.x, "y": spot.y}).get("location"), "depth:-1", "up the ladder")
	eq(_req(p, {"type": "build", "location": "depth:-1", "x": spot.x + 1, "y": spot.y, "part": "base:wood_ceiling"}).get("reason"),
		"underground", "up is the depth above, not a ceiling")


func test_a_headframe_leads_into_the_same_depth_and_its_hole_stays() -> void:
	var way := _spawn_way()
	var far := way + Vector2i(40, 6)
	var cx := floori(far.x / 32.0)
	var cy := floori(far.y / 32.0)
	var sc := w.chunk("surface", cx, cy)
	sc.set_cell("ground", posmod(far.x, 32), posmod(far.y, 32), "base:grass")
	sc.set_cell("cover", posmod(far.x, 32), posmod(far.y, 32), "")
	sc.set_cell("structure", posmod(far.x, 32), posmod(far.y, 32), "")
	var p := _player(far + Vector2i(1, 0))
	eq(_req(p, {"type": "build", "location": "surface", "x": far.x, "y": far.y, "part": "base:headframe"}).get("reason"),
		"materials", "a headframe costs a great deal")
	for id: String in _content.structure_cost("base:headframe"):
		w.grant(p, id, int(_content.structure_cost("base:headframe")[id]))
	check(_req(p, {"type": "build", "location": "surface", "x": far.x, "y": far.y, "part": "base:headframe"}).get("ok", false), "built")
	w.move_character(p, far * Movement.UNIT + Vector2i(128, 128))
	var r := _req(p, {"type": "climb", "location": "surface", "x": far.x, "y": far.y})
	eq(r.get("location"), "depth:-1", "into the one depth -1 everybody shares")
	eq(_part("depth:-1", far), "base:mine_ladder")
	_req(p, {"type": "climb", "location": "depth:-1", "x": far.x, "y": far.y})
	check(_req(p, {"type": "dismantle", "location": "surface", "x": far.x, "y": far.y}).get("ok", false), "taken down")
	eq(_part("surface", far), "base:shaft_hole", "the hole stays")
	eq(_part("depth:-1", far), "base:mine_ladder", "and the working below")
	eq(_req(p, {"type": "climb", "location": "surface", "x": far.x, "y": far.y}).get("location"), "depth:-1", "still a way down")


func test_no_daylight_underground_only_torches() -> void:
	w.world_time = 12 * Daylight.HOUR_MS
	var way := _spawn_way()
	check(w.light_at("surface", way) > 0.9, "noon above")
	eq(w.light_at("depth:-1", way + Vector2i(1, 0)), 0.0, "dark below")
	w.grant(B, "base:log", 2)
	_req(B, {"type": "build", "location": "depth:-1", "x": way.x + 1, "y": way.y + 1, "part": "base:torch"})
	check(w.light_at("depth:-1", way + Vector2i(1, 0)) > 0.5, "a torch lights it")


## Passive and hostile creatures below (ADR-0017 p. 8): depths are
## populated as they are made; a spider hunts at noon too (no day below).
func test_creatures_live_below_and_a_spider_hunts_in_the_dark() -> void:
	var found := {}
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			w.chunk("depth:-1", cx, cy)
	for c: Creature in w.creatures.creatures.values():
		if c.location == "depth:-1":
			found[c.kind] = true
	check(found.has("base:cave_rat") and found.has("base:cave_spider"), "rats and spiders below: %s" % found)
	var way := _spawn_way()
	var p := _player(way + Vector2i(1, 0), "depth:-1")
	var spider := w.creatures._spawn("base:cave_spider", "depth:-1", way + Vector2i(-1, 1), {}, 3)
	w.world_time = 12 * Daylight.HOUR_MS
	for i in 120:
		w.tick += 1
		w.advance_time()
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				w.mark_needed("depth:-1", floori(way.x / 32.0) + dx, floori(way.y / 32.0) + dy)
		w.creatures.step(w.tick)
		w.combat.step(w.tick)
	check(w.combat.health_of(p) < 20 or int(w.present[p]["deaths"]) > 0, "bitten in the dark at noon: %s" % spider.state)


## ADR-0021: trees are felled with an axe in hand, in blows by their size
## and wood (an oak 15, at the axe's pace; the work done is kept with the
## tree); taking apart names its layer (a roof, not the wall under it).
func test_felling_a_tree_and_taking_apart_a_chosen_layer() -> void:
	var c := w.chunk("surface", 3, 3)
	c.set_cell("ground", 5, 5, "base:grass")
	c.set_cell("cover", 5, 5, "base:oak")
	c.set_cell("cover", 6, 5, "base:birch")
	var p := _player(Vector2i(100, 101))
	w.grant(p, "base:axe", 1)
	_req(p, {"type": "hold", "item": "base:axe"})
	var fell := {"type": "gather", "location": "surface", "x": 101, "y": 101, "layer": "cover", "item": "base:axe"}
	var r := _req(p, fell.duplicate())
	eq([r.get("work"), r.get("of")], [1, 15], "a blow: one of fifteen")
	eq(_req(p, fell.duplicate()).get("reason"), "not_ready", "not faster than the axe swings")
	var blows := 1
	while blows < 40 and not r.has("drops"):
		w.tick += 14  # the axe's 0.7 s
		w.combat.step(w.tick)
		r = _req(p, fell.duplicate())
		blows += 1
		if blows == 7:
			w.flush_state()
			w.chunk("surface", 3, 3).get_props(5, 5)  # the work is with the tree
			eq(int((w.chunk("surface", 3, 3).get_props(5, 5).get("cover", {}) as Dictionary).get("work", 0)), 7)
	eq(blows, 15, "an oak falls at the fifteenth blow (about ten seconds)")
	eq(w.inventory(p).count("base:log"), 3, "an oak gives three logs")
	eq(w.chunk("surface", 3, 3).get_cell("cover", 5, 5), "base:stump", "the tree is gone: a stump left (ADR-0056)")
	check(not (w.chunk("surface", 3, 3).get_props(5, 5).get("cover", {}) as Dictionary).has("work"), "and the work done on it")
	eq(_content.get_def("base:birch")["gather"]["work"], 8, "a birch, thinner: eight")
	w.grant(p, "base:plank", 20)
	w.grant(p, "base:log", 5)
	_req(p, {"type": "build", "location": "surface", "x": 102, "y": 100, "part": "base:wood_wall"})
	_req(p, {"type": "build", "location": "surface", "x": 102, "y": 100, "part": "base:thatch_roof"})
	r = _req(p, {"type": "dismantle", "location": "surface", "x": 102, "y": 100, "layer": "roof"})
	eq(r.get("part"), "base:thatch_roof", "the roof, as asked")
	eq(_part("surface", Vector2i(102, 100)), "base:wood_wall", "the wall stays")


## Arrows fly below as on the surface: the depth's heights are under 0, yet
## an arrow there is not "in the ground" at once; it flies, hits, falls far.
func test_arrows_fly_underground() -> void:
	var loc := "depth:-1"
	var at := Vector2i(400, 400)
	for y in range(at.y - 2, at.y + 3):
		for x in range(at.x - 2, at.x + 20):  # an open gallery to shoot along
			var c := w.chunk(loc, floori(x / 32.0), floori(y / 32.0))
			c.set_cell("structure", posmod(x, 32), posmod(y, 32), "")
			c.set_cell("ground", posmod(x, 32), posmod(y, 32), "base:cave_floor")
	for id: String in w.creatures.creatures.keys():
		if w.creatures.creatures[id].location == loc:
			w.creatures.remove(id)
	var p := _player(at, loc)
	w.grant(p, "base:bow", 1)
	w.grant(p, "base:arrow", 2)
	_req(p, {"type": "hold", "item": "base:bow"})
	var rat := w.creatures._spawn("base:cave_rat", loc, at + Vector2i(6, 0), {}, 1)
	var hp := rat.health
	var aim := (at + Vector2i(12, 0)) * Movement.UNIT + Vector2i(128, 128)
	check(_req(p, {"type": "attack", "item": "base:bow", "x": aim.x, "y": aim.y}).get("ok", false), "shot")
	for i in 3:
		w.tick += 1
		w.combat.step(w.tick)
	eq(w.combat.projectiles.size(), 1, "it flies, not dropped where it was shot")
	if not w.combat.projectiles.is_empty():
		var pr: Combat.Projectile = w.combat.projectiles.values()[0]
		check(Movement.cell_of(Vector2i(pr.pos)).x > at.x + 1, "away from the bow")
	for i in 30:
		w.tick += 1
		w.combat.step(w.tick)
	check(rat.health < hp or not w.creatures.has(rat.id), "it hit the rat on its way")
	w.creatures.remove(rat.id)
	w.tick += 40
	w.combat.step(w.tick)
	_req(p, {"type": "attack", "item": "base:bow", "x": aim.x, "y": aim.y})
	for i in 40:
		w.tick += 1
		w.combat.step(w.tick)
	var lying := -1
	for id: String in w.items:
		if w.items[id]["location"] == loc and w.items[id]["item"] == "base:arrow":
			lying = Movement.cell_of(Vector2i(w.items[id]["x"], w.items[id]["y"])).x
	check(lying > at.x + 10, "a miss falls far away, at its range or a wall: %d" % lying)


## Open cells 4 to 6 cells round a way (outside its hollow), in its depth.
func _open_round_way(g: UndergroundGenerator, z: int, at: Vector2i) -> int:
	var chunks := {}
	var open := 0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var d2 := dx * dx + dy * dy
			if d2 <= 10 or d2 > 36:
				continue
			var p := at + Vector2i(dx, dy)
			var k := Vector2i(floori(p.x / 32.0), floori(p.y / 32.0))
			if not chunks.has(k):
				chunks[k] = g.generate(z, k.x, k.y)
			if (chunks[k] as Chunk).get_cell("structure", p.x - k.x * 32, p.y - k.y * 32) == "":
				open += 1
	return open


func test_ways_up_and_down_open_on_caves_not_walled_in() -> void:
	var g := UndergroundGenerator.new(12345, _content)
	var ways := 0
	for z in [-1, -2]:
		for cy in range(-8, 8):
			for cx in range(-8, 8):
				for way: Vector2i in [g.entrance_at(z, cx, cy), g.entrance_at(z - 1, cx, cy)]:
					if way == UndergroundGenerator.NONE:
						continue
					ways += 1
					check(_open_round_way(g, z, way) > 0, "depth %d, way at %s: walled in" % [z, way])
	check(ways > 10, "ways enough to say so: %d" % ways)
	# A tunnel crossing a chunk's edge is dug alike whichever chunk comes first.
	var a := UndergroundGenerator.new(12345, _content)
	var b := UndergroundGenerator.new(12345, _content)
	for cy in range(-8, 8):
		for cx in range(-8, 8):
			var first := a.generate(-1, cx, cy)
			var second := b.generate(-1, -1 - cx, -1 - cy)  # another order
			check(first != null and second != null, "made")
	for cy in range(-8, 8):
		for cx in range(-8, 8):
			check(a.generate(-1, cx, cy).same_as(b.generate(-1, cx, cy)), "chunk %d,%d the same either way" % [cx, cy])
