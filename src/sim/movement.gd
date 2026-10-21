class_name Movement
## Walking on a location's grid, shared by the server (authority) and the
## client (prediction). Positions are integers in 1/UNIT of a cell, so both
## sides compute exactly the same result from the same inputs.
## The collider is a box at the feet, half its size each way from the
## position: a man's (HALF_X by HALF_Y) unless a body says otherwise (BodySize).

## A cell is UNIT units; UNIT is 1 << UNIT_SHIFT (cells by a shift, which
## floors for negative positions too).
const UNIT_SHIFT := 8
const UNIT := 1 << UNIT_SHIFT
const TICK_RATE := 20
## ≈ 4 cells per second; diagonals keep about the same speed.
const WALK := 51
const DIAGONAL := 36
## Running (Ctrl): 1.5 times as fast. A step stays shorter than a cell.
const RUN := 77
const RUN_DIAGONAL := 54
## Swimming (ADR-0050): half as fast as walking, never running.
const SWIM := 26
const SWIM_DIAGONAL := 18
const HALF_X := 80
const HALF_Y := 48


## One tick of movement in direction (dx, dy), each -1..1; run: 1.5 times as fast.
## solid: Callable(cell_x: int, cell_y: int) -> bool
## swim: in water, slowly.
static func step(pos: Vector2i, dx: int, dy: int, solid: Callable, run := false, half := Vector2i(HALF_X, HALF_Y), swim := false) -> Vector2i:
	var diagonal := dx != 0 and dy != 0
	var speed := (RUN_DIAGONAL if diagonal else RUN) if run else (DIAGONAL if diagonal else WALK)
	if swim:
		speed = SWIM_DIAGONAL if diagonal else SWIM
	pos = _axis(pos, dx * speed, true, solid, half)
	return _axis(pos, dy * speed, false, solid, half)


## A step at any speed (units a tick, less than a cell): creatures, which
## each go at their own pace; diagonals keep about the same speed.
static func step_at(pos: Vector2i, dx: int, dy: int, solid: Callable, speed: int, half := Vector2i(HALF_X, HALF_Y)) -> Vector2i:
	var s := int(round(speed * 0.7071)) if dx != 0 and dy != 0 else speed
	pos = _axis(pos, dx * s, true, solid, half)
	return _axis(pos, dy * s, false, solid, half)


static func cell_of(pos: Vector2i) -> Vector2i:
	return Vector2i(pos.x >> UNIT_SHIFT, pos.y >> UNIT_SHIFT)


## Moves along one axis; the leading edge stops at the first solid cell.
## A step is shorter than a cell, so only one new row or column can be entered.
static func _axis(pos: Vector2i, d: int, horizontal: bool, solid: Callable, half: Vector2i) -> Vector2i:
	if d == 0:
		return pos
	var np := pos
	if horizontal:
		np.x += d
		var col := _div(np.x + half.x - 1) if d > 0 else _div(np.x - half.x)
		for cy in range(_div(np.y - half.y), _div(np.y + half.y - 1) + 1):
			if solid.call(col, cy):
				np.x = col * UNIT - half.x if d > 0 else (col + 1) * UNIT + half.x
				break
	else:
		np.y += d
		var row := _div(np.y + half.y - 1) if d > 0 else _div(np.y - half.y)
		for cx in range(_div(np.x - half.x), _div(np.x + half.x - 1) + 1):
			if solid.call(cx, row):
				np.y = row * UNIT - half.y if d > 0 else (row + 1) * UNIT + half.y
				break
	return np


static func _div(v: int) -> int:
	return v >> UNIT_SHIFT
