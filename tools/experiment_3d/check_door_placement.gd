extends "res://tools/experiment_3d/check_interior_cutaway.gd"
## Fresh disposable world: generated doors plus actual player construction.
var door_plan := {}

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--old-world="): continue
		var path := arg.trim_prefix("--old-world=")
		var before := FileAccess.get_sha256(path)
		var old := ServerWorld.open(path, ContentRegistry.load_packs(["res://content/base"]), {"require_planned": true})
		verify(old == null and ServerWorld.open_error.contains("генератора"), "old generator world is explicitly refused")
		if old: old.close()
		verify(FileAccess.get_sha256(path) == before, "refused original world database remains byte-for-byte unchanged")
	await super.run()

func shot(name: String, rect: Rect2i, angle: float) -> void:
	await super.shot(name, rect, angle)
	if name == "upper-se": await check_generated_door(rect, angle)
	if name == "outside-restored": await check_installation()

func check_generated_door(rect: Rect2i, angle: float) -> void:
	var original := Movement.cell_of(g.client.position)
	var id := String(world._props_at(g.client.location, original.x, original.y).get("hospitality", ""))
	door_plan = world.hospitality.plan(id)
	var door := Vector2i.MAX
	for cell: Vector2i in door_plan["upper"]:
		if door_plan["upper"][cell].get("structure", "") != "base:wood_door": continue
		if world.content.get_def(world._part_at(g.client.location, cell.x, cell.y - 1, "structure")).get("role") == "wall" \
				and world.content.get_def(world._part_at(g.client.location, cell.x, cell.y + 1, "structure")).get("role") == "wall": door = cell
	verify(door != Vector2i.MAX, "generated inn has a door in a longitudinal partition")
	if door == Vector2i.MAX: return
	verify(world._props_at(g.client.location, door.x, door.y).get("facing") in ["e", "w"], "generated door frame follows its actual partition")
	await move_to(door + Vector2i.LEFT * 2)
	var result := await request({"type": "use", "location": g.client.location, "x": door.x, "y": door.y})
	verify(result.get("ok", false) and result.get("open", false), "open the generated door through the ordinary request")
	await super.shot("door-open", rect, angle)
	result = await request({"type": "use", "location": g.client.location, "x": door.x, "y": door.y})
	verify(result.get("ok", false) and not result.get("open", true), "close the same generated door")
	await move_to(original)
	await super.shot("door-closed", rect, angle)

func detail(name: String, cell: Vector2i) -> void:
	view.yaw = -.6
	view.tilt = 45
	view.zoom = 7
	await settle()
	var at := Vector2(cell) + Vector2.ONE * .5
	var focus := Vector3(at.x, view.elevation(at) + .9, at.y)
	view.eye.size = 7
	view.eye.position = focus + Vector3(0, sin(deg_to_rad(45)), cos(deg_to_rad(45))).rotated(Vector3.UP, .6) * 65
	view.eye.look_at(focus, Vector3.UP)
	await capture(name)

func check_installation() -> void:
	var centre := Vector2i.MAX
	for cell: Vector2i in door_plan["cells"]:
		var clear := true
		for dy in range(-1, 3):
			for dx in range(-1, 2):
				var spec: Dictionary = door_plan["cells"].get(cell + Vector2i(dx, dy), {})
				if spec.get("ground", "") != "base:wood_floor" or spec.get("structure", "") != "" or spec.get("ceiling", "") == "": clear = false
		if clear:
			centre = cell
			break
	verify(centre != Vector2i.MAX, "fixture has a clear indoor construction site")
	if centre == Vector2i.MAX: return
	world.grant(g.client.character_id, "base:plank", 20)
	await move_to(centre + Vector2i(0, 2))
	for side in [-1, 0, 1]:
		var result := await request({"type": "build", "location": "surface", "x": centre.x + side, "y": centre.y, "part": "base:wood_wall"})
		verify(result.get("ok", false), "build an actual owned wall block")
	await detail("installation-wall", centre)
	var before := world.inventory(g.client.character_id).count("base:plank")
	var result := await request({"type": "build", "location": "surface", "x": centre.x, "y": centre.y, "part": "base:wood_door", "facing": "e"})
	verify(result.get("ok", false), "convert the owned middle wall through the normal build request")
	verify(world.inventory(g.client.character_id).count("base:plank") == before - 1, "the old wall is credited, only one extra plank is charged")
	verify(world._props_at("surface", centre.x, centre.y).get("facing") == "s", "perpendicular input cannot rotate the door across the wall")
	await detail("installation-door", centre)
	result = await request({"type": "use", "location": "surface", "x": centre.x, "y": centre.y})
	verify(result.get("ok", false) and result.get("open", false), "open the installed leaf")
	await detail("installation-open", centre)
	result = await request({"type": "dismantle", "location": "surface", "x": centre.x, "y": centre.y, "layer": "structure"})
	verify(result.get("ok", false), "remove the door leaving an opening")
	result = await request({"type": "build", "location": "surface", "x": centre.x, "y": centre.y, "part": "base:wood_door", "facing": "n"})
	verify(result.get("ok", false), "install into that existing opening with the other opening side")
