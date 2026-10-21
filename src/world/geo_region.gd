class_name GeoRegion
extends RefCounted
## One region of the endless world (ADR-0049): SIZE coarse points across
## (a point a chunk), its own landmass — a continent, a few large islands or
## an archipelago — with the sea all along its borders, so the seas of
## neighbouring regions join into one ocean and each region drains on its own.
##
## Causes come one after another, each from the last:
## - relief: the land from slow noise, falling to a fixed sea depth at the
##   region's borders (so heights meet across them); mountain belts of
##   ridges on the land;
## - climate: warmth from latitude (bands across the whole world, cold and
##   warm by turns) and height; rain from a west wind that takes up water
##   over the sea and loses it over the land, most where the land rises (the
##   far side of a range is dry);
## - water: every point drains to the sea, or to a basin of its own in a dry
##   land; depressions fill into lakes; what drains through a point (its
##   rain upstream) makes rivers where there is enough of it.
## All of it is a function of the seed and the region's place: computed once
## (well under a second), shared read only.

## Coarse points across a region.
const SIZE := 160
## Height of the sea (heights run about -1..1) and of the sea at a border.
const SEA := 0.0
const BORDER_DEPTH := -0.45
## Points from a border within which the land falls away to the border depth.
const MARGIN := 10
## Points from the equator to a pole: warmth runs in bands across the world.
const LATITUDE := SIZE * 3
## Rain upstream a point needs to carry a river (in "points of average rain").
const RIVER_FLOW := 20.0
## Heights above which the land is hills, mountains, peaks.
const HILLS := 0.2
const MOUNTAINS := 0.45
const PEAKS := 0.68
## Fords (ADR-0051): on rivers this wide at most, on this share (%) of their
## stretches.
const FORD_WIDEST := 6.0
const FORD_SHARE := 22
## A depression this deep or deeper is a lake (shallower ones are drained).
const LAKE_DEPTH := 0.012

var world_seed := 0
## The region's place (regions across, down) and its first coarse point.
var place := Vector2i.ZERO
var first := Vector2i.ZERO
## What kind of land it holds: 0 open sea with islets .. 1 a large continent.
var landiness := 0.5
## Per point (index j * SIZE + i, local): height, its height with
## depressions filled (lakes' surfaces), warmth and rain (-1..1), the point
## it drains to (-1: the sea or a basin), what drains through it, its river's
## width in cells (0: none) and its course's bend (cells).
var height := PackedFloat32Array()
var filled := PackedFloat32Array()
var warmth := PackedFloat32Array()
var rain := PackedFloat32Array()
var down := PackedInt32Array()
var flow := PackedFloat32Array()
var river := PackedFloat32Array()
var bend := PackedVector2Array()
## Whether a point's stretch of river has a ford midway (1), ADR-0051.
var ford := PackedByteArray()


func _init(seed_value: int, at: Vector2i) -> void:
	world_seed = seed_value
	place = at
	first = at * SIZE
	# The region spawn is in always holds a good piece of land.
	landiness = 0.85 if at == Vector2i.ZERO else _roll("land")
	var cells := SIZE * SIZE
	height.resize(cells)  # each by name: packed arrays are values, a loop would resize copies
	filled.resize(cells)
	warmth.resize(cells)
	rain.resize(cells)
	flow.resize(cells)
	river.resize(cells)
	down.resize(cells)
	bend.resize(cells)
	ford.resize(cells)
	_relief()
	_climate()
	_drainage()
	_rivers()


# --- relief ------------------------------------------------------------------

func _noise(salt: int, freq: float, octaves: int) -> FastNoiseLite:
	var f := FastNoiseLite.new()
	f.seed = world_seed + salt
	f.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	f.frequency = freq
	f.fractal_octaves = octaves
	return f


## Points from the nearest border of a region (0 on it).
static func from_border(i: int, j: int) -> int:
	return mini(mini(i, SIZE - 1 - i), mini(j, SIZE - 1 - j))


