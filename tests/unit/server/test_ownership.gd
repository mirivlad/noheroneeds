extends TestCase
## ADR-0016 (the author's rules of 15.10.2026): buildings are nobody's to
## defend but by what they are made of — anyone breaks or mends anything,
## stone takes long; only the one who set a part up takes it apart whole.
## Doors open to all unless their maker locks them with a code; chests open
## to their owner and the owner's friends; what the dead dropped is theirs
## for ten minutes; the ground is cleared when the world starts again.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 5})
	_clear()


func after_each() -> void:
	w.close()


func _clear() -> void:
	var c := w.chunk("surface", 0, 0)
	for y in 10:
		for x in 10:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
	for id: String in w.creatures.in_chunk("surface", 0, 0):
		w.creatures.remove(id)


func _player(name: String, cell := Vector2i(3, 3)) -> String:
	var c := PortableCharacter.create(name, "base:humanoid_adult")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _at(x: int, r: Dictionary) -> Dictionary:
	r.merge({"location": "surface", "x": x, "y": 3})
	return r


## Strikes until it breaks or `most` blows: [blows, last result].
func _break(actor: String, x: int, most: int) -> Array:
	var r := {}
	for i in most:
		w.tick += 20
		w.combat.step(w.tick)
		r = _req(actor, _at(x, {"type": "strike_part"}))
		if r.has("broken"):
			return [i + 1, r]
	return [most, r]


func test_anyone_breaks_and_stone_takes_long() -> void:
	var a := _player("Аня")
	w.grant(a, "base:plank", 20)
	w.grant(a, "base:stone", 10)
	_req(a, _at(4, {"type": "build", "part": "base:wood_wall"}))
	_req(a, _at(5, {"type": "build", "part": "base:stone_wall"}))
	var b := _player("Боря")
	w.grant(b, "base:axe", 1)
	w.grant(b, "base:pickaxe", 1)
	w.grant(b, "base:plank", 10)
	eq(_req(b, _at(4, {"type": "dismantle"})).get("reason"), "not_owner", "not taken apart whole by another")
	_req(b, {"type": "hold", "item": "base:axe"})
	eq(_req(b, _at(4, {"type": "strike_part"})).get("damage"), 4, "but broken: an axe on wood")
	check(_req(b, _at(4, {"type": "repair"})).get("ok", false), "and mended by anyone")
	w.move_character(b, Vector2i(4 * 256 + 128, 4 * 256 + 128))  # within an axe's reach of the stone
	w.tick += 20
	w.combat.step(w.tick)
	eq(_req(b, _at(5, {"type": "strike_part"})).get("damage"), 0, "an axe hardly scratches stone")
	eq(float(w.chunk("surface", 0, 0).get_props(5, 3).get("damage")), 0.6, "a share of a blow is kept")
	_req(b, {"type": "hold", "item": "base:pickaxe"})
	var r := _break(b, 5, 1000)
	eq(r[0], 400, "a pick breaks a stone wall, but in 400 blows (some five minutes)")
	eq(r[1].get("broken"), "base:stone_wall")
	eq(w.chunk("surface", 0, 0).get_cell("structure", 5, 3), "", "gone")


