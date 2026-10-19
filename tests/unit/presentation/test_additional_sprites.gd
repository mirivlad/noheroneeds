extends TestCase
## Additive bodies survive signed files and world entry; old looks still draw.


func test_walk_has_contact_and_passing_poses_on_sides_and_diagonals() -> void:
	for body: String in ["traveler", "wayfarer"]:
		var image := Art.texture("res://content/base/art/additional/" + body + "_body.png").get_image()
		for row in [1, 2, 3]:
			var widths := []
			for frame in 6:
				var legs := image.get_region(Rect2i((frame + 4) * 48, row * 48 + 37, 48, 8))
				widths.append(legs.get_used_rect().size.x)
			check(int(widths.max()) - int(widths.min()) >= 3,
				"%s row %d: a wide contact and a narrow passing pose: %s" % [body, row, widths])


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


func test_runtime_walk_moves_the_tool_with_the_hand_and_attacks_still_finish() -> void:
	var view := WorldView.new()
	view.content = ContentRegistry.load_packs(["res://content/base"])
	for plan: String in ["base:traveler", "base:wayfarer"] + CharacterEditor.PLANS[0] + CharacterEditor.PLANS[1]:
		var doll := view._character(plan, {"body_plan": plan, "worn": WorldLibrary.STARTER_OUTFIT.duplicate()})
		var visual := view.content.visual_of(plan)
		for dir_index in 8:
			var dir := Vector2.DOWN.rotated(-dir_index * PI / 4)
			var target := Vector2.ZERO
			doll.show_at(target, 0.0, true)
			var positions := {}
			for frame in 12:
				doll.hold(view.item_picture("base:axe"), view.item_grip("base:axe"))
				target += dir * CharacterSprite.WALK_PX_PER_SEC * 0.1
				doll.show_at(target, 0.1, true)
				var hand: Array = visual["hands"][CharacterSprite.DIRS[doll._dir]][doll._column]
				var at := Vector2(float(hand[0]) + 0.5 - visual["origin"][0], float(hand[1]) + 0.5 - visual["origin"][1]) * float(visual.get("pixel_scale", 1.0))
				if doll._mirror:
					at.x = -at.x
				var grip := doll._held.position + doll._scaled_grip().rotated(doll._held.rotation)
				check(grip.is_equal_approx(at), "show_at keeps the handle on this frame's wrist")
				positions[grip] = true
			check(positions.size() >= 2, "the tool actually moves through the walk")
			for kind: String in ["chop", "thrust", "draw"]:
				doll.swing(dir, kind)
				doll.show_at(target, 0.05, true)
				var held_transform := doll._held.transform
				doll.hold(view.item_picture("base:axe"), view.item_grip("base:axe"))
				eq(doll._held.transform, held_transform, "holding the same item does not reset the blow")
				check(doll.swinging(), "the blow is still in progress")
				for frame in 8:
					doll.show_at(target, 0.05, true)
				check(not doll.swinging(), "the blow finishes")
				eq(doll.scale, Vector2.ONE, "the body comes back from its lean")
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


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


func test_actual_tool_pixels_touch_the_wrist_including_mirrored_views() -> void:
	var view := WorldView.new()
	view.content = ContentRegistry.load_packs(["res://content/base"])
	for plan: String in ["base:traveler"] + CharacterEditor.PLANS[0] + CharacterEditor.PLANS[1]:
		var doll := view._character(plan, {"body_plan": plan, "worn": WorldLibrary.STARTER_OUTFIT.duplicate()})
		var visual := view.content.visual_of(plan)
		for item: String in ["base:axe", "base:pickaxe", "base:spear", "base:bow"]:
			var picture := view.item_picture(item)
			var point: Array = view.content.visual_of(item)["grip"]
			check(picture.get_image().get_pixel(int(point[0]), int(point[1])).a > 0.0,
				"the grip is an opaque handle pixel of " + item)
			var offset := view.item_grip(item)
			for dir in [Vector2.RIGHT, Vector2.LEFT, Vector2(1, -1), Vector2(-1, -1)]:
				doll.turn_to(dir)
				doll.hold(picture, offset)
				for frame in 6:
					doll._frame(visual["animations"]["walk"], frame)
					var hand: Array = visual["hands"][CharacterSprite.DIRS[doll._dir]][frame + 4]
					var at := Vector2(float(hand[0]) + 0.5 - visual["origin"][0], float(hand[1]) + 0.5 - visual["origin"][1]) * float(visual.get("pixel_scale", 1.0))
					var drawn_grip := offset * doll._held.scale
					if doll._mirror:
						at.x = -at.x
						drawn_grip.x = -drawn_grip.x
					var actual := doll._held.position + drawn_grip.rotated(doll._held.rotation)
					check(actual.is_equal_approx(at), "the drawn handle touches the wrist: " + item)
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


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
		var plan: String = CharacterEditor.PLANS[choice][0]
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


func test_fitted_clothes_and_old_clothes_draw_and_can_be_removed() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var view := WorldView.new()
	view.content = content
	for plan: String in MainMenu.BODIES:
		var looks := {"body_plan": plan, "styles": {}, "worn": WorldLibrary.STARTER_OUTFIT.duplicate()}
		if plan == "base:humanoid_adult":
			looks["styles"] = CharacterLibrary.STYLE_DEFAULTS.duplicate()
		var doll := view._character(plan, looks)
		var paths := []
		for layer: Array in doll._layers:
			paths.append(String((layer[1] as Sprite2D).texture.resource_name))
		if plan == "base:humanoid_adult":
			check(paths.any(func(p: String) -> bool: return p.ends_with("people/hair_short.png")), "old hair still draws")
			check(paths.any(func(p: String) -> bool: return p.ends_with("people/linen_shirt.png")), "old shirt still draws")
		else:
			eq(paths.size(), 4, "body and three fitted clothing layers")
			check(paths.all(func(p: String) -> bool: return p.contains("art/additional/")), "new body uses fitted clothes")
		for angle in range(8):
			var dir := Vector2.RIGHT.rotated(angle * PI / 4)
			doll.turn_to(dir)
			doll.show_at(Vector2.ZERO, 0.0, true)
			for frame in range(6):
				doll.show_at(dir * (frame + 1) * 2, 0.1, true)
				var rect: Rect2 = (doll._layers[0][1] as Sprite2D).region_rect
				check(rect.end.x <= 480 and rect.end.y <= 240, "walk frame within the sheet")
				for layer: Array in doll._layers:
					eq((layer[1] as Sprite2D).region_rect, rect, "clothes follow the body")
		looks["worn"] = {}
		var undressed := view._character(plan, looks)
		eq(undressed._layers.size(), 2 if plan == "base:humanoid_adult" else 1, "removed clothes disappear")
	view.free()
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
