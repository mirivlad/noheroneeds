extends TestCase


func test_the_editor_swings_a_sword_on_every_body_without_giving_it_to_the_character() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var editor := CharacterEditor.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(editor)
	editor.setup(content)
	editor.preview.set_process(false)
	for plan: String in CharacterEditor.PLANS:
		var i := CharacterEditor.PLANS.find(plan)
		editor.sex_pick.select(i)
		editor.sex_pick.item_selected.emit(i)
		i = CharacterEditor.IN_HANDS.values().find("base:iron_sword")
		editor.hands_pick.select(i)
		editor.hands_pick.item_selected.emit(i)
		i = CharacterEditor.ACTIONS.values().find("blow")
		editor.action_pick.select(i)
		editor.action_pick.item_selected.emit(i)
		editor.preview._process(0.31)
		var doll := editor.preview.doll
		eq(doll._held_item, "base:iron_sword", plan + " holds the sword")
		eq(doll._swing_kind, "slash", plan + " slashes, rather than chopping")
		check(doll.swinging(), plan + " plays the blow")
		var layers: Array = doll.get("_held_layers")
		check(layers.any(func(l: Array) -> bool: return (l[1] as Sprite2D).visible), plan + " draws its sword frames")
		check(not editor.appearance().has("held"), "trying a sword gives no starting weapon")
		editor.preview.action = "idle"
		editor.preview._process(1.0)
	editor.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


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
	check(library.edit(file, "Аня", "base:human_f", styles, colors), library.last_error)
	var after := library.load_character(file)
	eq(after.character_id, before.character_id)
	eq(after.attributes, before.attributes)
	eq(after.skills, before.skills)
	eq(after.equipment, before.equipment)
	eq(after.inventory.to_data(), before.inventory.to_data())
	eq(after.body_plan, "base:human_f")
	eq(after.styles, styles)
	eq(after.colors, colors)
	check(CharacterFile.read(library.file_bytes(file), content).ok, "edited file has a valid owner signature")
	check(not library.edit(file, "", after.body_plan, styles, colors), "blank name refused")
	eq(library.load_character(file).body_plan, after.body_plan, "refusal preserves the file")
	var signed := library.file_bytes(file)
	check(not library.edit(file, "Аня", after.body_plan, styles, {"skin":"red"}), "invalid palette colour refused")
	eq(library.file_bytes(file), signed, "invalid edits cannot overwrite the signed file")


func test_changing_equipment_preserves_walk_facing_held_tool_and_swing() -> void:
	var view := WorldView.new()
	view.content = ContentRegistry.load_packs(["res://content/base"])
	var look := {"body_plan":"base:human_m", "styles":{"face":"base:human_face_soft","hair":"base:human_hair_short"},
		"worn":WorldLibrary.STARTER_OUTFIT.duplicate()}
	var doll := view.doll_for("actor", look)
	doll.show_at(Vector2.ZERO, 0.0, true)
	doll.show_at(Vector2(-4, -4), 0.17, true)
	doll.hold(view.item_picture("base:axe"), view.item_grip("base:axe"), "base:axe")
	var state := [doll._walk, doll._dir, doll._column, doll._shown, doll.position, doll._held_item]
	look["worn"]["headwear"] = "base:felt_hat"
	var updated := view.doll_for("actor", look, doll)
	eq(updated, doll, "same node")
	eq([doll._walk, doll._dir, doll._column, doll._shown, doll.position, doll._held_item], state,
		"no phase, facing or tool reset")
	eq(doll._held_layers.size(), 3, "the axe is drawn again over the new clothes")
	doll.swing(Vector2.LEFT, "chop")
	doll.show_at(Vector2(-4, -4), 0.05, true)
	var swing := [doll._swing_t, doll._swing_dir, doll._column, doll.scale, doll.position]
	look["worn"].erase("torso")
	view.doll_for("actor", look, doll)
	eq([doll._swing_t, doll._swing_dir, doll._column, doll.scale, doll.position], swing,
		"changing clothes during a blow leaves it intact")
	doll.free()
	view.free()
	await (Engine.get_main_loop() as SceneTree).process_frame
