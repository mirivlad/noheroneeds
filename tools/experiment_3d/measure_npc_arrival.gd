extends SceneTree
## Isolates the first appearance of human NPCs from chunk generation.
## godot --path . --audio-driver Dummy -s res://tools/experiment_3d/measure_npc_arrival.gd

func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	root.size = Vector2i(960, 540)
	Engine.max_fps = 60
	var content := ContentRegistry.load_packs(["res://content/base"])
	var wire := MemoryTransport.MemoryNetwork.new()
	var client := GameClient.new(wire.client(), null, PackedByteArray(), content)
	client.state = "playing"
	client.location = Levels.SURFACE
	var view := WorldView3D.new()
	view.setup(content, client)
	root.add_child(view)
	view.eye.position = Vector3(0, 9, 12)
	view.eye.look_at(Vector3.ZERO)
	view.eye.size = 12.0
	for i in 8:
		var look := {"body_plan": "base:human_ro_f" if i % 2 else "base:human_ro_m",
			"styles": {"hair": ["base:human_ro_hair_tousled", "base:human_ro_hair_bob",
				"base:human_ro_hair_twintails", "base:human_ro_hair_long"][i % 4]},
			"worn": {"torso": "base:linen_shirt", "legs": "base:work_trousers", "feet": "base:boots",
				"headwear": "base:felt_hat" if i % 2 else "base:fur_hood"}, "colors": {}}
		client.entities["villager-" + str(i)] = {"kind": "creature", "creature": "base:human_ro_m",
			"x": (i - 4) * Movement.UNIT, "y": Movement.UNIT, "appearance": look}
	var started := Time.get_ticks_usec()
	var max_update := 0.0
	var max_frame := 0.0
	var frames := 0
	while Time.get_ticks_usec() - started < 10000000:
		var began := Time.get_ticks_usec()
		view._update_actors(1.0, 1.0 / 60.0)
		max_update = maxf(max_update, (Time.get_ticks_usec() - began) / 1000.0)
		await process_frame
		max_frame = maxf(max_frame, (Time.get_ticks_usec() - began) / 1000.0)
		frames += 1
		if view.sprite_count() == 8: break
	var visible := view.sprite_count()
	print(JSON.stringify({"npc": visible, "frames": frames, "max_update_ms": max_update,
		"max_frame_ms": max_frame, "all_ready_ms": (Time.get_ticks_usec() - started) / 1000.0}))
	view.free()
	Art.clear()
	quit(0 if visible == 8 else 1)
