extends TestCase
## ADR-0021: what a click does comes from what is held and what is pointed
## at, through content data.

var content: ContentRegistry
var client: GameClient
var view: WorldView


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	client = GameClient.new(null, null, PackedByteArray(), content)
	client.character_id = "me"
	client.location = "surface"
	var c := Chunk.new()
	c.set_cell("structure", 3, 3, "base:wood_door")
	c.set_props(3, 3, {"owner": "me"})
	c.set_cell("structure", 4, 3, "base:wood_wall")
	c.set_props(4, 3, {"owner": "someone"})
	client.chunks[ServerWorld.chunk_key("surface", 0, 0)] = c
	view = WorldView.new()
	view.client = client


func after_each() -> void:
	view.free()


func _part(id: String, cell: Vector2i, layer := "structure") -> Dictionary:
	return {"kind": "part", "id": id, "layer": layer, "cell": cell, "location": "surface"}


func _ids(actions: Array[Dictionary]) -> Array:
	return actions.map(func(a: Dictionary) -> String: return a["id"])


func test_the_tool_in_hand_decides() -> void:
	var a := Actions.of(content, client, view, "base:pickaxe", _part("base:rock", Vector2i(9, 9)), Vector2i.ZERO)
	eq(Actions.primary(a).get("name"), "Копать", "a pick digs rock")
	eq(Actions.primary(a)["request"]["item"], "base:pickaxe", "with the pick held")
	a = Actions.of(content, client, view, "base:axe", _part("base:oak", Vector2i(9, 9), "cover"), Vector2i.ZERO)
	eq(Actions.primary(a).get("name"), "Рубить", "an axe fells a tree")
	a = Actions.of(content, client, view, "base:axe", _part("base:rock", Vector2i(9, 9)), Vector2i.ZERO)
	var dig: Dictionary = a.filter(func(x: Dictionary) -> bool: return x["id"] == "gather")[0]
	check(not dig.get("enabled", true) and String(dig["why"]).contains("кирка"), "an axe does not dig: " + String(dig["why"]))


func test_weapons_strike_and_shoot_without_a_mode() -> void:
	var wolf := {"kind": "entity", "id": "w1", "location": "surface",
		"entity": {"kind": "creature", "creature": "base:wolf", "x": 900, "y": 900}}
	var a := Actions.of(content, client, view, "base:axe", wolf, Vector2i(880, 880))
	eq(Actions.primary(a).get("id"), "strike", "an axe strikes a wolf")
	eq(Actions.primary(a)["request"]["x"], 900, "at the wolf")
	a = Actions.of(content, client, view, "base:bow", _part("base:rock", Vector2i(2, 2)), Vector2i(500, 600))
	eq(Actions.primary(a).get("id"), "shoot", "a bow shoots wherever one aims")
	a = Actions.of(content, client, view, "", wolf, Vector2i.ZERO)
	eq(Actions.primary(a).get("id"), "inspect", "bare hands look")
	check(_ids(a).has("strike"), "a punch is in the menu")
	a = Actions.of(content, client, view, "base:spear", {"kind": "ground", "id": "base:grass", "cell": Vector2i(1, 1),
		"location": "surface"}, Vector2i(300, 300))
	eq(Actions.primary(a).get("id"), "swing", "a spear swings at the air too")


func test_doors_things_and_ones_own() -> void:
	var a := Actions.of(content, client, view, "", _part("base:wood_door", Vector2i(3, 3)), Vector2i.ZERO)
	eq(Actions.quick(a).get("name"), "Открыть", "E opens a door")
	check(_ids(a).has("dismantle"), "one's own door may be taken apart")
	eq(_ids(a).filter(func(i: String) -> bool: return i == "lock").size(), 1, "and locked by the one who set it up")
	a = Actions.of(content, client, view, "", _part("base:wood_wall", Vector2i(4, 3)), Vector2i.ZERO)
	var apart: Dictionary = a.filter(func(x: Dictionary) -> bool: return x["id"] == "dismantle")[0]
	check(not apart["enabled"] and String(apart["why"]).contains("сломать"), "someone else's wall: only broken")
	check(_ids(a).has("strike_part"), "which anyone may do (ADR-0016)")
	var thing := {"kind": "entity", "id": "i1", "location": "surface", "entity": {"kind": "item", "item": "base:stone", "count": 2}}
	a = Actions.of(content, client, view, "", thing, Vector2i.ZERO)
	eq(Actions.quick(a).get("id"), "pickup")
	eq(Actions.describe(content, thing), "Камень ×2")


