extends TestCase
## Authoritative conversion, material conservation and layer persistence.
var world: ServerWorld
var actor := ""
var db := ""

func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	world = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 4})
	var c := world.chunk("surface", 0, 0)
	for y in 9:
		for x in 9:
			c.set_cell("ground", x, y, "base:grass")
			for layer: String in ["cover", "structure", "ceiling", "roof"]: c.set_cell(layer, x, y, "")
			c.set_props(x, y, {})
	var pc := PortableCharacter.create("Строитель", "base:human_ro_m")
	world.enter("owner", pc)
	actor = pc.character_id
	world.move_character(actor, Vector2i(2, 4) * Movement.UNIT + Vector2i(128, 128))
	world.grant(actor, "base:plank", 100)
	world.grant(actor, "base:stone", 30)

func after_each() -> void:
	world.close()

func request(op: Dictionary, who := "") -> Dictionary:
	if who == "": who = actor
	op["request_id"] = Uuid.v4()
	op.merge({"location": "surface", "x": 2, "y": 2})
	world.handle(who, op)
	world.sync()
	for ack: Array in world.take_acks():
		if ack[1] == op["request_id"]: return ack[2]
	return {}

func wall_row(part := "base:wood_wall") -> void:
	for x in range(1, 4):
		check(request({"type": "build", "part": part, "x": x}).get("ok", false), "wall row is built normally")

func test_conversion_preserves_layers_and_dismantling_leaves_an_opening_without_duplication() -> void:
	check(request({"type": "build", "part": "base:plank_floor"}).get("ok", false), "laid floor")
	check(request({"type": "build", "part": "base:wood_ceiling"}).get("ok", false), "ceiling and real upper floor")
	wall_row()
	var c := world.chunk("surface", 0, 0)
	var ground: Dictionary = c.get_props(2, 2)["ground"].duplicate(true)
	var ceiling: Dictionary = c.get_props(2, 2)["ceiling"].duplicate(true)
	var before := world.inventory(actor).count("base:plank")
	check(request({"type": "build", "part": "base:wood_door", "facing": "e"}).get("ok", false), "wall turns into a door atomically")
	eq(c.get_cell("structure", 2, 2), "base:wood_door")
	eq(c.get_props(2, 2)["facing"], "s", "orientation follows the wall despite perpendicular client input")
	eq(c.get_props(2, 2)["owner"], actor)
	eq(c.get_props(2, 2)["ground"], ground)
	eq(c.get_props(2, 2)["ceiling"], ceiling)
	eq(c.get_cell("ground", 2, 2), "base:wood_floor")
	eq(c.get_cell("ceiling", 2, 2), "base:wood_ceiling")
	eq(world.inventory(actor).count("base:plank"), before - 1, "three existing planks count toward the four-plank door")
	check(request({"type": "dismantle", "layer": "structure"}).get("ok", false), "door dismantles normally")
	eq(c.get_cell("structure", 2, 2), "", "dismantling leaves an opening, not a magically restored wall")
	eq(world.inventory(actor).count("base:plank"), before + 3, "only the original wall material has been recovered")
	for cycle in 3:
		check(request({"type": "build", "part": "base:wood_door", "facing": "n"}).get("ok", false), "reinstall in the existing opening")
		eq(c.get_props(2, 2)["facing"], "n", "opening side can be reversed within the wall plane")
		check(request({"type": "dismantle", "layer": "structure"}).get("ok", false), "remove door again")
		eq(world.inventory(actor).count("base:plank"), before + 3, "repeated installation cannot duplicate materials")
	eq(c.get_props(2, 2)["ground"], ground)
	eq(c.get_props(2, 2)["ceiling"], ceiling)

func test_denied_conversion_does_not_touch_wall_or_inventory() -> void:
	wall_row()
	var c := world.chunk("surface", 0, 0)
	var before := world.inventory(actor).count("base:plank")
	var pc := PortableCharacter.create("Другой", "base:human_ro_m")
	world.enter("other", pc)
	world.move_character(pc.character_id, Vector2i(2, 4) * Movement.UNIT + Vector2i(128, 128))
	world.grant(pc.character_id, "base:plank", 10)
	eq(request({"type": "build", "part": "base:wood_door"}, pc.character_id).get("reason"), "not_owner")
	eq(world.inventory(pc.character_id).count("base:plank"), 10)
	eq(c.get_cell("structure", 2, 2), "base:wood_wall")
	eq(world.inventory(actor).count("base:plank"), before)
	world.inventory(actor).remove("base:plank", before)
	eq(request({"type": "build", "part": "base:wood_door"}).get("reason"), "materials")
	eq(c.get_cell("structure", 2, 2), "base:wood_wall")
	eq(world.inventory(actor).count("base:plank"), 0)

func test_stone_wall_refund_is_exact_and_door_orientation_survives_reopen() -> void:
	wall_row("base:stone_wall")
	var stone := world.inventory(actor).count("base:stone")
	var planks := world.inventory(actor).count("base:plank")
	check(request({"type": "build", "part": "base:wood_door", "facing": "n"}).get("ok", false), "stone wall can be converted too")
	eq(world.inventory(actor).count("base:stone"), stone + 2, "stone is refunded once")
	eq(world.inventory(actor).count("base:plank"), planks - 3, "the old plank is credited")
	world.close()
	world = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]))
	eq(world._part_at("surface", 2, 2, "structure"), "base:wood_door")
	eq(world._props_at("surface", 2, 2).get("facing"), "n", "opening side persists")
	eq(world._props_at("surface", 2, 2).get("owner"), actor)
