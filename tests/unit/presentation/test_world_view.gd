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
	g.world.starter_outfit = {"torso": "base:linen_shirt", "feet": "base:boots"}
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
	var dolls := view.find_children("*", "CharacterSprite", true, false)
	check(dolls.size() == 1, "own character shown")
	# A paper doll: the body, then hair and the starter outfit, in the body
	# plan's order (feet under torso under hair).
	var slots := []
	for child: Node in dolls[0].get_children():
		var t := (child as Sprite2D).texture
		slots.append((t.resource_path if t.resource_path != "" else t.resource_name).get_file())
	eq(slots, ["body.png", "boots.png", "linen_shirt.png", "hair_short.png"], "layers in order")
	# Grounds meet with ragged edges: only on a cell next to a higher ground.
	var edges := view.edge_cells()
	check(edges.size() > 0, "edges drawn where grounds meet: %d cells" % edges.size())
	var prio := {}
	for id: String in content.visuals:
		if content.visuals[id].has("edges"):
			prio[id] = int(content.visuals[id]["edges"]["priority"])
	var wrong := 0
	for cell: Vector2i in edges:
		var own := view.ground_at("surface", cell)
		var higher := false
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var n := view.ground_at("surface", cell + Vector2i(dx, dy))
				higher = higher or (prio.has(n) and prio.has(own) and prio[n] > prio[own])
		wrong += 0 if higher else 1
	eq(wrong, 0, "every edge lies next to a higher ground")
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


## Every layer shows the same frame: walking moves through the walk frames
## of the sheet, and the west side is the east mirrored.
func test_paper_doll_frames() -> void:
	var tex := ImageTexture.create_from_image(Image.create(480, 240, false, Image.FORMAT_RGBA8))
	var v := {"rect": [0, 0, 48, 48], "origin": [24, 45], "layer_order": {"e": ["body", "torso"]},
		"animations": {"idle": {"from": 0, "frames": 4, "fps": 6}, "walk": {"from": 4, "frames": 6, "fps": 10}}}
	var cs := CharacterSprite.new(tex, v, [["torso", tex]])
	cs.show_at(Vector2.ZERO, 0.016, true)
	for i in 3:
		cs.show_at(Vector2(-(i + 1) * 2.0, 0), 0.05, true)  # walking west
	var body: Sprite2D = cs.get_child(0)
	var shirt: Sprite2D = cs.get_child(1)
	eq(body.region_rect, shirt.region_rect, "layers on the same frame")
	check(body.region_rect.position.x >= 4 * 48, "a walk frame: %s" % body.region_rect)
	eq(body.region_rect.position.y, 2.0 * 48, "the east row")
	check(body.flip_h and shirt.flip_h, "mirrored for the west")
	cs.free()
