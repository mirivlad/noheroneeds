class_name Sight
## Who can see whom on the plan and across levels (ADR-0015): no 3D
## ballistics, only the heights of what stands in the way. A line goes from
## the eyes of one (its level + EYE) to the body of the other (its level +
## BODY) over the cells between them, its height changing evenly; each cell
## holds spans of height that block it:
##   a wall, a closed door, a window on level z — z .. z + height (1);
##   a solid plant on the surface — 0 .. its height (a bush 0.7, a tree 2);
##   a ceiling of level z — a slab just under the floor of z + 1;
##   a roof over level z — z + 1 .. z + 1 + ROOF.
## So from a walkway on a wall one sees over the yard's fence, from a closed
## room upstairs one sees nothing, and one in the street sees the man on the
## walkway, but not the one inside.
## A window or a loophole lets a line through only for one standing at it,
## inside (the cell behind it), and the other in its sector and range (the
## part's "opening", where its facing looks).
## Locations that share the plan (the surface and the levels of buildings)
## see each other; others (underground, ADR-0017) only themselves.

const EYE := 0.75
const BODY := 0.5
## A ceiling: a slab this thick under the floor above.
const SLAB := 0.1
## A roof rises this far above the level it covers.
const ROOF := 0.5


## Whether two locations are on one plan, so their people may see each other.
static func same_space(world: ServerWorld, a: String, b: String) -> bool:
	return a == b or (_on_plan(world, a) and _on_plan(world, b))


static func _on_plan(world: ServerWorld, location: String) -> bool:
	return location == Levels.SURFACE or world.levels.kind(location) == Levels.BUILDING_LEVEL


## Whether the eyes at cell `a` of location `la` see the cell `b` of `lb`
## (nothing in the way; how far and how light is Perception's business).
static func clear(world: ServerWorld, la: String, a: Vector2i, lb: String, b: Vector2i) -> bool:
	if la != lb and not same_space(world, la, lb):
		return false
	var ha := world.levels.z(la) + EYE
	var hb := world.levels.z(lb) + BODY
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var n := maxi(dx, -dy)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var p := a
	var i := 0
	while p != b:
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			p.x += sx
		if e2 <= dx:
			err += dx
			p.y += sy
		i += 1
		if p == b:
			break
		# The line's heights over this cell: from half a step before to half after.
		var h0 := lerpf(ha, hb, (i - 0.5) / n)
		var h1 := lerpf(ha, hb, (i + 0.5) / n)
		if _blocked(world, p, minf(h0, h1), maxf(h0, h1), la, a, lb, b):
			return false
	return true


## Whether something in the column of cell `p` spans heights lo..hi.
static func _blocked(world: ServerWorld, p: Vector2i, lo: float, hi: float,
		la: String, a: Vector2i, lb: String, b: Vector2i) -> bool:
	var lx := p.x & 31  # Chunk.SIZE is 32
	var ly := p.y & 31
	var c := world.chunk(Levels.SURFACE, p.x >> 5, p.y >> 5)
	if _part_blocks(world, c, lx, ly, 0, lo, hi, Levels.SURFACE, p, la, a, lb, b):
		return true
	if hi < 1.0 - SLAB:
		return false  # a low line: only what stands on the ground matters
	if c.get_cell("roof", lx, ly) != "" and _spans(lo, hi, 1.0, 1.0 + ROOF):
		return true
	if c.get_cell("ceiling", lx, ly) == "":
		return false
	if _spans(lo, hi, 1.0 - SLAB, 1.0):
		return true
	var building := String((c.get_props(lx, ly).get("ceiling", {}) as Dictionary).get("building", ""))
	var z := 1
	while hi >= z:
		var loc := world.levels.level(building, z)
		if loc == "":
			break
		var lc := world.chunk(loc, p.x >> 5, p.y >> 5)
		if _part_blocks(world, lc, lx, ly, z, lo, hi, loc, p, la, a, lb, b):
			return true
		if lc.get_cell("roof", lx, ly) != "" and _spans(lo, hi, z + 1.0, z + 1.0 + ROOF):
			return true
		if lc.get_cell("ceiling", lx, ly) == "":
			break
		if _spans(lo, hi, z + 1.0 - SLAB, z + 1.0):
			return true
		z += 1
	return false


## What stands on a cell of level z, if it blocks sight and reaches lo..hi,
## unless it is an opening the line may pass.
static func _part_blocks(world: ServerWorld, c: Chunk, lx: int, ly: int, z: int, lo: float, hi: float,
		loc: String, p: Vector2i, la: String, a: Vector2i, lb: String, b: Vector2i) -> bool:
	if lo > z + 4.0 or not Terrain.is_opaque(c, lx, ly, world.content):
		return false
	var part := c.get_cell("structure", lx, ly)
	var d := world.content.get_def(part if part != "" else c.get_cell("cover", lx, ly))
	if not _spans(lo, hi, z, z + float(d.get("height", 1.0))):
		return false
	if d.has("opening"):
		var facing := String(c.get_props(lx, ly).get("facing", ""))
		if _through(d["opening"], facing, loc, p, la, a, lb, b):
			return false
	return true


## Through an opening at cell w of `loc`, facing `facing`: one end stands at
## it inside (the cell behind it, same level), the other is in its sector and
## within its range.
static func _through(o: Dictionary, facing: String, loc: String, w: Vector2i,
		la: String, a: Vector2i, lb: String, b: Vector2i) -> bool:
	var out: Vector2i = ContentRegistry.FACINGS.get(facing, Vector2i.ZERO)
	if out == Vector2i.ZERO:
		return false
	var inner := w - out
	var other: Vector2i
	if la == loc and a == inner:
		other = b
	elif lb == loc and b == inner:
		other = a
	else:
		return false
	var v := Vector2(other - w)
	var d := v.length()
	if d == 0.0 or d > float(o["range"]):
		return false
	return v.dot(Vector2(out)) / d >= cos(deg_to_rad(float(o["sector"]) / 2.0))


## Whether heights lo..hi meet bottom..top.
static func _spans(lo: float, hi: float, bottom: float, top: float) -> bool:
	return lo <= top and hi >= bottom
