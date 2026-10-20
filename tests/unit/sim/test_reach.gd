extends TestCase
## A pick reaches the first solid cell toward the aim, within three cells.

func _solid(cells: Array) -> Callable:
	return func(x: int, y: int) -> bool: return cells.has(Vector2i(x, y))


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func test_the_first_solid_toward_the_aim() -> void:
	var me := _at(Vector2i(10, 10))
	var far := Vector2(_at(Vector2i(20, 10)))
	eq(Reach.first_solid(me, far, _solid([Vector2i(12, 10), Vector2i(13, 10)])), Vector2i(12, 10), "the nearer of two")
	eq(Reach.first_solid(me, far, _solid([Vector2i(13, 10)])), Vector2i(13, 10), "three cells: in reach")
	eq(Reach.first_solid(me, far, _solid([Vector2i(14, 10)])), Reach.NONE, "four: not")
	eq(Reach.first_solid(me, Vector2(_at(Vector2i(10, 4))), _solid([Vector2i(12, 10), Vector2i(10, 8)])), Vector2i(10, 8),
		"only along the line toward the aim")
	eq(Reach.first_solid(me, Vector2(_at(Vector2i(13, 13))), _solid([Vector2i(12, 12)])), Vector2i(12, 12), "diagonally too")
	eq(Reach.first_solid(me, Vector2(me), _solid([Vector2i(11, 10)])), Reach.NONE, "no direction, nothing")
	eq(Reach.first_solid(me, far, _solid([Vector2i(10, 10)])), Reach.NONE, "not the cell one stands on")