## ADR-0016: a locked door says so; only the one who set it up locks it;
## another person may be befriended; anyone mends a worn part.
func test_locks_friends_and_mending() -> void:
	var c: Chunk = client.chunks[ServerWorld.chunk_key("surface", 0, 0)]
	c.set_props(3, 3, {"owner": "someone", "locked": true})
	c.set_props(4, 3, {"owner": "someone", "damage": 7.5})
	var a := Actions.of(content, client, view, "", _part("base:wood_door", Vector2i(3, 3)), Vector2i.ZERO)
	eq(Actions.quick(a).get("name"), "Открыть (заперто)")
	check(not _ids(a).has("lock"), "not someone else's lock")
	a = Actions.of(content, client, view, "", _part("base:wood_wall", Vector2i(4, 3)), Vector2i.ZERO)
	check(_ids(a).has("repair"), "someone else's wall mended")
	var her := {"kind": "entity", "id": "c2", "location": "surface", "entity": {"kind": "character", "x": 0, "y": 0}}
	a = Actions.of(content, client, view, "", her, Vector2i.ZERO)
	var f: Dictionary = a.filter(func(x: Dictionary) -> bool: return x["id"] == "friend")[0]
	eq(f["request"], {"type": "befriend", "character": "c2"})
	client.own["friends"] = ["c2"]
	a = Actions.of(content, client, view, "", her, Vector2i.ZERO)
	eq(a.filter(func(x: Dictionary) -> bool: return x["id"] == "friend")[0]["name"], "Убрать из друзей")


func test_a_ceiling_is_struck_by_its_layer() -> void:
	var c: Chunk = client.chunks[ServerWorld.chunk_key("surface", 0, 0)]
	c.set_cell("ceiling", 5, 5, "base:wood_ceiling")
	c.set_props(5, 5, {"ceiling": {"owner": "someone", "damage": 10.0}})
	var a := Actions.of(content, client, view, "base:axe", _part("base:wood_ceiling", Vector2i(5, 5), "ceiling"), Vector2i.ZERO)
	var blow: Dictionary = a.filter(func(x: Dictionary) -> bool: return x["id"] == "strike_part")[0]
	eq(blow["request"]["layer"], "ceiling")
	eq(a.filter(func(x: Dictionary) -> bool: return x["id"] == "repair")[0]["request"]["layer"], "ceiling", "worn: mended")


## On a building level a cell without floor is jumped down into from beside
## it; over stairs, gone down by them (E).
func test_a_drop_is_jumped_into() -> void:
	client.z = 1
	client.position = Vector2i(5 * 256 + 128, 4 * 256 + 128)
	var void_cell := {"kind": "ground", "id": "", "cell": Vector2i(5, 5), "location": "surface"}
	var a := Actions.of(content, client, view, "", void_cell, Vector2i.ZERO)
	eq(Actions.quick(a).get("request"), {"type": "jump", "dx": 0, "dy": 1}, "E jumps down into it")
	var far := {"kind": "ground", "id": "", "cell": Vector2i(5, 8), "location": "surface"}
	a = Actions.of(content, client, view, "", far, Vector2i.ZERO)
	eq(a.filter(func(x: Dictionary) -> bool: return x["id"] == "jump")[0]["enabled"], false, "from beside it only")
	var c: Chunk = client.chunks[ServerWorld.chunk_key("surface", 0, 0)]
	c.set_props(5, 5, {"stairs_down": true})
	a = Actions.of(content, client, view, "", void_cell, Vector2i.ZERO)
	eq(Actions.quick(a).get("request", {}).get("dir"), "down", "stairs below: E goes down them")
	check(_ids(a).has("jump"), "jumping is still there")
	eq(Actions.describe(content, void_cell), "Пустота: проём или край — можно спрыгнуть")


