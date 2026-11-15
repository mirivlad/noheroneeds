extends SceneTree
## Run in two fresh Godot processes and compare the emitted JSON snapshots.
func _initialize() -> void:
	var library := ModelLibrary3D.new()
	var result := {}
	for species: String in PlantMeshes3D.SPECIES + ["bush", "berry_bush", "dry_bush"]:
		var id := "base:" + species
		for cell: Vector2i in [Vector2i.ZERO, Vector2i(31, 32), Vector2i(-32, -1), Vector2i(-1, -33)]:
			var variant := PlantMeshes3D.variant_at(id, cell)
			var mesh := library.mesh_for(id, {"kind": "plant"}, variant)
			result[id + "|" + str(cell)] = {"variant": variant,
				"vertices_hash": str(hash(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]))}
	print("PLANT_DETERMINISM:" + JSON.stringify(result))
	quit()
