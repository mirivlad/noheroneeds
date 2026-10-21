extends TestCase
## ADR-0050: a character swims into water a creature keeps out of — half as
## fast, never running; nothing is worked with in the water; swimming tires
## and chills, and one spent in the water drowns.

var w: ServerWorld
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	w = ServerWorld.open(tmp_dir().path_join("world.db"), _content, {"seed": 5})
	var c := w.chunk("surface", 0, 0)
	for y in 16:
		for x in 16:
			c.set_cell("ground", x, y, "base:water" if x >= 6 else "base:grass")
			c.set_cell("cover", x, y, "")
			c.set_cell("structure", x, y, "")
	for id: String in w.creatures.in_chunk("surface", 0, 0):
		w.creatures.remove(id)


func after_each() -> void:
	w.close()


func _player() -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, Vector2i(4 * 256 + 128, 4 * 256 + 128))
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func test_a_character_swims_where_a_creature_cannot_go() -> void:
	var walker := func(x: int, y: int) -> bool: return w.blocks_walker("surface", x, y)
	var creature := func(x: int, y: int) -> bool: return w.is_solid("surface", x, y)
	var pos := Vector2i(5 * 256 + 128, 4 * 256 + 128)
	var walked := pos
	for i in 20:
		walked = Movement.step(walked, 1, 0, walker)
	check(Movement.cell_of(walked).x >= 6, "a character goes into the water: %s" % Movement.cell_of(walked))
	var held := pos
	for i in 20:
		held = Movement.step_at(held, 1, 0, creature, Movement.WALK)
	check(Movement.cell_of(held).x < 6, "a creature stops at the shore")
	# Half as fast in water.
	var a := Vector2i(8 * 256, 8 * 256)
	eq(Movement.step(a, 1, 0, walker, false, Vector2i(Movement.HALF_X, Movement.HALF_Y), true).x - a.x, Movement.SWIM)
	check(Movement.SWIM * 2 <= Movement.WALK + 1, "half a walk")
	# Something solid on the water still keeps one out.
	w.chunk("surface", 0, 0).set_cell("structure", 9, 8, "base:wood_wall")
	check(w.blocks_walker("surface", 9, 8), "a wall stands in the water: no way through")
	check(not w.blocks_walker("surface", 10, 8), "open water: one swims")


func test_nothing_is_worked_with_swimming() -> void:
	var a := _player()
	check(not w.in_water(a), "on the shore")
	w.move_character(a, Vector2i(8 * 256 + 128, 4 * 256 + 128))
	check(w.in_water(a), "in the water")
	w.grant(a, "base:axe", 1)
	w.grant(a, "base:plank", 10)
	eq(_req(a, {"type": "build", "location": "surface", "x": 9, "y": 4, "part": "base:wood_wall"}).get("reason"), "swimming")
	eq(_req(a, {"type": "attack", "x": 0, "y": 0}).get("reason"), "swimming")
	eq(_req(a, {"type": "craft", "recipe": "base:twist_cord", "count": 1}).get("reason"), "swimming")
	check(_req(a, {"type": "drop", "item": "base:plank", "count": 1}).get("ok", false), "but one may let a thing go")


func test_swimming_tires_and_chills_and_spent_one_drowns() -> void:
	var a := _player()
	w.world_time = Daylight.DAY_MS + 12 * Daylight.HOUR_MS  # noon, summer: ashore it is warm
	w.needs.step()
	w.move_character(a, Vector2i(10 * 256 + 128, 4 * 256 + 128))
	var energy := w.needs.energy_of(a)
	var warmth := w.needs.warmth_of(a)
	w.world_time += Daylight.HOUR_MS
	w.needs.step()
	check(energy - w.needs.energy_of(a) > 25.0, "an hour's swim tires: %.1f -> %.1f" % [energy, w.needs.energy_of(a)])
	check(w.needs.warmth_of(a) < warmth - 15.0, "and chills, at noon too")
	# Spent: health goes, a point every three minutes, to the end.
	w.needs.set_energy(a, 0.0)
	var health := w.combat.health_of(a)
	w.world_time += 9 * 60 * 1000
	w.needs.step()
	eq(w.combat.health_of(a), health - 3, "nine minutes spent in the water: three health")
	var deaths := int(w.present[a].get("deaths", 0))
	w.world_time += Daylight.HOUR_MS * 2
	w.needs.step()
	eq(int(w.present[a].get("deaths", 0)), deaths + 1, "drowned")
	check(not w.in_water(a), "back at the spawn point, ashore")
	check(w.needs.energy_of(a) >= 49.0, "rested a little")


## ADR-0051: shallows are waded through — by creatures too — never running;
## deep water tires and chills twice as fast as common water.
func test_shallows_are_waded_and_deep_water_tires_more() -> void:
	var c := w.chunk("surface", 0, 0)
	for y in 16:
		c.set_cell("ground", 6, y, "base:shallows")
		c.set_cell("ground", 7, y, "base:shallows")
		c.set_cell("ground", 12, y, "base:deep_water")
		c.set_cell("ground", 13, y, "base:deep_water")
	check(not w.is_solid("surface", 6, 4), "a creature crosses a ford")
	check(not w.blocks_walker("surface", 7, 4), "and so does a character")
	var a := _player()
	w.move_character(a, Vector2i(6 * 256 + 128, 4 * 256 + 128))
	check(w.in_shallows(a) and not w.in_water(a), "wading, not swimming")
	eq(w.swim_effort(a), 1.0)
	w.move_character(a, Vector2i(12 * 256 + 128, 4 * 256 + 128))
	check(w.in_water(a), "deep water is swum")
	eq(w.swim_effort(a), 2.0, "twice as hard")
	w.world_time = Daylight.DAY_MS + 12 * Daylight.HOUR_MS
	w.needs.step()
	var energy := w.needs.energy_of(a)
	w.world_time += Daylight.HOUR_MS
	w.needs.step()
	check(energy - w.needs.energy_of(a) > 55.0, "an hour in deep water: %.1f -> %.1f" % [energy, w.needs.energy_of(a)])
