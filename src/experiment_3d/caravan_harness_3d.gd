class_name CaravanHarness3D
extends Node3D
## Connect the actual wagon to the exact flank/bridle points filmed in each pose.
var shafts: Array[MeshInstance3D] = []
var reins: Array[MeshInstance3D] = []

func setup(wagon: Node3D) -> void:
	var wood := _material(wagon,"weathered oak",Color("6f4d27"))
	var rope := _material(wagon,"rope",Color("9e8762"))
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	for i in 2:
		var shaft := MeshInstance3D.new()
		shaft.mesh = unit
		shaft.material_override = wood
		add_child(shaft)
		shafts.append(shaft)
		var rein := MeshInstance3D.new()
		rein.mesh = unit
		rein.material_override = rope
		add_child(rein)
		reins.append(rein)

func follow(wagon: Node3D, horse: BillboardActor3D, camera: Camera3D) -> void:
	var forward := Vector3(horse.facing.x,0,horse.facing.y)
	var side := Vector3(-forward.z,0,forward.x)
	for i in 2:
		var sign_of_side := -1.0 if i==0 else 1.0
		var flank := horse.harness_anchor(i,camera)
		var bridle := horse.harness_anchor(i+2,camera)
		if flank == Vector3.INF:
			flank = horse.position + side*sign_of_side*.55 + Vector3.UP*1.35
			bridle = horse.position + forward*.8 + side*sign_of_side*.09 + Vector3.UP*2.05
		_place(shafts[i],wagon.global_transform*Vector3(sign_of_side*.43,.53,-.25),flank,.10)
		_place(reins[i],wagon.global_transform*Vector3(sign_of_side*.2,1.30,-.69),bridle,.026)

func _place(part: MeshInstance3D, start: Vector3, end: Vector3, width: float) -> void:
	var direction := end-start
	if direction.length_squared()<.0001:
		part.hide()
		return
	part.show()
	var basis := Basis.looking_at(direction.normalized(),Vector3.UP)
	basis.x *= width
	basis.y *= width
	basis.z *= direction.length()
	part.global_transform = Transform3D(basis,(start+end)*.5)

func _material(wagon: Node3D, title: String, fallback: Color) -> Material:
	for node: Node in wagon.find_children("*","MeshInstance3D",true,false):
		var model := node as MeshInstance3D
		for surface in model.mesh.get_surface_count():
			var material := model.get_active_material(surface)
			if material and material.resource_name == title:
				return material
	var material := StandardMaterial3D.new()
	material.albedo_color = fallback
	material.roughness = .88
	return material
