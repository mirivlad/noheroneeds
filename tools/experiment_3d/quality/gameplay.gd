extends "res://tools/experiment_3d/check_runtime.gd"
## Additional real-server checks for the quality changes.
func run() -> void:
	output = "/tmp/nhn-quality-interactions"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(output)
	var profile := output.path_join("profile-" + str(Time.get_ticks_usec()))
	var lib := WorldLibrary.new(profile.path_join("worlds"))
	var world_id := lib.create("Quality interactions 431", {"seed":"431", "starter_kit":true})
	var prepared := ServerWorld.open(lib.db_path(world_id),ContentRegistry.load_packs(["res://content/base"]),{"seed":431})
	prepared.close()
	app = App.new()
	app.configure({"renderer":"3d", "profile_dir":profile, "world":world_id, "time":"10"})
	root.add_child(app)
	g = app.game
	g.set_process(false)
	view = g.view as WorldView3D
	world = g.game.world
	g.game.server.wait_for_disk = true
	verify(world.world_seed==431,"actual server world uses seed 431")
	await pump(40)
	await move_to(Vector2i.ZERO)
	var built := true
	for y in range(-2,2):
		for x in range(-2,3):
			var r := await request({"type":"build", "location":"surface", "x":x,"y":y,"part":"base:plank_floor"})
			built = built and r.get("ok",false)
	verify(built,"player lays real 5x4 floor through server requests")
	for x in range(-1,2):
		var r := await request({"type":"build", "location":"surface", "x":x,"y":-1,"part":"base:thatch_roof"})
		verify(r.get("ok",false),"real roof part built at %d,-1" % x)
	await move_to(Vector2i(0,3))
	await settle()
	var rect := view.building_footprint(Vector2i(0,-1))
	verify(rect == Rect2i(-2,-2,5,4),"player roof uses live floor footprint across negative chunk border")
	var corners := [Vector2i(-2,-2),Vector2i(3,-2),Vector2i(-2,2),Vector2i(3,2)]
	var h := view.corner_height(corners[0])
	var level := true
	for c:Vector2i in corners: level = level and absf(view.corner_height(c)-h)<.001
	verify(level,"player foundation is level across four server chunks")
	view.yaw=.6
	view.tilt=55
	await capture("player-roof-before")
	await move_to(Vector2i(0,0))
	var result := await request({"type":"dismantle", "location":"surface", "x":0,"y":-1,"layer":"roof"})
	verify(result.get("ok",false),"normal dismantle removes the selected roof tile")
	await move_to(Vector2i(0,3))
	await settle()
	verify(not has_roof(Vector2i(0,-1),rect),"removed roof tile has no rendered patch")
	verify(has_roof(Vector2i(-1,-1),rect) and has_roof(Vector2i(1,-1),rect),"neighboring roof patches survive removal")
	verify(view.building_footprint(Vector2i(-1,-1)) == rect,"removal keeps surviving ridge geometry stable")
	await capture("player-roof-after")
	await move_to(Vector2i(-231,816))
	view.zoom=26
	view.tilt=45
	await settle()
	verify(not world.is_solid("surface",-231,816),"original mountain road cell is server-passable")
	var direction := Vector2i.ZERO
	for d:Vector2i in [Vector2i.RIGHT,Vector2i.DOWN,Vector2i.LEFT,Vector2i.UP,Vector2i(1,1),Vector2i(-1,1),Vector2i(-1,-1),Vector2i(1,-1)]:
		if world._part_at("surface",-231+d.x,816+d.y,"ground") == "base:dirt" and not world.is_solid("surface",-231+d.x,816+d.y):
			direction=d
			break
	var start := g.client.position
	g.client.move=direction
	var feet := true
	for i in 20:
		await pump(1)
		for actor:Node in view._actors.values():
			if actor is BillboardActor3D:
				var p:Vector3=actor.position
				feet=feet and absf(p.y-view.elevation(Vector2(p.x,p.z)))<.001
	g.client.move=Vector2i.ZERO
	print("MOUNTAIN_WALK " + str({"direction":direction,"start":start,"end":g.client.position}))
	verify(direction != Vector2i.ZERO and g.client.position != start,"real server movement along sloped mountain road")
	verify(feet,"own character and interpolated NPC/animal feet stay on rendered triangles")
	await move_to(Vector2i(-224,816))
	await settle()
	var left := edge_vertices("surface|-8|25",-224)
	var right := edge_vertices("surface|-7|25",-224)
	var seam := left.size()>0 and right.size()>0
	for key:String in left:
		seam=seam and right.has(key) and (left[key] as Vector3).distance_to(right.get(key,Vector3.INF))<.00001
	verify(seam,"actual neighboring ground meshes share positions and normals on chunk edge")
	verify(view._geometry.size()<=25 and view.pending_chunks()==0,"streaming is bounded and finishes after crossing chunk boundary")
	await capture("mountain-walking")
	var report := {"checks":checks,"failures":failures,"adapter":RenderingServer.get_video_adapter_name(),"seed":431}
	FileAccess.open(output.path_join("interactions.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	app.quit()
	app.free()
	await process_frame
	Art.clear()
	print("QUALITY_INTERACTIONS " + JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)

func has_roof(cell:Vector2i,_rect:Rect2i)->bool:
	var mesh := view.roof_mesh(cell)
	for holder:Node in view._geometry.values():
		for node:Node in holder.get_children():
			if node is MultiMeshInstance3D and node.multimesh.mesh==mesh:
				for i in node.multimesh.instance_count:
					var p:Vector3=node.multimesh.get_instance_transform(i).origin
					if Vector2(p.x,p.z).distance_to(Vector2(cell)+Vector2.ONE*.5)<.001:return true
	return false

func edge_vertices(key:String,x:int)->Dictionary:
	var out := {}
	if not view._geometry.has(key):return out
	for node:Node in view._geometry[key].get_children():
		if node is MeshInstance3D:
			var arrays:Array=node.mesh.surface_get_arrays(0)
			var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
			for i in vertices.size():
				if absf(vertices[i].x-x)<.001:out[str(vertices[i])]=normals[i]
			break # The first mesh is ground, the second optional mesh is rock.
	return out
