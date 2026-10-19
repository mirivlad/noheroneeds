extends TestCase


func test_edit_keeps_identity_progress_and_signed_file() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var path := tmp_dir()
	var me := PlayerIdentity.load_or_create(path.path_join("key"))
	var library := CharacterLibrary.new(path.path_join("characters"), content, me)
	var file := library.create("Аня", CharacterLibrary.STYLE_DEFAULTS)
	var before := library.load_character(file)
	before.inventory.add("base:stone", 7)
	before.equipment = {"feet": "base:boots"}
	before.attributes = {"base:strength": 7}
	before.skills = {"base:farming": {"level": 2, "xp": 9}}
	library._write(file, CharacterFile.export_signed(before, me, content))
	var styles := {"face": "base:human_face_angular", "hair": "base:human_hair_long"}
	var colors := {"skin": "#503327", "hair": "#c9a363"}
	check(library.edit(file, "Аня", "base:human_f_broad", styles, colors), library.last_error)
	var after := library.load_character(file)
	eq(after.character_id, before.character_id)
	eq(after.attributes, before.attributes)
	eq(after.skills, before.skills)
	eq(after.equipment, before.equipment)
	eq(after.inventory.to_data(), before.inventory.to_data())
	eq(after.body_plan, "base:human_f_broad")
	eq(after.styles, styles)
	eq(after.colors, colors)
	check(CharacterFile.read(library.file_bytes(file), content).ok, "edited file has a valid owner signature")
	check(not library.edit(file, "", after.body_plan, styles, colors), "blank name refused")
	eq(library.load_character(file).body_plan, after.body_plan, "refusal preserves the file")
	var signed := library.file_bytes(file)
	check(not library.edit(file, "Аня", after.body_plan, styles, {"skin":"red"}), "invalid palette colour refused")
	eq(library.file_bytes(file), signed, "invalid edits cannot overwrite the signed file")


func test_palette_and_all_modular_combinations_draw_independently() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for plans: Array in CharacterEditor.PLANS:
		for plan: String in plans:
			var visual := content.visual_of(plan)
			var light := Art.character_texture(visual, {"skin": "#f1b892"}).get_image()
			var dark := Art.character_texture(visual, {"skin": "#503327"}).get_image()
			check(light.get_data() != dark.get_data(), "skin tone changes body pixels: " + plan)
			for face: String in CharacterEditor.FACES:
				for hair: String in CharacterEditor.HAIRS:
					var look := {"body_plan": plan, "styles": {"face": face, "hair": hair},
						"colors": {"skin": "#8b5a3f", "hair": "#c9a363"}, "worn": WorldLibrary.STARTER_OUTFIT.duplicate()}
					var layers := Art.character_layers(content, visual, look)
					eq(layers.size(), 5, "head, hair, three fitted clothes")
					for layer: Array in layers:
						eq(layer[1].get_size(), Vector2(1344, 480))
					look["worn"]["headwear"] = "base:felt_hat"
					eq(Art.character_layers(content, visual, look).size(), 6, "hat combines with all faces and hair")


func test_head_neck_overlaps_body_in_every_idle_and_walk_frame() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for plans: Array in CharacterEditor.PLANS:
		for plan: String in plans:
			var visual := content.visual_of(plan)
			var body := Art.texture(visual["atlas_path"]).get_image()
			for face: String in CharacterEditor.FACES:
				var head := Art.texture(visual["style_overrides"][face]["atlas_path"]).get_image()
				for row in 5:
					for frame in 14:
						var cell := Rect2i(frame * 96, row * 96, 96, 96)
						var bounds := head.get_region(cell).get_used_rect()
						var overlap := 0
						for y in range(bounds.end.y - 2, bounds.end.y):
							for x in range(bounds.position.x, bounds.end.x):
								var at := cell.position + Vector2i(x, y)
								if head.get_pixelv(at).a > 0.0 and body.get_pixelv(at).a > 0.0:
									overlap += 1
						check(overlap >= 2, "%s %s %s %s frame %d: neck seated in the body, got %d pixels" %
							[plan, face, CharacterSprite.DIRS[row], "idle" if frame < 4 else "walk", frame, overlap])


func test_body_and_clothing_have_no_solid_blocks_of_outline_ink() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var ink := Color8(51, 41, 37)
	for plans: Array in CharacterEditor.PLANS:
		for plan: String in plans:
			var visual := content.visual_of(plan)
			var layers := [visual]
			for item: String in WorldLibrary.STARTER_OUTFIT.values():
				layers.append(Art.worn_visual(content, visual, item))
			for layer: Dictionary in layers:
				var img := Art.texture(layer["atlas_path"]).get_image()
				var thick := 0
				for y in range(1, img.get_height() - 1):
					for x in range(1, img.get_width() - 1):
						if img.get_pixel(x, y) != ink:
							continue
						# One logical pixel permits two native pixels at this density.
						# Material shadows are distinct from the outline pigment.
						var solid := true
						for dy in range(-1, 2):
							for dx in range(-1, 2):
								if img.get_pixel(x+dx, y+dy) != ink:
									solid = false
						if solid:
							thick += 1
				check(thick == 0, "%s: %d solid 3x3 outline blocks" % [layer["atlas_path"], thick])


