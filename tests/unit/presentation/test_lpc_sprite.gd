extends TestCase
## Humans from LPC layers (tools/art/import_lpc.py): the sheets fit together,
## the sprite faces four ways, walks, runs, swings with real frames, holds
## tools as layers of their own and is recoloured by palette ramps.

const PLANS := ["base:human_m", "base:human_f"]


func _content() -> ContentRegistry:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	return content


func _look(plan: String, worn := WorldLibrary.STARTER_OUTFIT) -> Dictionary:
	return {"body_plan": plan, "styles": {"face": "base:human_face_square", "hair": "base:human_hair_braid"},
		"colors": {"skin": "#ae6b3f", "hair": "#e09e2b", "eyes": "#5686ae"}, "worn": worn.duplicate()}


func _sheets(visual: Dictionary) -> Array:
	var sheets := [visual]
	for group: String in ["style_overrides", "worn_overrides", "held_overrides"]:
		for layer: Dictionary in visual.get(group, {}).values():
			sheets.append_array(layer["sheets"])
	return sheets


func test_every_layer_fits_its_atlas_and_the_body_grid() -> void:
	var content := _content()
	for plan: String in PLANS:
		var visual := content.visual_of(plan)
		eq(visual.get("format"), "lpc", plan + " is drawn from LPC layers")
		for sheet: Dictionary in _sheets(visual):
			var size := Art.texture(sheet["atlas_path"]).get_size()
			for anim: String in sheet["anims"]:
				var r: Array = sheet["anims"][anim]
				check(r[0] + r[2] * r[3] <= size.x and r[1] + r[2] * 4 <= size.y,
					"%s %s: four rows of %d frames inside the atlas" % [sheet["atlas"], anim, r[3]])
				var body: Array = visual["anims"].get(anim, [])
				if r[2] == 64 and not body.is_empty():
					check(r[3] >= body[3], "%s %s: a frame for every frame of the body" % [sheet["atlas"], anim])
		for anim: String in visual["animations"]:
			var frames: Array = visual["animations"][anim]["frames"]
			var r: Array = visual["anims"][anim]
			var count: int = (r[4] as Array).size() if r.size() > 4 else r[3]  # borrowed columns, in order
			check(frames.all(func(f: int) -> bool: return f < count), "%s %s: the timeline is on the sheet" % [plan, anim])


func test_four_directions_with_diagonals_seen_from_the_side() -> void:
	var content := _content()
	var doll := Art.character_sprite(content, content.visual_of("base:human_m"), _look("base:human_m"))
	for case: Array in [[Vector2.UP, 0], [Vector2.LEFT, 1], [Vector2.DOWN, 2], [Vector2.RIGHT, 3],
			[Vector2(1, 1), 3], [Vector2(-1, -1), 1], [Vector2(1, 2), 2], [Vector2(-1, -2), 0]]:
		doll.turn_to(case[0])
		eq(doll._dir, case[1], "facing %s" % case[0])
		for layer: Array in doll._layers:
			var s: Sprite2D = layer[1]
			eq(int(s.region_rect.position.y) / int(s.region_rect.size.y), case[1], "every layer on the row of the direction")
			check(not s.flip_h, "drawn, not mirrored")
	doll.free()


func test_layers_follow_the_body_and_keep_the_feet() -> void:
	var content := _content()
	for plan: String in PLANS:
		var visual := content.visual_of(plan)
		var doll := Art.character_sprite(content, visual, _look(plan))
		eq(doll._layers.size(), 1 + 3 + 2 + 3, "body, head with nose and brows, braid front and back, three clothes")
		doll.show_at(Vector2.ZERO, 0.0, true)
		for step in 10:
			doll.show_at(Vector2(step + 1, 0) * 3.0, 0.1, true)
			var body: Sprite2D = doll._layers[0][1]
			for layer: Array in doll._layers:
				var s: Sprite2D = layer[1]
				if s.visible:
					eq(s.region_rect.position.x - float(layer[2]["anims"][doll._anim_name][0]),
						body.region_rect.position.x - float(visual["anims"][doll._anim_name][0]), "same frame as the body")
					eq(s.offset * s.scale, Vector2(-16, -31), "feet at the origin, half a texel a pixel")
		var z := doll.get_children().map(func(n: Node) -> int:
			return int(doll._layers.filter(func(l: Array) -> bool: return l[1] == n)[0][2]["z"]))
		var sorted := z.duplicate()
		sorted.sort()
		eq(z, sorted, "drawn back to front by depth")
		doll.free()


