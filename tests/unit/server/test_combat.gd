extends TestCase
## ADR-0019: health, blows within reach and arc, arrows over the plan, death
## of creatures and characters, the PvP rule, wolves, health coming back.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})
	_field()


func after_each() -> void:
	w.close()


## A clear field round (170, 170): grass, nothing growing, nobody else.
func _field() -> void:
	for cy in [4, 5, 6]:
		for cx in [4, 5, 6]:
			var c := w.chunk("surface", cx, cy)
			for id: String in w.creatures.in_chunk("surface", cx, cy):
				w.creatures.remove(id)
			for y in Chunk.SIZE:
				for x in Chunk.SIZE:
					c.set_cell("ground", x, y, "base:grass")
					c.set_cell("cover", x, y, "")


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func _player(name: String, cell: Vector2i) -> String:
	var c := PortableCharacter.create(name, "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, _at(cell))
	return c.character_id


## Takes `item` into the hands (as the client does before acting), then strikes.
func _attack(actor: String, aim_cell: Vector2i, item := "") -> Dictionary:
	w.handle(actor, {"request_id": Uuid.v4(), "type": "hold", "item": item})
	var r := {"request_id": Uuid.v4(), "type": "attack", "item": item, "x": _at(aim_cell).x, "y": _at(aim_cell).y}
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _ticks(n: int, near := Vector2i(170, 170)) -> void:
	for i in n:
		w.tick += 1
		w.advance_time()
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				w.mark_needed("surface", 5 + dx, 5 + dy)
		w.creatures.step(w.tick)
		w.combat.step(w.tick)


## Only arrows fly (creatures stand still: they would run from the archer).
func _fly(n: int) -> void:
	for i in n:
		w.tick += 1
		w.combat.step(w.tick)


func _items_at(cell: Vector2i) -> Dictionary:
	var out := {}
	for id: String in w.items:
		var it: Dictionary = w.items[id]
		if Movement.cell_of(Vector2i(it["x"], it["y"])) == cell:
			out[it["item"]] = int(out.get(it["item"], 0)) + int(it["count"])
	return out


func test_a_blow_hits_within_reach_and_arc_and_not_through_walls() -> void:
	w.world_time = 12 * Daylight.HOUR_MS
	var p := _player("Аня", Vector2i(170, 170))
	w.grant(p, "base:axe", 1)
	var deer := w.creatures._spawn("base:deer", "surface", Vector2i(171, 170), {}, 1)
	eq(_attack(p, Vector2i(170, 172), "base:axe").get("hit"), "", "aimed away: a miss")
	_ticks(20)
	deer.pos = _at(Vector2i(171, 170))
	eq(_attack(p, Vector2i(172, 170), "base:axe").get("hit"), deer.id, "aimed at it: a hit")
	eq(deer.health, 10 - 4, "an axe takes 4")
	eq(_attack(p, Vector2i(172, 170), "base:axe").get("reason"), "not_ready", "not again at once")
	eq(_attack(p, Vector2i(172, 170), "base:spear").get("reason"), "not_held", "only what is in the hands (and carried)")
	_ticks(20)
	deer.pos = _at(Vector2i(172, 170))
	w.grant("b", "base:plank", 10)
	w.handle("b", {"request_id": "wall", "type": "build", "location": "surface", "x": 171, "y": 169, "part": "base:wood_wall"})
	w.sync()
	deer.pos = _at(Vector2i(171, 168))
	eq(_attack(p, Vector2i(171, 168), "base:axe").get("hit"), "", "not round a wall's corner")
	check(deer.memory.has(p) and deer.memory[p]["what"] == "attacker", "it knows who hurt it")


func test_a_creature_that_dies_leaves_its_drops_and_is_gone_for_good() -> void:
	var p := _player("Аня", Vector2i(170, 170))
	w.grant(p, "base:axe", 1)
	var hare := w.creatures._spawn("base:hare", "surface", Vector2i(171, 170), {}, 1)
	var id := hare.id
	_attack(p, Vector2i(171, 170), "base:axe")
	check(not w.creatures.has(id), "an axe kills a hare (3 health)")
	eq(_items_at(Vector2i(171, 170)), {"base:raw_meat": 1}, "its meat lies where it fell")
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	check(not w.creatures.has(id), "not back after a restart")
	eq(_items_at(Vector2i(171, 170)), {}, "nor its meat: a restart clears the ground (ADR-0016)")


func test_characters_hurt_characters_only_where_the_rules_allow() -> void:
	var a := _player("Аня", Vector2i(170, 170))
	var b := _player("Боря", Vector2i(171, 170))
	eq(_attack(a, Vector2i(171, 170)).get("hit"), "", "PvE: no")
	eq(w.combat.health_of(b), 20)
	w.combat.pvp = "free"
	_ticks(20)
	eq(_attack(a, Vector2i(171, 170)).get("hit"), b, "free PvP: bare hands")
	eq(w.combat.health_of(b), 19)


func test_a_character_that_dies_leaves_what_it_carried_and_comes_back() -> void:
	w.spawn_position = _at(Vector2i(160, 160))
	var a := _player("Аня", Vector2i(170, 170))
	w.grant(a, "base:plank", 7)
	w.combat.hurt(a, 5, "")
	w.flush_state()
	w.close()
	w = ServerWorld.open(_db, _content)
	w.spawn_position = _at(Vector2i(160, 160))
	var c := PortableCharacter.new()
	# The same character comes back (its world copy is used).
	var known: Dictionary = w._known_character(a)
	c.character_id = a
	w.enter(known["owner"], PortableCharacter.from_data(known["data"]))
	eq(w.combat.health_of(a), 15, "health is kept over a restart")
	w.combat.hurt(a, 30, "")
	eq(w.present[a]["pos"], _at(Vector2i(160, 160)), "back at the spawn point")
	eq(w.combat.health_of(a), 20, "whole again")
	eq(int(w.present[a]["deaths"]), 1)
	eq(w.inventory(a).count("base:plank"), 0, "what it carried...")
	eq(int(_items_at(Vector2i(170, 170)).get("base:plank", 0)), 7, "...lies where it fell")
	w.combat.death_drops = false
	w.grant(a, "base:stone", 3)
	w.combat.hurt(a, 30, "")
	eq(w.inventory(a).count("base:stone"), 3, "kept where the world says so")


func test_an_arrow_flies_hits_the_first_in_its_way_and_misses_fall() -> void:
	w.world_time = 12 * Daylight.HOUR_MS
	var p := _player("Аня", Vector2i(170, 170))
	w.grant(p, "base:bow", 1)
	w.grant(p, "base:arrow", 2)
	var deer := w.creatures._spawn("base:deer", "surface", Vector2i(176, 170), {}, 1)
	deer.pos = _at(Vector2i(176, 170))
	check(_attack(p, Vector2i(180, 170), "base:bow").get("ok", false), "shot")
	eq(w.inventory(p).count("base:arrow"), 1, "an arrow less")
	eq(w.combat.projectiles.size(), 1, "it flies")
	_fly(8)
	eq(w.combat.projectiles.size(), 0, "and is done")
	eq(deer.health, 10 - 5, "it hit the deer on its way")
	w.grant("b", "base:plank", 10)
	w.handle("b", {"request_id": "wall", "type": "build", "location": "surface", "x": 170, "y": 175, "part": "base:wood_wall"})
	w.sync()
	_fly(20)
	_attack(p, Vector2i(170, 180), "base:bow")
	_fly(8)
	eq(_items_at(Vector2i(170, 174)), {"base:arrow": 1}, "a wall stops it; it lies before the wall")
	_fly(20)
	eq(_attack(p, Vector2i(170, 180), "base:bow").get("reason"), "no_ammo", "no arrows left")


func test_a_wolf_hunts_by_night_keeps_off_by_day_and_runs_when_hurt() -> void:
	var p := _player("Аня", Vector2i(170, 170))
	var wolf := w.creatures._spawn("base:wolf", "surface", Vector2i(190, 170), {}, 1)
	w.world_time = 12 * Daylight.HOUR_MS
	_ticks(80)
	eq(w.combat.health_of(p), 20, "by day, outside its territory, it leaves one alone")
	wolf.pos = _at(Vector2i(178, 170))
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS
	wolf.last_time = w.world_time
	_ticks(60)
	check(w.combat.health_of(p) < 20, "by night it comes and bites: %d" % w.combat.health_of(p))
	var before := wolf.cell()
	w.combat.hurt(wolf.id, 11, p)
	_ticks(5)
	check(wolf.state == "flee", "badly hurt, it runs: " + wolf.state)
	_ticks(30)
	check(Vector2(wolf.cell()).distance_to(Vector2(170, 170)) > Vector2(before).distance_to(Vector2(170, 170)) + 5, "away")


func test_health_comes_back_after_a_while() -> void:
	var p := _player("Аня", Vector2i(170, 170))
	w.combat.hurt(p, 6, "")
	_ticks(Combat.REGEN_AFTER - 20)
	eq(w.combat.health_of(p), 14, "not at once")
	_ticks(Combat.REGEN_EVERY * 10)
	check(w.combat.health_of(p) > 14, "then slowly back: %d" % w.combat.health_of(p))


## A wall with a walkway on top (ceilings over it) along y = 168, x 166..174;
## a second level over the middle. Returns [level 1, level 2].
func _walkway() -> Array:
	w.grant("b", "base:plank", 200)
	for x in range(166, 175):
		for y in [167, 168]:
			if y == 168:
				w.handle("b", {"request_id": "w%d" % x, "type": "build", "location": "surface", "x": x, "y": y, "part": "base:wood_wall"})
			w.handle("b", {"request_id": "c%d_%d" % [x, y], "type": "build", "location": "surface", "x": x, "y": y, "part": "base:wood_ceiling"})
	w.sync()
	var l1 := w.levels.level(w._ceiling_building("surface", 170, 168), 1)
	w.handle("b", {"request_id": "up", "type": "build", "location": l1, "x": 170, "y": 167, "part": "base:wood_ceiling"})
	w.sync()
	return [l1, w.levels.level(w._ceiling_building("surface", 170, 168), 2)]


func _do(actor: String, r: Dictionary) -> Dictionary:
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _place(id: String, location: String, cell: Vector2i) -> void:
	w.present[id]["location"] = location
	w.move_character(id, _at(cell))


func test_arrows_from_a_walkway_into_the_street_and_back_up() -> void:
	w.world_time = 12 * Daylight.HOUR_MS
	var l := _walkway()
	var p := _player("Аня", Vector2i(170, 160))
	_place(p, l[0], Vector2i(170, 168))
	w.grant(p, "base:bow", 1)
	w.grant(p, "base:arrow", 5)
	var deer := w.creatures._spawn("base:deer", "surface", Vector2i(170, 175), {}, 1)
	deer.pos = _at(Vector2i(170, 175))
	check(_attack(p, Vector2i(170, 175), "base:bow").get("ok", false), "shot down from the walkway")
	_fly(12)
	eq(deer.health, 5, "over the wall, into the deer in the street")
	# From the street up at one on the walkway (free PvP here).
	w.creatures.remove(deer.id)  # else the arrow meets it first, on its way up
	w.combat.pvp = "free"
	var q := _player("Боря", Vector2i(170, 176))
	w.grant(q, "base:bow", 1)
	w.grant(q, "base:arrow", 5)
	var r := {"request_id": "up", "type": "attack", "item": "base:bow", "x": _at(Vector2i(170, 168)).x, "y": _at(Vector2i(170, 168)).y, "z": 1}
	w.handle(q, {"request_id": "hold-up", "type": "hold", "item": "base:bow"})
	w.handle(q, r)
	w.sync()
	_fly(12)
	eq(w.combat.health_of(p), 15, "up at the one on the walkway")


func test_jumping_off_a_level() -> void:
	var l := _walkway()
	var p := _player("Аня", Vector2i(170, 160))
	_place(p, l[0], Vector2i(170, 168))
	eq(_do(p, {"request_id": "j0", "type": "jump", "dx": -1, "dy": 0}).get("reason"), "not_an_edge", "the walkway goes on: walk")
	w.handle(p, {"request_id": "j1", "type": "jump", "dx": 0, "dy": 1})
	w.sync()
	eq(w.present[p]["location"], "surface", "down in the street")
	eq(Movement.cell_of(w.present[p]["pos"]), Vector2i(170, 169), "right below the edge")
	eq(w.combat.health_of(p), 18, "a fall of one level hurts a little")
	# From the second level, over the walkway, onto... the walkway below.
	_place(p, l[1], Vector2i(170, 167))
	w.handle(p, {"request_id": "j2", "type": "jump", "dx": 1, "dy": 0})
	w.sync()
	eq(w.present[p]["location"], l[0], "onto the floor below, not through it")
	eq(w.combat.health_of(p), 16)
	# Into a wall: no.
	w.grant("b", "base:plank", 10)
	w.handle("b", {"request_id": "wall", "type": "build", "location": "surface", "x": 165, "y": 168, "part": "base:wood_wall"})
	w.sync()
	_place(p, l[0], Vector2i(166, 168))
	eq(_do(p, {"request_id": "j3", "type": "jump", "dx": -1, "dy": 0}).get("reason"), "blocked", "not into a wall")


func test_armour_takes_off_every_blow_but_a_blow_always_tells() -> void:
	var a := _player("Аня", Vector2i(170, 170))
	var b := _player("Боря", Vector2i(171, 170))
	w.combat.pvp = "free"
	w.grant(a, "base:spear", 1)
	_ticks(20)
	eq(_attack(a, Vector2i(171, 170), "base:spear").get("hit"), b)
	var spear := int(_content.get_def("base:spear")["weapon"]["damage"])
	eq(w.combat.health_of(b), 20 - spear, "unarmoured: the whole blow")
	w.combat.heal(b, 20)
	for item: String in ["base:leather_armor", "base:iron_helmet"]:
		w.grant(b, item, 1)
		w.handle(b, {"request_id": Uuid.v4(), "type": "equip", "item": item})
	w.sync()
	eq(w.combat.armor_of(b), 3, "leather 2 and a helmet 1")
	_ticks(20)
	eq(_attack(a, Vector2i(171, 170), "base:spear").get("hit"), b)
	eq(w.combat.health_of(b), 20 - (spear - 3), "three off the blow")
	w.combat.heal(b, 20)
	_ticks(20)
	_attack(a, Vector2i(171, 170), "")
	eq(w.combat.health_of(b), 19, "a fist on armour still tells")
	w.combat.hurt(b, 5, "")
	eq(w.combat.health_of(b), 14, "not a blow (a fall): armour does nothing")
	check(not ContentRegistry.from_defs([{"id": "test:x", "kind": "item", "armor": 2}]).errors.is_empty(),
		"armour on what is not worn: a content error")
	check(not ContentRegistry.from_defs([{"id": "test:x", "kind": "item", "equip_slot": "torso", "armor": -1}]).errors.is_empty(),
		"negative armour: a content error")


## What a creature does when struck is data ("reaction"): a hare runs; a
## poring strikes back, and another poring that sees it joins in; one too far
## to see stays as it was.
func test_struck_ones_run_or_strike_back_and_kin_stand_up_for_them() -> void:
	var p := _player("Аня", Vector2i(170, 170))
	w.world_time = 12 * Daylight.HOUR_MS
	var hare := w.creatures._spawn("base:hare", "surface", Vector2i(171, 170), {}, 1)
	var poring := w.creatures._spawn("base:poring", "surface", Vector2i(170, 172), {}, 2)
	var kin := w.creatures._spawn("base:poring", "surface", Vector2i(174, 172), {}, 3)
	var far := w.creatures._spawn("base:poring", "surface", Vector2i(192, 190), {}, 4)
	for c: Creature in [hare, poring, kin, far]:
		c.last_time = w.world_time
	w.combat.hurt(hare.id, 1, p)
	w.combat.hurt(poring.id, 1, p)
	_ticks(4)
	eq(hare.state, "flee", "a hare runs")
	check(poring.state in ["hunt", "attack"], "a poring goes for who struck it: " + poring.state)
	check(kin.state in ["hunt", "attack"], "its kin that saw it too: " + kin.state)
	check(not far.state in ["hunt", "attack"], "one that did not see it, not: " + far.state)
	_ticks(80)
	check(w.combat.health_of(p) < 20, "and they bite: %d" % w.combat.health_of(p))


## Game runs slower than a running character: a hunter with a spear can catch up.
func test_game_is_slower_than_a_running_hunter() -> void:
	for kind: String in ["base:hare", "base:deer", "base:sheep", "base:cow", "base:chicken"]:
		var d := _content.get_def(kind)
		check(float(d["run_speed"]) * Movement.WALK < Movement.RUN, "%s runs slower than a character" % kind)
