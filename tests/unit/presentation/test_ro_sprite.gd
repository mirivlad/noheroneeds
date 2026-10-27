extends TestCase
## Humans from the RO sprite pipeline (tools/art/ro_sprites/export_game.py):
## every layer fits its atlas, the sprite faces eight real ways, keeps the
## feet, draws its layers in the order of each frame, walks and runs, and
## swings with the tool in frames of its own.

const PLAN := "base:human_ro_m"
## Each body plan and its sample hair.
const PLANS := {"base:human_ro_m": "base:human_ro_hair_tousled", "base:human_ro_f": "base:human_ro_hair_twintails"}


func _content() -> ContentRegistry:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	return content


func _look(worn := WorldLibrary.STARTER_OUTFIT, plan := PLAN) -> Dictionary:
	return {"body_plan": plan, "styles": {"hair": PLANS[plan]}, "colors": {}, "worn": worn.duplicate()}


func _sheets(visual: Dictionary) -> Array:
	var sheets := [visual]
	for group: String in ["style_overrides", "worn_overrides", "held_overrides"]:
		for layer: Dictionary in visual.get(group, {}).values():
			sheets.append_array(layer["sheets"])
	return sheets


func test_every_layer_fits_its_atlas() -> void:
	var content := _content()
	for plan: String in PLANS:
		_fits_its_atlas(content.visual_of(plan), plan)


func _fits_its_atlas(visual: Dictionary, plan: String) -> void:
	eq(visual.get("format"), "ro", plan + " is drawn from RO layers")
	check(visual["style_overrides"].has(PLANS[plan]), plan + " draws its own hair")
	for clip: String in visual["clips"]:
		check(visual["anims"].has(clip), "the body has every clip: " + clip)
	for sheet: Dictionary in _sheets(visual):
		var size := Art.texture(sheet["atlas_path"]).get_size()
		var w: int = sheet["frame"][0]
		var h: int = sheet["frame"][1]
		for clip: String in sheet["anims"]:
			var r: Array = sheet["anims"][clip]
			eq(r[1], int(visual["clips"][clip]["frames"]), "%s %s: a frame for every frame of the clip" % [sheet["atlas"], clip])
			var last: int = r[0] + r[1] - 1
			check((last % sheet["columns"] + 1) * w <= size.x and (last / sheet["columns"] * 8 + 8) * h <= size.y,
				"%s %s: eight rows of its frames inside the atlas" % [sheet["atlas"], clip])
	for item: String in visual["held_overrides"]:
		var anims: Dictionary = visual["held_overrides"][item]["sheets"][0]["anims"]
		check(anims.has("idle") and anims.has("walk") and visual["swings"].values().any(func(c: String) -> bool:
			return anims.has(c)), item + ": carried and swung")


func test_eight_directions_drawn_not_mirrored() -> void:
	var content := _content()
	var doll := Art.character_sprite(content, content.visual_of(PLAN), _look()) as RoSprite
	check(doll != null, "an RO body is drawn by RoSprite")
	for case: Array in [[Vector2.DOWN, 0], [Vector2(1, 1), 1], [Vector2.RIGHT, 2], [Vector2(1, -1), 3],
			[Vector2.UP, 4], [Vector2(-1, -1), 5], [Vector2.LEFT, 6], [Vector2(-1, 1), 7]]:
		doll.turn_to(case[0])
		eq(doll._row, case[1], "facing %s" % case[0])
		for layer: Array in doll._layers:
			var s: Sprite2D = layer[1]
			if s.visible:
				eq(int(s.region_rect.position.y) / int(s.region_rect.size.y) % 8, case[1], "every layer on the row of the direction")
				check(not s.flip_h, "drawn, not mirrored")
	doll.free()


func test_layers_keep_the_feet_and_the_order_of_the_frame() -> void:
	var content := _content()
	var visual := content.visual_of(PLAN)
	var worn := WorldLibrary.STARTER_OUTFIT.merged({"armor": "base:leather_armor", "back_item": "base:wool_cloak"})
	var doll := Art.character_sprite(content, visual, _look(worn)) as RoSprite
	eq(doll._layers.size(), 1 + 1 + worn.size(), "body, hair and every worn thing")
	for layer: Array in doll._layers:
		var s: Sprite2D = layer[1]
		eq(s.offset, -Vector2(layer[2]["origin"][0], layer[2]["origin"][1]), "feet at the origin")
		eq(s.scale, Vector2.ONE * 0.5, "half a texel a pixel")
	for dir: Vector2 in [Vector2.DOWN, Vector2.RIGHT, Vector2.UP, Vector2(-1, -1)]:
		doll.turn_to(dir)
		var drawn := doll.get_children().map(func(n: Node) -> String:
			return String(doll._layers.filter(func(l: Array) -> bool: return l[1] == n)[0][2]["key"]))
		eq(drawn[0], "body", "the body first: the rest was filmed in front of it")
		check(drawn.find("leather_armor") > drawn.find("linen_shirt"), "the armour over the shirt")
		var listed: Array = (visual["order"]["idle"][doll._row][0] as Array).map(func(k: Variant) -> String:
			return String(visual["layers"][int(k)]))
		eq(drawn, listed.filter(func(k: String) -> bool: return drawn.has(k)), "the frame's own order")
	doll.free()


