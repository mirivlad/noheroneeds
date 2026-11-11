extends TestCase
## Doors follow straight wall axes; both client preview and server share it.

class View:
	var chunk := Chunk.new()

	func build_chunk(_location: String, cx: int, cy: int) -> Chunk:
		return chunk if cx == 0 and cy == 0 else null

	func build_kind(_location: String) -> String:
		return Levels.SURFACE

	func build_z(_location: String) -> int:
		return 0

	func build_max_levels() -> int:
		return 3

	func build_someone_on(_location: String, _x: int, _y: int) -> bool:
		return false


func _check(view: View, content: ContentRegistry, part: String, x: int, y: int) -> String:
	return BuildRules.check(view, content, part, "surface", x, y, "")


func test_doors_align_to_either_wall_axis() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var v := View.new()
	for y in range(2, 7):
		v.chunk.set_cell("structure", 3, y, "base:wood_wall")  # a side wall, top to bottom
	v.chunk.set_cell("structure", 10, 5, "base:wood_wall")
	v.chunk.set_cell("structure", 12, 5, "base:wood_wall")  # a wall across, a gap in it
	v.chunk.set_cell("structure", 3, 4, "")
	eq(_check(v, content, "base:wood_door", 3, 4), "", "vertical wall opening automatically turns the door")
	eq(BuildRules.placement_facing(v, content, "base:wood_door", "surface", 3, 4, "s"), "e", "a perpendicular requested direction is normalized to the wall")
	eq(_check(v, content, "base:wood_door", 11, 5), "", "into a wall across")
	eq(_check(v, content, "base:wood_gate", 3, 4), "", "gate also follows its opening")
	eq(_check(v, content, "base:wood_window", 3, 4), "", "a window turns to the side")
	v.chunk.set_cell("structure", 11, 5, "base:wood_door")
	eq(_check(v, content, "base:wood_wall", 11, 4), "door_beside", "no wall above a door")
	eq(_check(v, content, "base:wood_wall", 11, 6), "door_beside", "nor below")
	eq(_check(v, content, "base:wood_wall", 13, 5), "", "beside it along the wall")

func test_rotated_doors_and_gates_preserve_their_approach() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	for facing: String in ["n", "e", "s", "w"]:
		var v := View.new()
		var at := Vector2i(10, 10)
		var normal: Vector2i = ContentRegistry.FACINGS[facing]
		var along := Vector2i(-normal.y, normal.x)
		for side: int in [-1, 1]:
			var wall := at + along * side
			v.chunk.set_cell("structure", wall.x, wall.y, "base:wood_wall")
		for part: String in ["base:wood_door", "base:wood_gate"]:
			eq(BuildRules.check(v, content, part, "surface", at.x, at.y, facing), "", "a door may be built in either wall orientation")
		v.chunk.set_cell("structure", at.x, at.y, "base:wood_door")
		v.chunk.set_props(at.x, at.y, {"facing": facing})
		var blocked := at + normal
		eq(_check(v, content, "base:wood_wall", blocked.x, blocked.y), "door_beside", "building may not block either rotated approach")

func test_free_doors_corners_and_junctions_are_refused() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var v := View.new()
	eq(_check(v, content, "base:wood_door", 10, 10), "door_frame", "a freestanding door has no wall axis")
	v.chunk.set_cell("structure", 9, 10, "base:wood_wall")
	eq(_check(v, content, "base:wood_door", 10, 10), "door_frame", "an empty opening needs both jambs")
	v.chunk.set_cell("structure", 10, 9, "base:wood_wall")
	eq(_check(v, content, "base:wood_door", 10, 10), "door_frame", "a corner is ambiguous")
	v.chunk.set_cell("structure", 11, 10, "base:wood_wall")
	eq(_check(v, content, "base:wood_door", 10, 10), "door_frame", "a T junction would block the approach")

func test_wall_replacement_requires_ownership_and_keeps_material_balance() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var v := View.new()
	for x in range(9, 12): v.chunk.set_cell("structure", x, 10, "base:wood_wall")
	v.chunk.set_props(10, 10, {"owner": "builder"})
	eq(BuildRules.check(v, content, "base:wood_door", "surface", 10, 10, "e", "builder"), "", "an owned wall is a valid conversion target")
	eq(BuildRules.check(v, content, "base:wood_door", "surface", 10, 10, "e", "other"), "not_owner", "a door cannot breach another owner's wall")
	var cost := BuildRules.placement_cost(v, content, "base:wood_door", "surface", 10, 10)
	var wall := content.structure_cost("base:wood_wall")
	var door := content.structure_cost("base:wood_door")
	for id: String in cost: eq(int(wall.get(id, 0)) + int(cost[id]), int(door.get(id, 0)), "one wall plus the conversion balance equals exactly one door")
	v.chunk.set_cell("structure", 11, 10, "")
	eq(BuildRules.check(v, content, "base:wood_door", "surface", 10, 10, "n", "builder"), "", "a two-block straight wall also has an unambiguous axis")
