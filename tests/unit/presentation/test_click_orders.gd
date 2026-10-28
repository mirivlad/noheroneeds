extends TestCase
## Playing by the mouse as in RO: a way round what is in the way, no corner
## cut, walked cell by cell; an order on a target stops in reach of it.

## A wall x = 3 from y = -3 to 3: one goes round it.
func _solid(x: int, y: int) -> bool:
	return x == 3 and y >= -3 and y <= 3


func test_a_way_round_a_wall() -> void:
	var way := ClickOrders.find(Vector2i.ZERO, func(c: Vector2i) -> bool: return c == Vector2i(6, 0), Vector2i(6, 0), _solid)
	check(not way.is_empty() and way[-1] == Vector2i(6, 0), "it gets there: %s" % str(way))
	check(way.all(func(c: Vector2i) -> bool: return not _solid(c.x, c.y)), "never through the wall")
	var prev := Vector2i.ZERO
	for c: Vector2i in way:
		var d := c - prev
		check(maxi(absi(d.x), absi(d.y)) == 1, "a cell at a time")
		if d.x != 0 and d.y != 0:
			check(not _solid(prev.x + d.x, prev.y) and not _solid(prev.x, prev.y + d.y), "no corner cut at %s" % c)
		prev = c
	var shut := func(x: int, y: int) -> bool: return absi(x) == 2 or absi(y) == 2
	eq(ClickOrders.find(Vector2i.ZERO, func(c: Vector2i) -> bool: return c == Vector2i(5, 5), Vector2i(5, 5), shut), [] as Array[Vector2i],
		"walled in: no way")


func test_walking_and_stopping_in_reach() -> void:
	var o := ClickOrders.new()
	var at := Vector2i(128, 128)  # the middle of cell 0,0
	o.walk_to(Vector2i(6, 0), Vector2i.ZERO, _solid)
	check(o.active() and not o.acting(), "walking")
	var moves := 0
	while o.active() and moves < 2000:
		var m := o.step(at, _solid, 0.05)
		at += m * 24
		moves += 1
	eq(Movement.cell_of(at), Vector2i(6, 0), "walked there, round the wall")
	var deer := Vector2(9.5, 0.5) * Movement.UNIT
	o.act_on({"kind": "entity", "id": "d"}, {"id": "strike"}, 1.2, true, Movement.cell_of(at), _solid, deer)
	moves = 0
	while not o.in_reach(at, deer) and moves < 2000:
		at += o.step(at, _solid, 0.05, deer) * 24
		moves += 1
	check(o.in_reach(at, deer), "walked up to the deer")
	eq(o.step(at, _solid, 0.05, deer), Vector2i.ZERO, "and stands there to strike")
	check(o.acting(), "still on it (strikes again till it falls)")
	o.clear()
	check(not o.active(), "another order ends it")