func test_fitted_clothes_leave_every_animated_wrist_bare() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var skin := [Color8(128, 0, 32), Color8(192, 0, 48), Color8(255, 96, 128), Color8(51, 41, 37)]
	for plans: Array in CharacterEditor.PLANS:
		for plan: String in plans:
			var visual := content.visual_of(plan)
			var body := Art.texture(visual["atlas_path"]).get_image()
			for row in 5:
				for frame in 14:
					var hand: Array = visual["hands"][CharacterSprite.DIRS[row]][frame]
					var at := Vector2i(frame*96 + int(hand[0]), row*96 + int(hand[1]))
					check(body.get_pixelv(at).a > 0 and body.get_pixelv(at) in skin,
						"%s %d:%d: tool attaches to the skin/outline of a wrist" % [plan, row, frame])
					for item: String in WorldLibrary.STARTER_OUTFIT.values():
						var worn := Art.worn_visual(content, visual, item)
						check(Art.texture(worn["atlas_path"]).get_image().get_pixelv(at).a == 0,
							"%s %d:%d: %s leaves the hand visible" % [plan, row, frame, item])


func test_modular_walk_keeps_contact_and_passing_poses() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for plans: Array in CharacterEditor.PLANS:
		for plan: String in plans:
			var body := Art.texture(content.visual_of(plan)["atlas_path"]).get_image()
			for row in [1, 2, 3]:
				var widths := []
				for frame in 6:
					widths.append(body.get_region(Rect2i((frame+4)*96, row*96+74, 96, 16)).get_used_rect().size.x)
				check(int(widths.max()) - int(widths.min()) >= 3,
					"%s row %d: visible stride and passing pose: %s" % [plan, row, widths])


func test_changing_equipment_preserves_walk_facing_held_tool_and_swing() -> void:
	var view := WorldView.new()
	view.content = ContentRegistry.load_packs(["res://content/base"])
	var look := {"body_plan":"base:human_m", "styles":{"face":"base:human_face_soft","hair":"base:human_hair_short"},
		"worn":WorldLibrary.STARTER_OUTFIT.duplicate()}
	var doll := view._character("actor", look)
	doll.show_at(Vector2.ZERO, 0.0, true)
	doll.show_at(Vector2(-4, -4), 0.17, true)
	doll.hold(view.item_picture("base:axe"), view.item_grip("base:axe"))
	var state := [doll._walk, doll._dir, doll._mirror, doll._column, doll._shown, doll.position, doll._held]
	look["worn"]["headwear"] = "base:felt_hat"
	var updated := view._character("actor", look)
	eq(updated, doll, "same node")
	eq([doll._walk, doll._dir, doll._mirror, doll._column, doll._shown, doll.position, doll._held], state,
		"no phase, facing or tool reset")
	doll.swing(Vector2.LEFT, "chop")
	doll.show_at(Vector2(-4, -4), 0.05, true)
	var swing := [doll._swing_t, doll._swing_dir, doll._held.transform, doll.scale, doll.position]
	look["worn"].erase("torso")
	view._character("actor", look)
	eq([doll._swing_t, doll._swing_dir, doll._held.transform, doll.scale, doll.position], swing,
		"changing clothes during a blow leaves it intact")
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


func test_classic_tool_bob_does_not_jump_when_a_hat_is_added() -> void:
	var view := WorldView.new()
	view.content = ContentRegistry.load_packs(["res://content/base"])
	var look := {"body_plan":"base:humanoid_adult", "styles":CharacterLibrary.STYLE_DEFAULTS.duplicate(), "worn":{}}
	var doll := view._character("classic", look)
	doll.turn_to(Vector2.RIGHT)
	doll._frame(doll._anim("walk"), 1)
	doll.hold(view.item_picture("base:axe"), view.item_grip("base:axe"))
	var transform := doll._held.transform
	var bob := doll._hand_bob
	look["worn"]["headwear"] = "base:felt_hat"
	view._character("classic", look)
	eq(doll._hand_bob, bob)
	eq(doll._held.transform, transform, "legacy wrist bob also survives dressing")
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


func test_detailed_sheets_keep_world_size_pivot_and_held_item_size() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for plans: Array in CharacterEditor.PLANS:
		for plan: String in plans:
			var visual := content.visual_of(plan)
			var doll := CharacterSprite.new(Art.character_texture(visual, {}), visual)
			doll.turn_to(Vector2.RIGHT)
			var sprite: Sprite2D = doll._layers[0][1]
			eq(sprite.region_rect.size * sprite.scale, Vector2(48, 48), "logical frame unchanged")
			eq(sprite.offset * sprite.scale, Vector2(-24, -45), "feet keep their world pivot")
			doll.hold(Art.texture("res://content/base/art/editor/felt_hat_icon.png"))
			eq(doll._held.scale, Vector2(0.75, 0.75), "item size is independent of body resolution")
			var hand: Array = visual["hands"]["e"][0]
			var expected := (Vector2(float(hand[0])+0.5, float(hand[1])+0.5) - Vector2(48,90)) * 0.5
			var actual := doll._held.position + doll._scaled_grip().rotated(doll._held.rotation)
			check(actual.is_equal_approx(expected), "tool remains attached after scaling")
			doll.free()


func test_fast_movement_plays_run_and_walking_and_idle_still_work() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var visual := content.visual_of("base:human_m")
	var doll := CharacterSprite.new(Art.character_texture(visual, {}), visual)
	doll.show_at(Vector2.ZERO, 0.0, true)
	doll.show_at(Vector2(20,0), 0.1, true)
	check(doll._column >= 10 and doll._column < 14, "fast movement uses the four-frame run")
	doll.show_at(Vector2(20,0), 0.1, true)
	check(doll._column < 4, "stopping returns to idle")
	doll.show_at(Vector2(20+CharacterSprite.WALK_PX_PER_SEC*0.1,0), 0.1, true)
	check(doll._column >= 4 and doll._column < 10, "ordinary movement uses the six-frame walk")
	doll.free()
	var legacy := content.visual_of("base:traveler")
	doll = CharacterSprite.new(Art.texture(legacy["atlas_path"]), legacy)
	eq(doll._anim("run"), legacy["animations"]["walk"], "a legacy body runs using its own walk track")
	doll.free()
