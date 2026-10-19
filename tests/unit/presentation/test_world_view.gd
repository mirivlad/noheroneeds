extends TestCase
## The world view draws what the client received, from visual definitions only.


func test_view_follows_the_client() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
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
	check(view.terrain_tiles().size() >= Chunk.CELLS, "what is in sight is drawn at once")
	while view.pending_chunks() > 0:
		view.update_view(0.0, 0.05)  # the rest, a few each frame
	var sprites := view.find_children("*", "Sprite2D", true, false).size()
	check(sprites > 0, "tall things drawn as sprites: %d" % sprites)
	check(view._characters.has(g.client.character_id), "own character shown")
	var dolls := [view._characters[g.client.character_id]]
	# A paper doll: the body, the starter outfit, the head and hair, in the
	# layers' own depth (feet under torso under head under hair).
	var slots := []
	for child: Node in dolls[0].get_children():
		var t := (child as Sprite2D).texture
		slots.append((t.resource_path if t.resource_path != "" else t.resource_name).get_file())
	eq(slots, ["body_bodies_male.png", "feet_boots_basic_male.png", "torso_clothes_longsleeve_longsleeve_male.png",
		"head_heads_human_male.png", "hair_messy1_adult.png"], "layers in order")
	# Grounds are LPC terrains on the corners of cells: a corner draws the
	# lowest of its four cells as a fill and each higher one as its edge.
	var tiles := view.terrain_tiles()
	check(tiles.size() >= 9 * Chunk.CELLS, "terrain at the corners of the nearby chunks: %d" % tiles.size())
	var wrong := 0
	var meets := 0
	for corner: Vector2i in tiles:
		var want := 0
		for d: Vector2i in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
			var gr := view.ground_at("surface", corner + d)
			if view._terrain_rank.has(gr):
				want |= 1 << int(view._terrain_rank[gr])
		wrong += 0 if int(tiles[corner]) == want else 1
		meets += 1 if want & (want - 1) else 0
	eq(wrong, 0, "every corner draws exactly the grounds of its cells")
	check(meets > 0, "grounds meet somewhere: %d corners" % meets)
	# Sounds: the ground around is heard (ambience), a step is played.
	var audio := AudioDirector.new()
	audio.setup(content, g.client, view)
	view.add_child(audio)
	audio._process(0.6)
	var amb := audio.find_children("*", "AudioStreamPlayer", false, false)
	check(amb.size() > 0, "ambience of the ground around")
	audio.step_at(g.client.location, view.own_pixel_position(0.0))
	var playing := 0
	for v: AudioStreamPlayer2D in audio.find_children("*", "AudioStreamPlayer2D", false, false):
		playing += 1 if v.stream != null else 0
	eq(playing, 1, "a footstep")
	audio._process(20.0)  # past the first calm: a gust
	var gusts := 0
	for pl: AudioStreamPlayer in audio.find_children("*", "AudioStreamPlayer", false, false):
		gusts += 1 if pl.stream and String(pl.stream.resource_name).contains("wind") else 0
	eq(gusts, 1, "the wind comes in a gust")
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
