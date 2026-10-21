extends TestCase
## ADR-0021: the cursor says what a click will do — a glove takes, a sword
## strikes, an axe chops, a pick digs, a sight shoots.

var content: ContentRegistry
var client: GameClient
var view: WorldView


func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	client = GameClient.new(null, null, PackedByteArray(), content)
	client.character_id = "me"
	client.location = "surface"
	view = WorldView.new()
	view.client = client


func after_each() -> void:
	view.free()


func _kind(held: String, target: Dictionary, aim := Vector2i.ZERO) -> String:
	return CursorArt.kind_of(Actions.of(content, client, view, held, target, aim))


func _part(id: String, layer := "structure") -> Dictionary:
	return {"kind": "part", "id": id, "layer": layer, "cell": Vector2i(9, 9), "location": "surface"}


func test_the_cursor_follows_the_action() -> void:
	var wolf := {"kind": "entity", "id": "w1", "location": "surface",
		"entity": {"kind": "creature", "creature": "base:wolf", "x": 900, "y": 900}}
	var thing := {"kind": "entity", "id": "i1", "location": "surface", "entity": {"kind": "item", "item": "base:stone", "count": 2}}
	var grass := {"kind": "ground", "id": "base:grass", "cell": Vector2i(1, 1), "location": "surface"}
	eq(_kind("base:spear", wolf), "sword", "a weapon strikes")
	eq(_kind("base:spear", grass, Vector2i(300, 300)), "sword", "or swings at the air")
	eq(_kind("base:axe", _part("base:oak", "cover")), "axe", "an axe fells a tree")
	eq(_kind("base:pickaxe", _part("base:rock")), "pick", "a pick digs rock")
	eq(_kind("base:bow", grass, Vector2i(300, 300)), "bow", "a bow shoots")
	eq(_kind("base:bow", thing), "bow", "even over a thing lying")
	eq(_kind("", thing), "glove", "a thing lying is taken")
	eq(_kind("base:spear", thing), "glove", "whatever is held")
	eq(_kind("", _part("base:tall_grass", "cover")), "glove", "grass plucked by hand")
	eq(_kind("", _part("base:workbench")), "hammer", "work at a workbench")
	eq(_kind("", grass), "corners", "else the corners")


func test_pictures_are_outlined_and_scaled() -> void:
	for kind: String in CursorArt.GLYPHS:
		var img := CursorArt.texture(kind, 3).get_image()
		eq(img.get_size(), Vector2i(48, 48), kind)
		var hot := CursorArt.hotspot(kind, 3)
		check(Rect2(Vector2.ZERO, Vector2(48, 48)).has_point(hot), kind + " aims inside its picture")
	var sword := CursorArt.texture("sword", 2).get_image()
	eq(sword.get_pixel(0, 0), CursorArt.INK, "an outline round the point")
	eq(sword.get_pixel(2, 2), CursorArt.PALETTE["w"], "the point itself")
	eq(CursorArt.hotspot("sword", 2), Vector2(3, 3), "aimed with the point")