func test_a_rod_fishes_in_water() -> void:
	var water := {"kind": "ground", "id": "base:water", "cell": Vector2i(5, 5), "location": "surface"}
	var a := Actions.of(content, client, view, "base:fishing_rod", water, Vector2i.ZERO)
	eq(Actions.primary(a).get("name"), "Ловить рыбу", "a rod fishes")
	eq(Actions.primary(a)["request"].get("layer"), "ground", "in the ground's water")
	a = Actions.of(content, client, view, "base:axe", water, Vector2i.ZERO)
	var fish: Dictionary = a.filter(func(x: Dictionary) -> bool: return x["id"] == "gather")[0]
	check(not fish.get("enabled", true) and String(fish["why"]).contains("удочка"), "an axe does not fish: " + String(fish["why"]))
	a = Actions.of(content, client, view, "base:fishing_rod", {"kind": "ground", "id": "base:grass", "cell": Vector2i(5, 5),
		"location": "surface"}, Vector2i.ZERO)
	check(not _ids(a).has("gather"), "no fish in grass")


func test_an_animal_is_fed_what_it_eats() -> void:
	var sheep := {"kind": "entity", "id": "s1", "location": "surface",
		"entity": {"kind": "creature", "creature": "base:sheep", "x": 900, "y": 900}}
	var a := Actions.of(content, client, view, "base:wheat", sheep, Vector2i(900, 900))
	eq(Actions.primary(a).get("id"), "feed", "wheat to a sheep")
	eq(Actions.primary(a)["request"], {"type": "feed", "creature": "s1", "item": "base:wheat"})
	a = Actions.of(content, client, view, "base:wheat_seeds", sheep, Vector2i(900, 900))
	check(not _ids(a).has("feed"), "a sheep does not eat seeds")
	eq(Actions.describe(content, sheep, "me"), "Овца", "a wild one")
	sheep["entity"]["owner"] = "me"
	eq(Actions.describe(content, sheep, "me"), "Овца (ваша)")
	eq(Actions.describe(content, sheep, "other"), "Овца (чья-то)")


func test_a_bucket_fills_at_water_and_pours() -> void:
	var water := {"kind": "ground", "id": "base:water", "cell": Vector2i(5, 5), "location": "surface"}
	eq(Actions.primary(Actions.of(content, client, view, "base:bucket", water, Vector2i.ZERO)).get("id"), "fill", "a bucket at water")
	var crop := _part("base:wheat_crop", Vector2i(6, 6), "cover")
	eq(Actions.primary(Actions.of(content, client, view, "base:water_bucket", crop, Vector2i.ZERO)).get("name"), "Полить")
	var grass := {"kind": "ground", "id": "base:grass", "cell": Vector2i(5, 5), "location": "surface"}
	eq(Actions.primary(Actions.of(content, client, view, "base:water_bucket", grass, Vector2i.ZERO)).get("name"), "Вылить")
	eq(Actions.primary(Actions.of(content, client, view, "base:milk_bucket", grass, Vector2i.ZERO)).get("name"), "Выпить (ведро молока)")
	var cow := {"kind": "entity", "id": "c1", "location": "surface",
		"entity": {"kind": "creature", "creature": "base:cow", "x": 900, "y": 900, "owner": "me"}}
	eq(Actions.primary(Actions.of(content, client, view, "base:bucket", cow, Vector2i.ZERO)).get("name"), "Подоить")
	cow["entity"]["owner"] = "other"
	check(not _ids(Actions.of(content, client, view, "base:bucket", cow, Vector2i.ZERO)).has("fill"), "not another's cow")


func test_the_map_marks_ways_up_and_down() -> void:
	var c := Chunk.new()
	c.set_cell("ground", 0, 0, "base:grass")
	c.set_cell("structure", 3, 4, "base:wood_stairs")
	c.set_cell("structure", 5, 5, "base:cave_mouth")
	c.set_cell("structure", 7, 7, "base:cave_climb")
	c.set_cell("structure", 9, 9, "base:wood_wall")
	client.map_tiles["surface|0|0"] = MapTile.of(c)
	var painter := MapPainter.new()
	painter.setup(content, view, client)
	var marks := painter.marks("surface", Vector2i.ZERO)
	marks.sort_custom(func(a: Array, b: Array) -> bool: return a[0].x < b[0].x)
	eq(marks, [[Vector2i(3, 4), true], [Vector2i(5, 5), false], [Vector2i(7, 7), true]], "stairs and a climb up, a mouth down; a wall nothing")
