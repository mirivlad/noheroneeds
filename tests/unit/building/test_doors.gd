extends TestCase
## A door shows only in a wall that runs across the screen: not in a side
## one, and no wall is put above or below a door.

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


func test_doors_only_in_walls_across() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	var v := View.new()
	for y in range(2, 7):
		v.chunk.set_cell("structure", 3, y, "base:wood_wall")  # a side wall, top to bottom
	v.chunk.set_cell("structure", 10, 5, "base:wood_wall")
	v.chunk.set_cell("structure", 12, 5, "base:wood_wall")  # a wall across, a gap in it
	v.chunk.set_cell("structure", 3, 4, "")
	eq(_check(v, content, "base:wood_door", 3, 4), "side_wall", "not into a side wall")
	eq(_check(v, content, "base:wood_door", 11, 5), "", "into a wall across")
	eq(_check(v, content, "base:wood_gate", 3, 4), "side_wall", "nor a gate")
	eq(_check(v, content, "base:wood_window", 3, 4), "", "a window turns to the side")
	v.chunk.set_cell("structure", 11, 5, "base:wood_door")
	eq(_check(v, content, "base:wood_wall", 11, 4), "door_beside", "no wall above a door")
	eq(_check(v, content, "base:wood_wall", 11, 6), "door_beside", "nor below")
	eq(_check(v, content, "base:wood_wall", 13, 5), "", "beside it along the wall")