func test_walk_run_and_idle_play_their_own_frames() -> void:
	var content := _content()
	var doll := Art.character_sprite(content, content.visual_of("base:human_f"), _look("base:human_f"))
	doll.show_at(Vector2.ZERO, 0.0, true)
	doll.show_at(Vector2(20, 0), 0.1, true)
	eq(doll._anim_name, "run", "fast movement runs")
	doll.show_at(Vector2(20, 0), 0.1, true)
	eq(doll._anim_name, "idle", "standing still")
	var steps := [0]
	doll.stepped.connect(func() -> void: steps[0] += 1)
	var columns := {}
	var x := 20.0
	for i in 20:
		x += CharacterSprite.WALK_PX_PER_SEC * 0.05
		doll.show_at(Vector2(x, 0), 0.05, true)
		eq(doll._anim_name, "walk")
		columns[doll._column] = true
	check(columns.size() >= 6, "the walk goes through its frames: %s" % str(columns.keys()))
	check(steps[0] >= 2, "feet come down while walking: %d" % steps[0])
	doll.free()


func test_swings_play_once_with_the_tool_in_its_frames() -> void:
	var content := _content()
	var view := WorldView.new()
	view.content = content
	var doll := view._character("me", _look("base:human_m")) as LpcSprite
	doll.show_at(Vector2.ZERO, 0.0, true)
	for case: Array in [["base:axe", "chop", "chop"], ["base:pickaxe", "mine", "chop"],
			["base:spear", "thrust", "thrust"], ["base:bow", "draw", "shoot"], ["", "lunge", "slash"]]:
		doll.hold(view.item_picture(case[0]), view.item_grip(case[0]), case[0])
		eq(doll._held_item, case[0], "drawn with frames of its own: " + case[0])
		check(doll._held == null or not doll._held.visible, "no picture pinned to the hand")
		doll.show_at(Vector2.ZERO, 0.1, true)
		if case[0] != "":
			check(doll._held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible),
				"standing with %s shows it" % case[0])
		eq(case[1], view.swing_kind(case[0]))
		doll.swing(Vector2.RIGHT, case[1])
		var seen := {}
		var t := 0.0
		while doll.swinging() and t < 2.0:
			doll.show_at(Vector2.ZERO, 0.02, true)
			t += 0.02
			seen[doll._column] = true
			if case[0] != "" and doll.swinging():
				check(doll._held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible),
					"%s is drawn through the %s" % [case[0], case[2]])
		check(not doll.swinging(), case[1] + " finishes")
		check(seen.size() >= 3, "%s plays its frames: %s" % [case[2], str(seen.keys())])
		eq(doll.scale, Vector2.ONE, "no lean of the whole picture")
	doll.hold(view.item_picture("base:plank"), view.item_grip("base:plank"), "base:plank")
	check(doll._held != null and doll._held.visible and doll._held_layers.is_empty(), "other things are their picture at the hand")
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


func test_a_rod_is_cast_with_its_own_frames_and_carried_as_a_picture() -> void:
	var content := _content()
	var view := WorldView.new()
	view.content = content
	var doll := view._character("me", _look("base:human_f")) as LpcSprite
	doll.show_at(Vector2.ZERO, 0.0, true)
	doll.hold(view.item_picture("base:fishing_rod"), view.item_grip("base:fishing_rod"), "base:fishing_rod")
	eq(doll._held_item, "base:fishing_rod")
	doll.show_at(Vector2(40, 0), 0.2, true)
	check(doll._held != null and doll._held.visible, "walking: the rod has no frames, its picture is in the hand")
	check(not doll._held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible), "and no cast frames")
	eq(view.swing_kind("base:fishing_rod"), "cast")
	doll.swing(Vector2.RIGHT, "cast")
	var body := {}
	var rod := 0
	var t := 0.0
	while doll.swinging() and t < 3.0:
		doll.show_at(Vector2(40, 0), 0.02, true)
		t += 0.02
		if not doll.swinging():
			break
		check(not doll._held.visible, "no picture while the rod is cast")
		var s: Sprite2D = doll._layers[0][1]
		body[int(s.region_rect.position.x)] = true
		if doll._held_layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible):
			rod += 1
	check(t > 0.5, "a cast takes its time: %.2f s" % t)
	eq(body.size(), 6, "the body plays the thrust's six columns")
	check(rod > 30, "the rod is drawn through most of the cast: %d" % rod)
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


