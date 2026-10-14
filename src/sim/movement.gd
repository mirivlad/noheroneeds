class_name Movement
## Walking on a location's grid, shared by the server (authority) and the
## client (prediction). Positions are integers in 1/UNIT of a cell, so both
## sides compute exactly the same result from the same inputs.
## The collider is a box at the feet, HALF_X by HALF_Y from the position.

const UNIT := 256
const TICK_RATE := 20
## ≈ 4 cells per second; diagonals keep about the same speed.
const WALK := 51
const DIAGONAL := 36
## Running (Ctrl): 1.5 times as fast. A step stays shorter than a cell.
const RUN := 77
const RUN_DIAGONAL := 54
const HALF_X := 80
const HALF_Y := 48


## One tick of movement in direction (dx, dy), each -1..1; run: 1.5 times as fast.
## solid: Callable(cell_x: int, cell_y: int) -> bool
static func step(pos: Vector2i, dx: int, dy: int, solid: Callable, run := false) -> Vector2i:
	var diagonal := dx != 0 and dy != 0
	var speed := (RUN_DIAGONAL if diagonal else RUN) if run else (DIAGONAL if diagonal else WALK)
	pos = _axis(pos, dx * speed, true, solid)
	return _axis(pos, dy * speed, false, solid)


## A step at any speed (units a tick, less than a cell): creatures, which
## each go at their own pace; diagonals keep about the same speed.
static func step_at(pos: Vector2i, dx: int, dy: int, solid: Callable, speed: int) -> Vector2i:
	var s := int(round(speed * 0.7071)) if dx != 0 and dy != 0 else speed
	pos = _axis(pos, dx * s, true, solid)
	return _axis(pos, dy * s, false, solid)


static func cell_of(pos: Vector2i) -> Vector2i:
	return Vector2i(_div(pos.x), _div(pos.y))


## Moves along one axis; the leading edge stops at the first solid cell.
## A step is shorter than a cell, so only one new row or column can be entered.
static func _axis(pos: Vector2i, d: int, horizontal: bool, solid: Callable) -> Vector2i:
	if d == 0:
		return pos
	var np := pos
	if horizontal:
		np.x += d
		var col := _div(np.x + HALF_X - 1) if d > 0 else _div(np.x - HALF_X)
		for cy in range(_div(np.y - HALF_Y), _div(np.y + HALF_Y - 1) + 1):
			if solid.call(col, cy):
				np.x = col * UNIT - HALF_X if d > 0 else (col + 1) * UNIT + HALF_X
				break
	else:
		np.y += d
		var row := _div(np.y + HALF_Y - 1) if d > 0 else _div(np.y - HALF_Y)
		for cx in range(_div(np.x - HALF_X), _div(np.x + HALF_X - 1) + 1):
			if solid.call(cx, row):
				np.y = row * UNIT - HALF_Y if d > 0 else (row + 1) * UNIT + HALF_Y
				break
	return np


static func _div(v: int) -> int:
	return floori(float(v) / UNIT)