func _relief() -> void:
	# Noise in the world's coarse points (continuous across regions); only the
	# land's share, where its heart is and the falling away to the borders are
	# the region's own.
	var continent := _noise(101, 2.6 / SIZE, 4)
	var shore := _noise(151, 6.0 / SIZE, 2)  # how far from the border the sea begins
	var belts := _noise(202, 4.0 / SIZE, 2)  # where mountain belts run
	var ridges := _noise(303, 12.0 / SIZE, 4)
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var hills := _noise(404, 20.0 / SIZE, 3)
	var lift := lerpf(-0.15, 0.32, landiness)
	var heart := Vector2(SIZE, SIZE) * 0.5 + Vector2(_roll("x") - 0.5, _roll("y") - 0.5) * SIZE * 0.3
	for j in SIZE:
		for i in SIZE:
			var gi := first.x + i
			var gj := first.y + j
			# Nothing at the border itself; inland, the sea's edge wanders.
			var e := float(from_border(i, j)) * (1.0 + 0.7 * shore.get_noise_2d(gi, gj))
			var inland := smoothstep(MARGIN * 0.4, MARGIN * 3.0, e)
			# The land gathers round the region's heart: round, not square.
			var off := Vector2(i, j).distance_to(heart) / (SIZE * 0.5)
			var base := continent.get_noise_2d(gi, gj) * 0.9 + lift - 0.35 * off * off
			var land := smoothstep(0.0, 0.25, base)
			# Mountain belts: where the belt noise passes near zero, ridges rise.
			var belt := 1.0 - smoothstep(0.0, 0.1, absf(belts.get_noise_2d(gi, gj)))
			var range_h := belt * land * (0.26 + 0.34 * ridges.get_noise_2d(gi, gj))
			var h := base * 0.45 + range_h + hills.get_noise_2d(gi, gj) * 0.06 * land
			height[j * SIZE + i] = lerpf(BORDER_DEPTH, h, inland)


## A number 0..1 of the region's own, by a name.
func _roll(salt: String) -> float:
	return float(absi(hash([world_seed, place.x, place.y, salt])) % 10007) / 10007.0


# --- climate --------------------------------------------------------------------

## Warmth by latitude at a coarse row of the world: bands, cold and warm by
## turns (-1 polar .. 1 tropical); the spawn region's middle is mild.
static func latitude_warmth(gj: float) -> float:
	var t := (gj - SIZE * 0.5) / LATITUDE + 0.6  # 0 pole .. 1 equator, 0.6 at spawn; south warmer
	var band := absf(fposmod(t + 1.0, 2.0) - 1.0)  # a triangle wave 0..1..0
	return lerpf(-0.95, 0.95, band)


func _climate() -> void:
	var wobble := _noise(505, 5.0 / SIZE, 2)
	var raw := PackedFloat32Array()
	raw.resize(SIZE * SIZE)
	for j in SIZE:
		var lat := latitude_warmth(first.y + j + 0.5)
		# The west wind brings water over the land from the sea.
		var water := 1.0
		var last := SEA
		for i in SIZE:
			var k := j * SIZE + i
			var h := height[k]
			if h < SEA:
				water = minf(1.0, water + 0.12)
				raw[k] = 0.06 * water
			else:
				var rise := maxf(0.0, h - last)
				var fall := clampf(water * (0.03 + 1.6 * rise), 0.0, water)
				water = minf(1.0, water - fall + 0.008)  # the land gives a little back
				raw[k] = fall
			last = maxf(h, SEA)
			# Colder up high.
			warmth[k] = clampf(lat + wobble.get_noise_2d(first.x + i, first.y + j) * 0.2 - 1.2 * maxf(0.0, h - 0.15), -1.0, 1.0)
	# Rain spreads a little round where it falls; then as -0.7..1 by its rank
	# over the land (so a region is never all desert nor all swamp, and is
	# mostly green).
	var smooth := _blur(_blur(raw))
	var land: Array = []
	for k in SIZE * SIZE:
		if height[k] >= SEA:
			land.append(smooth[k])
	land.sort()
	for k in SIZE * SIZE:
		var rank := land.bsearch(smooth[k]) / float(maxi(1, land.size()))
		rain[k] = clampf(rank * 1.7 - 0.7, -1.0, 1.0)


func _blur(a: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	for j in SIZE:
		for i in SIZE:
			var s := 0.0
			var w := 0.0
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := i + di
					var jj := j + dj
					if ii >= 0 and jj >= 0 and ii < SIZE and jj < SIZE:
						s += a[jj * SIZE + ii]
						w += 1.0
			out[j * SIZE + i] = s / w
	return out


# --- water ----------------------------------------------------------------------

const _N8 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]


