extends TestCase
## ADR-0021: what is in the hands is the server's. Actions are done with it,
## not with whatever lies in the bag; a request naming something else is
## refused; what is no longer carried leaves the hands.

var w: ServerWorld
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 5})
	var c := w.chunk("surface", 0, 0)
	for y in 10:
		for x in 10:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")
	c.set_cell("cover", 5, 3, "base:oak")


func after_each() -> void:
	w.close()


func _player() -> String:
	var c := PortableCharacter.create("Аня", "base:humanoid_adult")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, Vector2i(4 * 256 + 128, 3 * 256 + 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _fell(actor: String, item: Variant = null) -> Dictionary:
	var r := {"type": "gather", "location": "surface", "x": 5, "y": 3, "layer": "cover"}
	if item != null:
		r["item"] = item
	return _req(actor, r)


func test_a_tool_in_the_bag_does_nothing() -> void:
	var a := _player()
	w.grant(a, "base:axe", 1)
	w.grant(a, "base:pickaxe", 1)
	eq(_fell(a).get("reason"), "no_tool", "empty hands, the axe in the bag")
	eq(_fell(a, "base:axe").get("reason"), "not_held", "naming the axe does not put it into the hands")
	_req(a, {"type": "hold", "item": "base:pickaxe"})
	eq(_fell(a).get("reason"), "no_tool", "a pick in the hands does not fell trees")
	eq(_fell(a, "base:axe").get("reason"), "not_held", "nor does naming the axe while holding the pick")
	_req(a, {"type": "hold", "item": "base:axe"})
	check(_fell(a, "base:axe").get("ok", false), "the axe in the hands fells it")


func test_one_cannot_hold_what_one_has_not() -> void:
	var a := _player()
	w.grant(a, "base:axe", 1)
	_req(a, {"type": "hold", "item": "base:axe"})
	eq(_req(a, {"type": "hold", "item": "base:bow"}).get("reason"), "not_carried")
	eq(w.held_of(a), "", "a refused hold leaves the hands empty, not with the old thing")
	eq(_req(a, {"type": "hold", "item": "base:oak"}).get("reason"), "not_carried", "a tree is not a thing to hold")
	eq(_req(a, {"type": "hold", "item": 42}).get("reason"), "bad_request", "nor is a number")
	for bad: Dictionary in [{"type": "gather", "x": "a", "y": [], "layer": 5, "item": {}},
			{"type": "attack", "x": null, "item": 3.5, "unarmed": "yes"},
			{"type": "strike_part", "location": 1, "x": {}, "item": []},
			{"type": "store", "location": "surface", "x": 4, "y": 4, "item": 7, "count": "all"}]:
		check(_req(a, bad).get("ok") != true, "a malformed %s is refused, not a crash" % bad["type"])
	eq(_req(a, {"type": "attack", "item": "base:axe", "x": 0, "y": 0}).get("reason"), "not_held")
	eq(_req(a, {"type": "strike_part", "location": "surface", "x": 5, "y": 3, "item": "base:axe"}).get("reason"),
		"not_held")


func test_what_leaves_the_bag_leaves_the_hands() -> void:
	var a := _player()
	w.grant(a, "base:axe", 1)
	w.grant(a, "base:bow", 1)
	w.grant(a, "base:spear", 1)
	w.grant(a, "base:plank", 10)
	_req(a, {"type": "hold", "item": "base:axe"})
	_req(a, {"type": "drop", "item": "base:axe", "count": 1})
	eq(w.held_of(a), "", "dropped")
	eq(String(w.present[a]["held"]), "", "and others see empty hands")
	_req(a, {"type": "build", "location": "surface", "x": 4, "y": 4, "part": "base:chest"})
	_req(a, {"type": "hold", "item": "base:bow"})
	_req(a, {"type": "store", "location": "surface", "x": 4, "y": 4, "item": "base:bow", "count": 1})
	eq(w.held_of(a), "", "put into a chest")
	_req(a, {"type": "hold", "item": "base:spear"})
	w.combat.hurt(a, 100, "")
	eq(w.held_of(a), "", "lost in death")
	eq(String(w.present[a]["held"]), "")


func test_actions_without_a_name_use_the_hands() -> void:
	var a := _player()
	w.grant(a, "base:axe", 1)
	_req(a, {"type": "hold", "item": "base:axe"})
	check(_fell(a).get("ok", false), "felled with what is held")
	w.grant(a, "base:plank", 10)
	_req(a, {"type": "build", "location": "surface", "x": 3, "y": 3, "part": "base:wood_wall"})
	eq(_req(a, {"type": "strike_part", "location": "surface", "x": 3, "y": 3}).get("damage"), 4, "an axe blow")
	w.tick += 40
	w.combat.step(w.tick)
	eq(_req(a, {"type": "strike_part", "location": "surface", "x": 3, "y": 3, "item": "base:axe", "unarmed": true})
		.get("damage"), 5, "the free hand on purpose: one more")
