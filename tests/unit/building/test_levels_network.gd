extends TestCase
## A building level through the whole chain: requests over the network, the
## location change, the level's chunks, prediction against the floor's edge,
## and the view hiding the cover of the room the player stands in.


func test_up_the_stairs_and_back() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var g := LocalGame.start(tmp_dir().path_join("world.db"), content, owner,
		PlayerIdentity.load_or_create(keys + "server"), CharacterFile.export_signed(c, owner, content))
	g.server.wait_for_disk = true
	g.world.starter_kit = {"base:plank": 100}
	var view := WorldView.new()
	view.setup(content, g.client)
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	_steps(g, view, 30)
	var cl := g.client
	for x in range(1, 4):
		for y in range(1, 4):
			cl.request({"type": "build", "location": "surface", "x": x, "y": y, "part": "base:wood_ceiling"})
	cl.request({"type": "build", "location": "surface", "x": 2, "y": 2, "part": "base:wood_stairs"})
	_steps(g, view, 10)
	eq(g.world.levels.info.size(), 1, "the ceiling made a level")
	# Stand by the stairs (as if walked there) and look at the room from
	# inside: its cover is hidden, all but the opening over the stairs.
	g.world.move_character(cl.character_id, Vector2i(2 * 256 + 128, 3 * 256 + 128))
	_steps(g, view, 10)
	check(view.hidden_room().has(Vector2i(2, 3)) and view.hidden_room().size() == 8, "the cover over this room is hidden: %d" % view.hidden_room().size())
	cl.request({"type": "climb", "location": "surface", "x": 2, "y": 2})
	_steps(g, view, 15)
	eq(cl.z, 1, "on the first floor")
	check(cl.location != "surface" and cl.has_position, "placed on the level")
	check(cl.chunks.has(ServerWorld.chunk_key(cl.location, 0, 0)), "the level's chunk arrived")
	var corrections_before := cl.corrections  # the test's own teleport counted earlier
	cl.move = Vector2i(1, 0)
	_steps(g, view, 30)
	var pos: Vector2i = g.world.present[cl.character_id]["pos"]
	eq(pos.x, 4 * Movement.UNIT - Movement.HALF_X, "stops at the edge of the floor")
	eq(cl.position, pos, "the client predicted the same")
	eq(cl.corrections - corrections_before, 0, "no corrections while walking on the level")
	cl.move = Vector2i(-1, 0)
	_steps(g, view, 6)
	cl.move = Vector2i.ZERO
	g.world.move_character(cl.character_id, Vector2i(2 * 256 + 128, 1 * 256 + 128))  # the landing
	_steps(g, view, 5)
	cl.request({"type": "climb", "location": cl.location, "x": 2, "y": 2})  # down through the opening
	_steps(g, view, 15)
	eq(cl.z, 0, "back down")
	eq(cl.location, "surface")
	view.free()
	g.close()


func _steps(g: LocalGame, view: WorldView, n: int) -> void:
	for i in n:
		g.step()
		view.update_view(0.0, 0.05)