func test_a_chest_opens_for_friends_and_spills_when_broken() -> void:
	var a := _player("Аня")
	var b := _player("Боря")
	w.grant(a, "base:plank", 20)
	w.grant(a, "base:stone", 9)
	_req(a, _at(4, {"type": "build", "part": "base:chest"}))
	_req(a, _at(4, {"type": "store", "item": "base:stone", "count": 9}))
	eq(_req(b, _at(4, {"type": "look_in"})).get("reason"), "not_owner")
	eq(_req(a, {"type": "befriend", "character": "nobody-known"}).get("reason"), "bad_request")
	eq(_req(a, {"type": "befriend", "character": b}).get("friends"), [b])
	eq(_req(b, _at(4, {"type": "look_in"})).get("contents"), {"base:stone": 9}, "a friend opens it")
	w.flush_state()
	w.close()
	w = ServerWorld.open(_db, _content)
	check(w.is_friend(a, b), "friends kept over a restart")
	check(not w.is_friend(b, a), "one way: it is Аня's list")
	for who: String in [a, b]:
		var known: Dictionary = w._known_character(who)
		w.enter(known["owner"], PortableCharacter.from_data(known["data"]))
		w.move_character(who, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	_req(a, {"type": "unfriend", "character": b})
	eq(_req(b, _at(4, {"type": "look_in"})).get("reason"), "not_owner", "no more")
	w.grant(b, "base:axe", 1)
	_req(b, {"type": "hold", "item": "base:axe"})
	var r := _break(b, 4, 40)
	eq(r[0], 15, "a chest takes 15 axe blows")
	var lying := {}
	for id: String in w.items:
		lying[w.items[id]["item"]] = int(lying.get(w.items[id]["item"], 0)) + int(w.items[id]["count"])
	eq(lying, {"base:stone": 9, "base:plank": 3}, "what it held and half of it lie there")


func test_a_door_locks_with_a_code() -> void:
	var a := _player("Аня")
	var b := _player("Боря")
	var c := _player("Вера")
	w.grant(a, "base:plank", 20)
	_req(a, _at(4, {"type": "build", "part": "base:wood_door"}))
	eq(_req(b, _at(4, {"type": "use"})).get("open"), true, "a door opens to anyone")
	_req(b, _at(4, {"type": "use"}))
	eq(_req(b, _at(4, {"type": "lock", "pin": "1234"})).get("reason"), "not_owner", "only its maker locks it")
	for bad: Variant in ["12a4", "123", "12345", "-123", 1234]:
		eq(_req(a, _at(4, {"type": "lock", "pin": bad})).get("reason"), "bad_pin", "not a code: %s" % str(bad))
	check(_req(a, _at(4, {"type": "lock", "pin": "1234"})).get("locked", false), "locked")
	var props := w.chunk("surface", 0, 0).get_props(4, 3)
	check(props.get("locked", false) and not str(props).contains("1234"), "seen as locked; the code never goes with the chunk")
	eq(_req(b, _at(4, {"type": "use"})).get("reason"), "locked", "the code is asked for")
	for i in 3:
		eq(_req(b, _at(4, {"type": "use", "pin": "0000"})).get("reason"), "wrong_pin")
	eq(_req(b, _at(4, {"type": "use", "pin": "1234"})).get("reason"), "pin_wait", "three wrong: one waits")
	w.tick += ServerWorld.PIN_WAIT_TICKS
	eq(_req(b, _at(4, {"type": "use", "pin": "1234"})).get("open"), true, "the right code, later")
	_req(b, _at(4, {"type": "use"}))
	eq(_req(b, _at(4, {"type": "use"})).get("open"), true, "known now: no code again")
	_req(b, _at(4, {"type": "use"}))
	eq(_req(a, _at(4, {"type": "use"})).get("open"), true, "its maker needs none")
	_req(a, _at(4, {"type": "use"}))
	_req(a, _at(4, {"type": "lock", "pin": "5678"}))
	eq(_req(b, _at(4, {"type": "use"})).get("reason"), "locked", "a new code: asked again")
	_req(a, {"type": "befriend", "character": c})
	eq(_req(c, _at(4, {"type": "use"})).get("open"), true, "the maker's friends need none")
	_req(c, _at(4, {"type": "use"}))
	w.flush_state()
	w.close()
	w = ServerWorld.open(_db, _content)
	for who: String in [a, b]:
		var known: Dictionary = w._known_character(who)
		w.enter(known["owner"], PortableCharacter.from_data(known["data"]))
		w.move_character(who, Vector2i(3 * 256 + 128, 3 * 256 + 128))
	eq(_req(b, _at(4, {"type": "use", "pin": "1234"})).get("reason"), "wrong_pin", "the lock kept over a restart")
	w.grant(b, "base:axe", 1)
	_req(b, {"type": "hold", "item": "base:axe"})
	eq(_break(b, 4, 20)[0], 8, "but a wooden door breaks")
	w.flush_state()
	eq(w.store.read_meta(ServerWorld._lock_key("surface", 4, 3)), "", "and its lock goes with it")
	_req(a, {"type": "unfriend", "character": c})
	w.grant(a, "base:plank", 4)
	_req(a, _at(4, {"type": "build", "part": "base:wood_door"}))
	eq(_req(b, _at(4, {"type": "use"})).get("open"), true, "a new door there is not locked")
	check(not _req(a, _at(4, {"type": "lock", "pin": ""})).get("locked", true), "an empty code takes a lock off")


func test_what_the_dead_dropped_is_theirs_for_ten_minutes() -> void:
	w.spawn_position = Vector2i(3 * 256 + 128, 3 * 256 + 128)
	var a := _player("Аня")
	var b := _player("Боря")
	w.grant(a, "base:plank", 5)
	w.grant(a, "base:stone", 2)
	w.combat.hurt(a, 100, "")
	var planks := ""
	var stones := ""
	for id: String in w.items:
		if w.items[id]["item"] == "base:plank":
			planks = id
		else:
			stones = id
	var r := _req(b, {"type": "pickup", "entity": planks})
	eq(r.get("reason"), "kept_for_dead", "not someone else's yet")
	eq(r.get("seconds"), 600)
	check(_req(a, {"type": "pickup", "entity": stones}).get("ok", false), "the one who died takes them")
	w.tick += 600 * Movement.TICK_RATE
	check(_req(b, {"type": "pickup", "entity": planks}).get("ok", false), "ten minutes on, anyone")