## Every point drains (priority flood from the outlets): the sea, and the
## lowest points of dry land with no way out worth the name (basins of their
## own). A point is reached from the lowest edge of what is reached already:
## the one it was reached from is where it drains; a hollow is filled to its
## brim — a lake.
func _drainage() -> void:
	const LEVELS := 4096
	var n := SIZE
	var buckets: Array[Array] = []  # plain arrays: shared, not copied (packed ones are values)
	buckets.resize(LEVELS)
	for b in LEVELS:
		buckets[b] = []
	var lo := -1.5
	var hi := 2.0
	var bucket := func(h: float) -> int: return clampi(int((h - lo) / (hi - lo) * LEVELS), 0, LEVELS - 1)
	var seen := PackedByteArray()
	seen.resize(n * n)
	for k in n * n:
		down[k] = -1
	for j in n:
		for i in n:
			var k := j * n + i
			var outlet := height[k] < SEA
			if not outlet and rain[k] < -0.6 and _lowest_round(i, j):
				outlet = true  # a dry hollow: a basin of its own (a salt lake, a dry bed)
			if outlet:
				filled[k] = height[k]
				seen[k] = 1
				buckets[bucket.call(height[k])].append(k)
	var order := PackedInt32Array()
	order.resize(n * n)
	var done := 0
	var b := 0
	var at := PackedInt32Array()
	at.resize(LEVELS)
	while b < LEVELS:
		var list: Array = buckets[b]
		if at[b] >= list.size():
			b += 1
			continue
		var k: int = list[at[b]]
		at[b] += 1
		order[done] = k
		done += 1
		var i := k % n
		var j := k / n
		for d: Vector2i in _N8:
			var ii := i + d.x
			var jj := j + d.y
			if ii < 0 or jj < 0 or ii >= n or jj >= n:
				continue
			var m := jj * n + ii
			if seen[m]:
				continue
			seen[m] = 1
			filled[m] = maxf(height[m], filled[k] + 0.00002)
			down[m] = k
			var nb: int = bucket.call(filled[m])
			buckets[nb].append(m)
			if nb < b:
				b = nb
	# What drains through a point: its rain (as water, 0..2) and all upstream.
	for k in n * n:
		flow[k] = (rain[k] + 1.0) if height[k] >= SEA else 0.0
	for x in range(done - 1, -1, -1):
		var k := order[x]
		if down[k] >= 0:
			flow[down[k]] += flow[k]


func _lowest_round(i: int, j: int) -> bool:
	var h := height[j * SIZE + i]
	for d: Vector2i in _N8:
		var ii := i + d.x
		var jj := j + d.y
		if ii >= 0 and jj >= 0 and ii < SIZE and jj < SIZE and height[jj * SIZE + ii] < h:
			return false
	return true


## Rivers: where enough water drains through dry land; wider downstream.
## Their course bends round each point by a little, so they do not follow
## the grid.
func _rivers() -> void:
	var wander := _noise(606, 0.5, 1)
	for k in SIZE * SIZE:
		var dry := height[k] >= SEA and not is_lake(k)
		river[k] = clampf(1.5 + sqrt(flow[k] - RIVER_FLOW) * 0.55, 1.5, 9.0) if dry and flow[k] >= RIVER_FLOW else 0.0
		var g := first + Vector2i(k % SIZE, k / SIZE)
		# Fords: on rivers not too wide, now and then.
		ford[k] = 1 if river[k] > 0.0 and river[k] <= FORD_WIDEST and absi(hash([world_seed, g.x, g.y, "ford"])) % 100 < FORD_SHARE else 0
		bend[k] = Vector2(wander.get_noise_2d(g.x * 7.0, g.y * 7.0), wander.get_noise_2d(g.y * 7.0 + 1000.0, g.x * 7.0)) * Chunk.SIZE * 0.3


## Whether a point is under a lake: a hollow deep enough (in a shallower
## one the water runs on over the brim).
func is_lake(k: int) -> bool:
	return filled[k] - height[k] >= LAKE_DEPTH and filled[k] >= SEA


## How much of the region is dry land (0..1).
func land_share() -> float:
	var dry := 0
	for k in SIZE * SIZE:
		if height[k] >= SEA:
			dry += 1
	return dry / float(SIZE * SIZE)
