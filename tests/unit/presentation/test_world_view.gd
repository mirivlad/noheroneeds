extends TestCase
## The world view draws what the client received, from visual definitions only.


func test_view_follows_the_client() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var c := PortableCharacter.create("Аня", "base:humanoid_adult")
	c.styles = {"hair": "base:hair_short", "face": "base:face_soft", "eyes": "base:eyes_round"}
	c.inventory.add("base:plank", 3)
	var g := LocalGame.start(tmp_dir().path_join("world.db"), content, owner,
		PlayerIdentity.load_or_create(keys + "server"), CharacterFile.export_signed(c, owner, content))
	g.server.wait_for_disk = true
	var view := WorldView.new()
	view.setup(content, g.client)
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	for i in 30:
		g.step()
	view.update_view(0.0, 0.05)
	var ground := view.ground_layer()
	check(ground.get_used_cells().size() >= 9 * Chunk.CELLS, "ground of the nearby chunks: %d cells" % ground.get_used_cells().size())
	var sprites := view.find_children("*", "Sprite2D", true, false).size()
	check(sprites > 0, "tall things drawn as sprites: %d" % sprites)
	check(view.find_children("*", "CharacterSprite", true, false).size() == 1, "own character shown")
	# A wall built at (2, 1) appears where it stands.
	g.client.request({"type": "build", "location": "surface", "x": 2, "y": 1, "part": "base:wood_wall"})
	for i in 10:
		g.step()
	view.update_view(0.0, 0.05)
	var found := false
	for s: Sprite2D in view.find_children("*", "Sprite2D", true, false):
		if s.position == Vector2(2 * WorldView.CELL, 2 * WorldView.CELL) and not s.is_queued_for_deletion():
			found = true
	check(found, "the wall sprite stands on its cell")
	view.free()
	g.close()
