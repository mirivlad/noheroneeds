class_name PlanetTopology
extends RefCounted
## How one finite world names places (the global plan).
##
## A continent is a flat map: its ocean goes on in every direction and
## nothing folds. A planet is closed: longitude wraps at the seam, and the
## rows beyond a pole are the rows of the far side, their order reversed and
## longitude turned half a world — the rule WorldPlan.value already uses to
## read its fields.
##
## Movement coordinates stay continuous (a covering space of the planet), so
## walking across the seam never jumps on the screen. Three things do fold:
##
##   * chunk identity and storage: every name of a chunk has one canonical
##     name, so a change made at "x = -1" is the change at "x = width - 1";
##   * distances and reaches: the short way round the seam;
##   * the rows of a chunk past a pole, which run the other way round
##     (ReflectedChunk tells such a chunk as players see it).
##
## So `canonical_chunk(c) == canonical_chunk(c + a whole world)`, one place
## never becomes two, and no reach or sight is measured through the poles.

var plan: WorldPlan


func _init(source: WorldPlan = null) -> void:
	plan = source


## Whether places fold at all (a planet; false for a flat continent).
func wraps() -> bool:
	return plan != null and plan.preset != "single_continent"


## Cells from one edge of a planet to the other.
func cells_across() -> int:
	return plan.size.x * Chunk.SIZE if wraps() else 0


## The canonical name of a chunk. A continent's chunks are their own names.
func canonical_chunk(at: Vector2i) -> Vector2i:
	return plan.canonical_point(at, 1) if wraps() else at


## Whether a chunk's rows lie past a pole of its canonical chunk: they run
## the other way round, as WorldPlan.value reads them.
func mirrored_chunk(at: Vector2i) -> bool:
	if not wraps():
		return false
	return posmod(at.y + plan.spawn.y, plan.size.y * 2) >= plan.size.y


## The canonical name of a cell: its chunk is folded, and the cell lies the
## same way inside the chunk on either side.
func canonical_cell(cell: Vector2i) -> Vector2i:
	if not wraps():
		return cell
	return plan.canonical_point(cell, Chunk.SIZE)


## The canonical name of the chunk a cell falls in.
func chunk_of_cell(cell: Vector2i) -> Vector2i:
	return canonical_chunk(Vector2i(floori(float(cell.x) / Chunk.SIZE), floori(float(cell.y) / Chunk.SIZE)))


## The shortest way from `a` to `b` in movement units, across the seam.
## Nothing folds at a pole: it is the end of the world, not a shortcut.
func delta(a: Vector2i, b: Vector2i) -> Vector2i:
	var d := b - a
	if not wraps():
		return d
	var width := cells_across() * Movement.UNIT
	if d.x > width / 2:
		d.x -= width
	elif d.x < -width / 2:
		d.x += width
	return d


## How far apart two positions are, the short way round the seam.
func distance(a: Vector2i, b: Vector2i) -> float:
	return Vector2(delta(a, b)).length()


## The shortest way from cell `a` to cell `b`, across the seam.
func cell_delta(a: Vector2i, b: Vector2i) -> Vector2i:
	var d := b - a
	if not wraps():
		return d
	var width := cells_across()
	if d.x > width / 2:
		d.x -= width
	elif d.x < -width / 2:
		d.x += width
	return d


## How far apart two cells are, the short way.
func cell_distance(a: Vector2i, b: Vector2i) -> float:
	return Vector2(cell_delta(a, b)).length()


## The same place as `pos`, named on the side of the seam `around` is on:
## what is near stays near when both are compared or drawn (movement units).
func nearest(pos: Vector2i, around: Vector2i) -> Vector2i:
	return around + delta(around, pos)


## The same place as cell `cell`, named on the side of the seam `around` is on.
func nearest_cell(cell: Vector2i, around: Vector2i) -> Vector2i:
	return around + cell_delta(around, cell)