func test_walk_run_and_idle_play_their_own_frames() -> void:
	var content := _content()
	var doll := Art.character_sprite(content, content.visual_of(PLAN), _look()) as RoSprite
	doll.show_at(Vector2.ZERO, 0.0, true)
	doll.show_at(Vector2(20, 0), 0.1, true)
	eq(doll._clip, "run", "fast movement runs")
	eq(doll._row, 2, "running east")
	doll.show_at(Vector2(20, 0), 0.1, true)
	eq(doll._clip, "idle", "standing still")
	var steps := [0]
	doll.stepped.connect(func() -> void: steps[0] += 1)
	var frames := {}
	var x := 20.0
	for i in 20:
		x += CharacterSprite.WALK_PX_PER_SEC * 0.05
		doll.show_at(Vector2(x, 0), 0.05, true)
		eq(doll._clip, "walk")
		frames[(doll._layers[0][1] as Sprite2D).region_rect.position] = true
	check(frames.size() >= 6, "the walk goes through its frames: %d" % frames.size())
	check(steps[0] >= 2, "feet come down while walking: %d" % steps[0])
	doll.free()


func test_swings_play_once_with_the_tool_in_its_frames() -> void:
	var content := _content()
	var view := WorldView.new()
	view.content = content
	var doll := view._character("me", _look()) as RoSprite
	doll.show_at(Vector2.ZERO, 0.0, true)
	for case: Array in [["base:axe", "chop"], ["base:iron_pickaxe", "chop"], ["base:spear", "thrust"],
			["base:hoe", "thrust"], ["base:bow", "shoot"], ["base:fishing_rod", "cast"], ["", "slash"]]:
		doll.hold(view.item_picture(case[0]), view.item_grip(case[0]), case[0])
		eq(doll._held_item, case[0], "drawn with frames of its own: " + case[0])
		doll.show_at(Vector2.ZERO, 0.1, true)
		if case[0] != "":
			check(doll._held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible),
				"standing with %s shows it" % case[0])
			check(doll._held == null or not doll._held.visible, "no picture pinned to the hand")
		doll.swing(Vector2.RIGHT, view.swing_kind(case[0]))
		eq(doll._swing_clip(), case[1], case[0] + " plays its clip")
		var seen := {}
		var t := 0.0
		while doll.swinging() and t < 3.0:
			doll.show_at(Vector2.ZERO, 0.02, true)
			t += 0.02
			seen[(doll._layers[0][1] as Sprite2D).region_rect.position] = true
			if case[0] != "" and doll.swinging():
				check(doll._held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible),
					"%s is drawn through the %s" % [case[0], case[1]])
		check(not doll.swinging(), case[1] + " finishes")
		check(seen.size() >= 4, "%s plays its frames: %d" % [case[1], seen.size()])
	doll.hold(view.item_picture("base:plank"), view.item_grip("base:plank"), "base:plank")
	check(doll._held != null and doll._held.visible and doll._held_layers.is_empty(), "other things are their picture at the hand")
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


func test_the_editor_offers_the_ro_bodies() -> void:
	var content := _content()
	var editor := CharacterEditor.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(editor)
	editor.setup(content)
	for plan: String in PLANS:
		editor.sex_pick.selected = CharacterEditor.PLANS.find(plan)
		var look := editor.appearance()
		eq(look["body_plan"], plan)
		eq(look["styles"], {"hair": PLANS[plan]}, "its own sample hair, no face to choose")
		var c := PortableCharacter.create("Тест", plan)
		c.styles = look["styles"]
		c.colors = look["colors"]
		eq(c.check_content(content), PackedStringArray(), plan + ": a valid character")
		var doll := Art.character_sprite(content, content.visual_of(plan), _look(WorldLibrary.STARTER_OUTFIT, plan))
		check(doll is RoSprite and doll._layers.size() == 2 + WorldLibrary.STARTER_OUTFIT.size(), plan + " is dressed")
		doll.free()
	editor.free()


func test_malformed_ro_visuals_are_content_errors() -> void:
	var body := {"id": "test:body", "kind": "body_plan", "slots": ["body"], "appearance_slots": [],
		"colors": ["skin"], "directions": 8}
	var visual := {"id": "test:visual/body", "kind": "visual", "for": "test:body", "mode": "character",
		"format": "ro", "atlas": "a.png", "frame": [60, 90], "origin": [30, 80], "columns": 10, "rect": [0, 0, 60, 90],
		"anims": {"idle": [0, 4], "walk": [4, 8]}, "clips": {"idle": {"frames": 4, "fps": 3}, "walk": {"frames": 8, "fps": 11}},
		"swings": {"lunge": "walk"}, "layers": ["body"], "order": {}}
	eq(ContentRegistry.from_defs([body, visual]).errors, PackedStringArray(), "a well-formed RO body loads")
	for bad: Dictionary in [{"clips": {"idle": {"frames": 4, "fps": 3}}}, {"swings": {"chop": "chop"}},
			{"anims": {"idle": [0]}}, {"columns": 0}, {"frame": [60]}, {"order": []},
			{"style_overrides": {"test:body": {"layer": "hair", "sheets": [{"atlas": "b.png"}]}}}]:
		check(not ContentRegistry.from_defs([body, visual.merged(bad, true)]).errors.is_empty(),
			"rejected before drawing: %s" % str(bad))
