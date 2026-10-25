extends SceneTree
## Native GPU captures: same original paper doll at the 2D camera's 2x
## and in Sprite3D at one source texel per logical screen pixel.
var output := "/tmp/nhn-quality-sprites"
func _initialize() -> void: call_deferred("run")
func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output)
	var content := ContentRegistry.load_packs(["res://content/base"])
	var results := []
	for id: String in ["base:human_m", "base:sheep"]:
		var looks := {"body_plan":id, "styles":CharacterLibrary.STYLE_DEFAULTS.duplicate(), "colors":CharacterLibrary.COLOR_DEFAULTS.duplicate(), "worn":WorldLibrary.STARTER_OUTFIT.duplicate()} if id == "base:human_m" else {"body_plan":id}
		var visual := content.visual_of(id)
		var reference := SubViewport.new()
		reference.size = Vector2i(192,192)
		reference.transparent_bg = true
		reference.disable_3d = true
		reference.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		reference.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		root.add_child(reference)
		var doll := Art.character_sprite(content, visual, looks)
		doll.scale = Vector2.ONE * 2
		doll.position = Vector2(96,152)
		reference.add_child(doll)
		var vp := SubViewport.new()
		vp.size = Vector2i(192,192)
		vp.own_world_3d = true
		vp.transparent_bg = true
		vp.msaa_3d = Viewport.MSAA_2X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(vp)
		var eye := Camera3D.new()
		eye.projection = Camera3D.PROJECTION_ORTHOGONAL
		eye.size = 6  # 192 / 32: one texel per pixel.
		vp.add_child(eye)
		var actor := BillboardActor3D.new()
		actor.setup(content,visual,looks,{})
		vp.add_child(actor)
		for direction in 4:
			var yaw := direction * PI / 2
			actor.show_actor(Vector3.ZERO, yaw, 0, true)
			doll._face(Vector2.DOWN.rotated(-yaw))
			doll.show_at(Vector2.ZERO, 0, true)
			doll.position = Vector2(96,152)
			eye.position = Vector3(0,4,4).rotated(Vector3.UP,-yaw)
			eye.look_at(Vector3.ZERO)
			# Centre the feet at the same output pixel as in 2D.
			eye.h_offset = 0
			eye.v_offset = 56.0 / 32.0
			for i in 5: await process_frame
			await RenderingServer.frame_post_draw
			var ref := reference.get_texture().get_image()
			var composed := actor.viewport.get_texture().get_image()
			var actual := vp.get_texture().get_image()
			var name := id.trim_prefix("base:") + "-" + str(direction)
			ref.save_png(output.path_join(name + "-2d.png"))
			actual.save_png(output.path_join(name + "-3d.png"))
			composed.save_png(output.path_join(name + "-composition.png"))
			results.append({"name":name,"reference_size":str(ref.get_size()),"composition_bytes_equal":ref.get_data() == composed.get_data()})
		reference.free()
		vp.free()
	FileAccess.open(output.path_join("sprites.json"),FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	Art.clear()
	quit()
