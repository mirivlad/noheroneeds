extends TestCase
## Bodies survive signed files and world entry; animals keep both their sheets.


func test_tool_grip_follows_the_current_frame_and_mirrors_with_the_hand() -> void:
	var tex := ImageTexture.create_from_image(Image.create(480, 240, false, Image.FORMAT_RGBA8))
	var visual := {"rect": [0, 0, 48, 48], "origin": [24, 45],
		"animations": {"idle": {"from": 0, "frames": 1, "fps": 1}, "walk": {"from": 1, "frames": 2, "fps": 10}},
		"hands": {"e": [[24, 33, 0], [20, 31, -20], [28, 34, 20]]}}
	var doll := CharacterSprite.new(tex, visual)
	doll.turn_to(Vector2.RIGHT)
	doll.hold(tex)
	for mirror in [false, true]:
		doll.turn_to(Vector2.LEFT if mirror else Vector2.RIGHT)
		for frame in 2:
			doll._frame(visual["animations"]["walk"], frame)
			var hand: Array = visual["hands"]["e"][frame + 1]
			var expected := Vector2(float(hand[0]) + 0.5 - 24.0, float(hand[1]) + 0.5 - 45.0)
			if mirror:
				expected.x = -expected.x
			var grip := doll._held.position + (CharacterSprite.GRIP * doll._held.scale).rotated(doll._held.rotation)
			check(grip.is_equal_approx(expected), "scaled grip stays on the drawn hand, including west")
			eq(doll._held.flip_h, mirror)
			check(is_equal_approx(doll._held.rotation, deg_to_rad(float(hand[2])) * (-1 if mirror else 1)),
				"the tool turns with the wrist")
	doll.free()


func test_bad_hand_anchors_are_rejected_as_content_errors() -> void:
	var body := {"id": "test:body", "kind": "body_plan", "slots": ["body"], "appearance_slots": [],
		"colors": ["skin"], "directions": 8}
	var visual := {"id": "test:visual/body", "kind": "visual", "for": "test:body", "mode": "character",
		"rect": [0, 0, 48, 48], "origin": [24, 45], "hands": {"e": [[24, 33, 0]]}}
	eq(ContentRegistry.from_defs([body, visual]).errors, PackedStringArray(), "valid anchors load")
	for bad: Dictionary in [{"hands": []}, {"hands": {"q": []}}, {"hands": {"e": [[48, 33, 0]]}},
			{"hands": {"e": [[24, "bad", 0]]}}, {"hand_behind": {"n": "yes"}},
			{"grip": [48, 13]}, {"grip": ["bad", 13]}, {"pixel_scale": 0},
			{"pixel_scale": -0.5}, {"pixel_scale": "small"}, {"pixel_scale": INF}]:
		check(not ContentRegistry.from_defs([body, visual.merged(bad, true)]).errors.is_empty(),
			"malformed hand data is rejected before the sprite renderer uses it")


func test_new_bodies_can_be_chosen_saved_and_played() -> void:
	for choice in [0, 1]:
		var app := App.new()
		var profile := tmp_dir()
		app.configure({"profile_dir": profile})
		(Engine.get_main_loop() as SceneTree).root.add_child(app)
		app.menu.show_character_create()
		var pick: OptionButton = app.menu.find_child("SexChoice", true, false)
		pick.select(choice)
		pick.item_selected.emit(choice)
		var hair: OptionButton = app.menu.find_child("HairChoice", true, false)
		check(not hair.disabled, "hairstyles are independent of sex and body")
		var name_edit: LineEdit = app.menu.find_children("*", "LineEdit", true, false).filter(
			func(n: Node) -> bool: return not n.is_queued_for_deletion())[-1]
		name_edit.text = "Новый облик %d" % choice
		for button: Button in app.menu.find_children("*", "Button", true, false):
			if button.text == "Создать" and not button.is_queued_for_deletion():
				button.pressed.emit()
				break
		var file := String(app.settings.get_value("character"))
		var plan: String = CharacterEditor.PLANS[choice]
		var saved := app.characters.load_character(file)
		check(saved != null, "signed file is readable")
		eq(saved.body_plan, plan)
		eq(saved.styles, {"face": "base:human_face_soft", "hair": "base:human_hair_short"}, "modular head and hair")
		eq(saved.check_content(app.content), PackedStringArray())
		# Reopen the library: this uses the persisted, signed bytes.
		var reopened := CharacterLibrary.new(profile.path_join("characters"), app.content, app.me)
		eq(reopened.load_character(file).body_plan, plan)
		app.start_game({"mode": "local", "world": "sprite-check", "world_path": app.worlds.db_path("sprite-check"),
			"rules": {"seed": "1"}})
		for i in 100:
			app.game._process(0.05)
			if app.game.client.state == "playing" and app.game.client.has_position:
				break
			OS.delay_msec(2)
		eq(app.game.client.state, "playing")
		eq(app.game.client.own.get("appearance", {}).get("body_plan"), plan, "the server keeps the chosen body")
		app.quit()
		app.free()
		for i in 2:
			await (Engine.get_main_loop() as SceneTree).process_frame


func test_old_and_new_animal_variants_are_stable() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for animal: String in ["hare", "deer", "wolf", "cave_rat", "cave_spider", "poring", "poporing"]:
		var seen := {}
		for i in 16:
			var view := WorldView.new()
			view.content = content
			var id := "animal-%d" % i
			var looks := {"body_plan": "base:" + animal}
			var doll := view._character(id, looks)
			var sprite: Sprite2D = doll._layers[0][1]
			var path := String(sprite.texture.resource_name)
			seen[path] = true
			check(view._character(id, looks) == doll, "unchanged appearance reuses its sprite")
			var another := WorldView.new()
			another.content = content
			var copy := another._character(id, looks)
			eq((copy._layers[0][1] as Sprite2D).texture.resource_name, path, "same entity on another client")
			view.free()
			another.free()
		eq(seen.size(), 2, "both variants of " + animal + " remain in use")
		check(seen.has("res://content/base/art/creatures/" + animal + ".png"), "old sheet remains in use")
		check(seen.has("res://content/base/art/additional/" + animal + ".png"), "new sheet appears alongside it")