func test_colours_map_to_the_nearest_ramp() -> void:
	var content := _content()
	var visual := content.visual_of("base:human_m")
	var pals := Art.lpc_palettes(visual["palettes_path"])
	eq(Art.lpc_ramp(pals["body"], "#ae6b3f", "light"), "olive", "an editor colour is its ramp")
	eq(Art.lpc_ramp(pals["body"], "#503327", "light"), "black", "an old colour finds the nearest skin")
	eq(Art.lpc_ramp(pals["hair"], "#2f7a52", "chestnut"), "dark_gray", "never a fantasy ramp")
	eq(Art.lpc_ramp(pals["body"], "", "light"), "light")
	for skin: String in CharacterEditor.SKIN:
		eq(Art.lpc_middle(pals["body"]["ramps"][Art.lpc_ramp(pals["body"], skin, "")]), skin, "editor skin " + skin)
	for hair: String in CharacterEditor.HAIR_COLORS:
		eq(Art.lpc_middle(pals["hair"]["ramps"][Art.lpc_ramp(pals["hair"], hair, "")]), hair, "editor hair " + hair)
	var m := Art.lpc_material(visual, visual, {"skin": "#ae6b3f"}) as ShaderMaterial
	check(m != null, "a skin other than the drawn one recolours")
	eq(int(m.get_shader_parameter("count")), (pals["body"]["ramps"]["light"] as Array).size())
	eq((m.get_shader_parameter("to_colors") as PackedColorArray)[2], Color(pals["body"]["ramps"]["olive"][2]))
	check(Art.lpc_material(visual, visual, {"skin": "#e4a47c"}) == null, "the drawn skin needs no shader")
	var shirt: Dictionary = visual["worn_overrides"]["base:linen_shirt"]["sheets"][0]
	eq(Art.lpc_material(visual, shirt, {}), null, "linen is the drawn white")
	var trousers: Dictionary = visual["worn_overrides"]["base:work_trousers"]["sheets"][0]
	check(Art.lpc_material(visual, trousers, {}) != null, "trousers are dyed their own colour")


func test_credits_name_every_source() -> void:
	var credits := FileAccess.get_file_as_string("res://CREDITS-art.md")
	for part: String in ["body/bodies/male", "body/bodies/female", "head/heads/human/male", "hair/braid",
			"torso/clothes/longsleeve", "legs/pants", "feet/boots", "tools/axe", "weapon/polearm/spear"]:
		check(credits.contains(part), "credited: " + part)
	check(credits.contains("CC-BY-SA 3.0") and credits.contains("OGA-BY 3.0"), "licences named")


func test_malformed_lpc_visuals_are_content_errors() -> void:
	var body := {"id": "test:body", "kind": "body_plan", "slots": ["body"], "appearance_slots": [],
		"colors": ["skin"], "directions": 4}
	var sheet := {"atlas": "a.png", "anims": {"idle": [0, 0, 64, 2], "walk": [128, 0, 64, 9]}, "z": 10}
	var visual := {"id": "test:visual/body", "kind": "visual", "for": "test:body", "mode": "character",
		"format": "lpc", "rect": [0, 0, 64, 64], "origin": [32, 62], "rows": ["n", "w", "s", "e"],
		"animations": {"idle": {"frames": [0, 1], "fps": 3}, "walk": {"frames": [1, 2], "fps": 10}},
		"swings": {"lunge": "walk"}}
	visual.merge(sheet)
	eq(ContentRegistry.from_defs([body, visual]).errors, PackedStringArray(), "a well-formed LPC body loads")
	for bad: Dictionary in [{"rows": ["s", "e", "n"]}, {"animations": {"idle": {"frames": [0], "fps": 3}}},
			{"animations": {"idle": {"frames": [], "fps": 3}, "walk": {"frames": [1], "fps": 10}}},
			{"swings": {"chop": "chop"}}, {"anims": {"idle": [0, 0, 64]}},
			{"style_overrides": {"test:body": {"layer": "hair", "sheets": [{"atlas": ""}]}}}]:
		check(not ContentRegistry.from_defs([body, visual.merged(bad, true)]).errors.is_empty(),
			"rejected before drawing: %s" % str(bad))


func test_a_diagonal_walk_keeps_one_facing() -> void:
	var content := _content()
	var view := WorldView.new()
	view.content = content
	var doll := view._character("deer", {"body_plan": "base:deer"}) as LpcSprite
	doll.show_at(Vector2.ZERO, 0.0, true)
	var turns := 0
	var was := -1
	var at := Vector2.ZERO
	for i in 60:  # south-east, the steps a little uneven as replicas come
		at += Vector2(1.0 + (0.15 if i % 2 == 0 else -0.15), 1.0 + (-0.15 if i % 2 == 0 else 0.15))
		doll.show_at(at, 0.05, true)
		if was >= 0 and doll._dir != was:
			turns += 1
		was = doll._dir
	eq(turns, 0, "no flicking between side and front on a diagonal")
	for i in 10:
		at += Vector2(0, 2)
		doll.show_at(at, 0.05, true)
	eq(doll._dir, 2, "straight south: it turns")
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame
