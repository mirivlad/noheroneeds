class_name Geography
extends RefCounted
## The world's geography (ADR-0049): endless, made of regions (GeoRegion),
## each a landmass of its own in the one ocean, worked out the first time
## anything in it is asked about and kept for the process (the regions are
## shared by every generator of a seed, read only). Spawn is somewhere good
## in region (0, 0), at world (0, 0).
##
## Coarse points stand a chunk each; "geo" coordinates are world cells
## shifted so that region (0, 0) begins at geo (0, 0).

## Cells a coarse point stands for (a chunk), cells a region is across.
const STEP := Chunk.SIZE
const REGION_CELLS := GeoRegion.SIZE * STEP
const SEA := GeoRegion.SEA
const HILLS := GeoRegion.HILLS
const MOUNTAINS := GeoRegion.MOUNTAINS
const PEAKS := GeoRegion.PEAKS
## Regions a process keeps (each is some 1 MB).
const KEEP := 24

var world_seed := 0
## Where world (0, 0) is in geo cells (geo = world + origin).
var origin := Vector2i.ZERO
## This view's own regions, by place (no lock needed to read them).
var _mine := {}
var _last_place := Vector2i(1 << 30, 0)
var _last: GeoRegion

static var _shared := {}
static var _origins := {}
static var _lock := Mutex.new()


## The geography of a seed (a view of its shared regions; one a thread).
static func of(seed_value: int) -> Geography:
	var g := Geography.new()
	g.world_seed = seed_value
	_lock.lock()
	var o: Variant = _origins.get(seed_value)
	_lock.unlock()
	if o == null:
		o = _spawn_point(g.region(Vector2i.ZERO))
		_lock.lock()
		_origins[seed_value] = o
		_lock.unlock()
	g.origin = o
	return g


## A region, by its place (regions across, down).
func region(at: Vector2i) -> GeoRegion:
	if at == _last_place:
		return _last
	var r: GeoRegion = _mine.get(at)
	if r == null:
		var key := "%d|%d|%d" % [world_seed, at.x, at.y]
		_lock.lock()
		r = _shared.get(key)
		if r == null:
			r = GeoRegion.new(world_seed, at)
			if _shared.size() >= KEEP:
				_shared.erase(_shared.keys()[0])  # the oldest
			_shared[key] = r
		_lock.unlock()
		if _mine.size() >= KEEP:
			_mine.clear()
		_mine[at] = r
	_last_place = at
	_last = r
	return r


## The region a world cell is in.
func region_at(x: int, y: int) -> GeoRegion:
	return region(Vector2i(floori(float(x + origin.x) / REGION_CELLS), floori(float(y + origin.y) / REGION_CELLS)))


## Where spawn is: dry, low, mild land with rain enough, near a river if
## possible, not far from the region's middle.
static func _spawn_point(r: GeoRegion) -> Vector2i:
	var n := GeoRegion.SIZE
	var best := Vector2i(n / 2, n / 2)
	var best_score := -INF
	for j in range(n / 5, n * 4 / 5):
		for i in range(n / 5, n * 4 / 5):
			var k := j * n + i
			var h := r.height[k]
			if h < SEA + 0.03 or h > HILLS or r.is_lake(k) or r.river[k] > 0.0:
				continue
			var near_river := 0.0
			for d: Vector2i in GeoRegion._N8:
				var m := (j + d.y) * n + (i + d.x)
				near_river = maxf(near_river, 1.0 if r.river[m] > 0.0 else 0.0)
			var score := -absf(r.warmth[k] - 0.15) * 2.0 - absf(r.rain[k] - 0.1) + near_river * 0.8 \
				- Vector2(i - n / 2, j - n / 2).length() / n * 2.0
			if score > best_score:
				best_score = score
				best = Vector2i(i, j)
	# World (0, 0) is in the middle of that point's chunk.
	return best * STEP + Vector2i(STEP / 2, STEP / 2)


# --- sampling (cells) -------------------------------------------------------------

const HEIGHT := 0
const WARMTH := 1
const RAIN := 2


## A field's value at a coarse point of the world (geo points).
func point_value(field: int, gi: int, gj: int) -> float:
	var r := region(Vector2i(floori(float(gi) / GeoRegion.SIZE), floori(float(gj) / GeoRegion.SIZE)))
	var k := (gj - r.first.y) * GeoRegion.SIZE + (gi - r.first.x)
	match field:
		HEIGHT:
			return r.height[k]
		WARMTH:
			return r.warmth[k]
		_:
			return r.rain[k]


## A field between the coarse points (bilinear), at a world cell: HEIGHT,
## WARMTH or RAIN.
func sample(field: int, x: int, y: int) -> float:
	var px := float(x + origin.x) / STEP - 0.5
	var py := float(y + origin.y) / STEP - 0.5
	var i := floori(px)
	var j := floori(py)
	var at := _block_at(i, j) + field * 9
	var fx := px - i
	var fy := py - j
	var a := lerpf(_block[at], _block[at + 1], fx)
	var b := lerpf(_block[at + 3], _block[at + 4], fx)
	return lerpf(a, b, fy)


## Warmth and rain together at a world cell (one look-up for both).
func climate_at(x: int, y: int) -> Vector2:
	var px := float(x + origin.x) / STEP - 0.5
	var py := float(y + origin.y) / STEP - 0.5
	var i := floori(px)
	var j := floori(py)
	var at := _block_at(i, j) + 9
	var fx := px - i
	var fy := py - j
	var w := lerpf(lerpf(_block[at], _block[at + 1], fx), lerpf(_block[at + 3], _block[at + 4], fx), fy)
	at += 9
	var r := lerpf(lerpf(_block[at], _block[at + 1], fx), lerpf(_block[at + 3], _block[at + 4], fx), fy)
	return Vector2(w, r)


## The values of the 3 x 3 coarse points from the last asked-about one: all
## the cells of a chunk sample within them (a cell's points are its chunk's
## and the ones before), so a chunk's cells look them up once, not each.
## Per field (HEIGHT, WARMTH, RAIN, then lake levels or -INF) nine values.
var _block := PackedFloat32Array()
var _block_from := Vector2i(1 << 30, 0)


## Where in _block the point (i, j) and the three after it are (field 0).
func _block_at(i: int, j: int) -> int:
	var d := Vector2i(i, j) - _block_from
	if d.x < 0 or d.y < 0 or d.x > 1 or d.y > 1:
		_block_from = Vector2i(i, j)
		_block.resize(36)
		for dj in 3:
			for di in 3:
				var gi := i + di
				var gj := j + dj
				var r := region(Vector2i(floori(float(gi) / GeoRegion.SIZE), floori(float(gj) / GeoRegion.SIZE)))
				var k := (gj - r.first.y) * GeoRegion.SIZE + (gi - r.first.x)
				var at := dj * 3 + di
				_block[at] = r.height[k]
				_block[9 + at] = r.warmth[k]
				_block[18 + at] = r.rain[k]
				_block[27 + at] = r.filled[k] if r.is_lake(k) else -INF
		d = Vector2i.ZERO
	return d.y * 3 + d.x


## The middle of a coarse point's course in world cells (bent).
func course_point(r: GeoRegion, k: int) -> Vector2:
	var g := r.first + Vector2i(k % GeoRegion.SIZE, k / GeoRegion.SIZE)
	return Vector2(g * STEP + Vector2i(STEP / 2, STEP / 2) - origin) + r.bend[k]


## River segments ([from, to, width there, width here, a ford midway]) that may pass near a
## chunk's cells. Rivers never reach a region's border (the sea is there), so
## only the chunk's own region has any.
func rivers_near(cx: int, cy: int) -> Array:
	var out: Array = []
	var mid := Vector2i(cx * Chunk.SIZE + Chunk.SIZE / 2, cy * Chunk.SIZE + Chunk.SIZE / 2) + origin
	var r := region(Vector2i(floori(float(mid.x) / REGION_CELLS), floori(float(mid.y) / REGION_CELLS)))
	var ci := floori(float(mid.x) / STEP) - r.first.x
	var cj := floori(float(mid.y) / STEP) - r.first.y
	for dj in range(-2, 3):
		for di in range(-2, 3):
			var i := ci + di
			var j := cj + dj
			if i < 0 or j < 0 or i >= GeoRegion.SIZE or j >= GeoRegion.SIZE:
				continue
			var k := j * GeoRegion.SIZE + i
			if r.river[k] <= 0.0 or r.down[k] < 0:
				continue
			var to := r.down[k]
			# It runs on into the sea or a lake: to the middle of that point.
			out.append([course_point(r, k), course_point(r, to), r.river[k], r.river[to] if r.river[to] > 0.0 else r.river[k], r.ford[k] == 1])
	return out


## The lake surface over a world cell's point (or -INF: none near).
func lake_level_at(x: int, y: int) -> float:
	var at := _block_at(floori(float(x + origin.x) / STEP - 0.5), floori(float(y + origin.y) / STEP - 0.5)) + 27
	return maxf(maxf(_block[at], _block[at + 1]), maxf(_block[at + 3], _block[at + 4]))
