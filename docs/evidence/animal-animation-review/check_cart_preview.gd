extends "res://tools/experiment_3d/check_horse_candidate.gd"
var preview_applied := false

func capture(name: String) -> void:
	if not preview_applied:
		for id: String in view._actors:
			var actor := view._actors[id] as BillboardActor3D
			if actor.cart == null:
				continue
			var document := GLTFDocument.new()
			var state := GLTFState.new()
			var error := document.append_from_file("res://build/animal_sprites/motion-review/cart.glb",state)
			verify(error==OK,"preview cart glTF loaded")
			if error!=OK:
				continue
			var scene := document.generate_scene(state) as Node3D
			actor.remove_child(actor.cart)
			actor.cart.queue_free()
			actor.cart = scene
			actor.add_child(scene)
			actor.show_cart(true)
			preview_applied = true
			break
	await super.capture(name)
