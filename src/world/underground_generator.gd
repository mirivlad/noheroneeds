class_name UndergroundGenerator
extends RefCounted
## Makes chunks of the underground (ADR-0017): one geology for the whole
## world, a function of the world seed, the depth and the cell, so chunks
## made in any order, from any way in, fit each other, and a deposit runs on
## into the next chunk and the next depth. Made once, then stored whole: a new
## VERSION shapes only what nobody has reached.
##
## Everything is content (the generator "base:underground" and "deposit"
## definitions): the rock, the floor under it, how much of the rock is
## caves, the deposits (which rock part, at what depths, veins or single
## finds, how rare). The code only samples noise.
##
## Ways between depths are a function too (entrance_at): where the surface
## has a cave mouth, the depth below has a hollow with a way up; where a
## cave drops to the next depth, that depth has a hollow and a way up.

const ID := "base:underground"
const VERSION := 2  # 2: ways in caves at both ends, a tunnel where they would be walled in
## Places tried for a way in a chunk before one is taken where it falls.
const WAY_TRIES := 24
## A chunk holds at most one natural way down to the next depth.
const NONE := Vector2i(1 << 30, 1 << 30)

var world_seed := 0
var _floor := ""
var _rock := ""
var _water := ""
var _cave_threshold := 0.3
var _water_threshold := 0.6
var _entrance_chance := 0.0
var _hollow := 3
## Parts that stand at the ends of natural ways: the way down (at the upper
## depth or the surface) and the way up (at the lower one).
var way_down_surface := ""
var way_down := ""
var way_up := ""
## [{rock, top, bottom, single, threshold, noise, area, presence, relief}],
## in content id order.
var _deposits: Array = []
## The land above (ADR-0053): deposits are richer or poorer by its height.
## Set by the server to the surface generator's (null: a flat world, all as
## they are).
var geography: Geography
var _caves := FastNoiseLite.new()
## Winding passages joining the chambers: a thin ridge of another noise.
var _passages := FastNoiseLite.new()
var _passage_width := 0.05
var _pools := FastNoiseLite.new()
## Cells that must be ways down besides the random ones (a world's entrance
## near its spawn point): "z|x|y" -> true (z: the depth the way leads to).
var extra_ways := {}


func _init(seed_value: int, content: ContentRegistry) -> void:
	world_seed = seed_value
	var g := content.get_def(ID)
	if g.get("kind") != "generator":
		return
	_floor = String(g["floor"])
	_rock = String(g["rock"])
	_water = String(g.get("water", ""))
	_cave_threshold = float(g.get("cave_threshold", 0.3))
	_water_threshold = float(g.get("water_threshold", 0.6))
	_entrance_chance = float(g.get("entrance_chance", 0.0))
	_hollow = int(g.get("hollow", 3))
	way_down_surface = String(g.get("way_down_surface", ""))
	way_down = String(g.get("way_down", ""))
	way_up = String(g.get("way_up", ""))
	_caves.seed = seed_value + 31337
	_caves.frequency = float(g.get("cave_frequency", 0.06))
	_caves.fractal_octaves = 2
	_passages.seed = seed_value + 4241
	_passages.frequency = float(g.get("passage_frequency", 0.025))
	_passages.fractal_octaves = 1
	_passage_width = float(g.get("passage_width", 0.05))
	_pools.seed = seed_value + 271
	_pools.frequency = 0.09
	var ids: Array = []
	for id: String in content.defs:
		if content.kind_of(id) == "deposit":
			ids.append(id)
	ids.sort()
	for i in ids.size():
		var d := content.get_def(ids[i])
		var n := FastNoiseLite.new()
		n.seed = seed_value + 7907 * (i + 3)
		n.frequency = float(d.get("frequency", 0.08))
		n.fractal_octaves = 1
		# Where a vein may run at all: wide areas of a slower noise.
		var area := FastNoiseLite.new()
		area.seed = seed_value + 6203 * (i + 5)
		area.frequency = n.frequency / 4.0
		_deposits.append({"rock": String(d["rock"]), "top": int(d["depths"][0]), "bottom": int(d["depths"][1]),
			"single": String(d.get("shape", "vein")) == "single", "threshold": float(d["threshold"]), "noise": n,
			"area": area, "presence": float(d.get("presence", 0.3)), "relief": d.get("relief", [1.0, 1.0, 1.0])})


func can_generate() -> bool:
	return _floor != "" and _rock != ""


## The natural way down in chunk (cx, cy) leading to depth `z` (from z + 1,
## the surface when z is -1), as a world cell; NONE if there is none.
func entrance_at(z: int, cx: int, cy: int) -> Vector2i:
	for key: String in extra_ways:
		var p := key.split("|")
		if int(p[0]) == z and floori(float(p[1]) / Chunk.SIZE) == cx and floori(float(p[2]) / Chunk.SIZE) == cy:
			return Vector2i(int(p[1]), int(p[2]))
	if _hash3(cx, cy, z, 11) >= _entrance_chance:
		return NONE
	var key := Vector3i(cx, cy, z)
	if _ways.has(key):
		return _ways[key]
	var found := _place_way(z, cx, cy)
	if _ways.size() > 4096:
		_ways.clear()
	_ways[key] = found
	return found


## Ways found (a function of the seed; kept, as chunks round ask again).
var _ways := {}


func _place_way(z: int, cx: int, cy: int) -> Vector2i:
	# In a cave at both ends (the depth it leads to, and the depth above it
	# unless that is the surface): a way is not walled in, out of every
	# passage. A few places are tried, in an order of the seed.
	var first := NONE
	for k in WAY_TRIES:
		var lx := 4 + int(_hash3(cx, cy, z, 12 + 2 * k) * (Chunk.SIZE - 8))
		var ly := 4 + int(_hash3(cx, cy, z, 13 + 2 * k) * (Chunk.SIZE - 8))
		var at := Vector2i(cx * Chunk.SIZE + lx, cy * Chunk.SIZE + ly)
		if first == NONE:
			first = at
		if _open_round(at, z) and (z == -1 or _open_round(at, z + 1)):
			return at
	return first


## Whether a way's place opens on caves, not a pocket: the cell is cave, and
## so are cells ROUND cells away in at least two of eight directions.
const ROUND := 5


func _open_round(at: Vector2i, z: int) -> bool:
	if not is_cave(at.x, at.y, z):
		return false
	var open := 0
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
		if is_cave(at.x + d.x * ROUND, at.y + d.y * ROUND, z):
			open += 1
	return open >= 2


## How far a tunnel is dug from a way shut in rock to look for a cave.
const TUNNEL_REACH := 24
## "z|x|y" -> its tunnel (the same for every chunk that asks).
var _tunnels := {}


## The cells of a tunnel from a way at `at` of depth `z` to the nearest cave
## out of its hollow, two cells wide; none if it already opens on caves.
func tunnel(at: Vector2i, z: int) -> Array[Vector2i]:
	var key := "%d|%d|%d" % [z, at.x, at.y]
	if _tunnels.has(key):
		return _tunnels[key]
	var out: Array[Vector2i] = []
	if not _open_round(at, z):
		var to := NONE
		for r in range(_hollow + 2, TUNNEL_REACH + 1):  # ring by ring, the nearest first
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), absi(dy)) != r or to != NONE:
						continue
					if is_cave(at.x + dx, at.y + dy, z):
						to = at + Vector2i(dx, dy)
			if to != NONE:
				break
		if to != NONE:
			var seen := {}
			var steps := int(Vector2(to - at).length() * 3.0) + 1
			for i in steps + 1:
				var p := Vector2(at).lerp(Vector2(to), float(i) / steps).round()
				for w: Vector2i in [Vector2i(p), Vector2i(p) + Vector2i(1, 0), Vector2i(p) + Vector2i(0, 1)]:
					if not seen.has(w):
						seen[w] = true
						out.append(w)
	if _tunnels.size() > 4096:
		_tunnels.clear()
	_tunnels[key] = out
	return out


## Whether a cell of a depth is cave (open), as generate() makes it.
func is_cave(x: int, y: int, z: int) -> bool:
	return _caves.get_noise_3d(x, y, z * 9.0) > _cave_threshold or absf(_passages.get_noise_3d(x, y, z * 9.0)) < _passage_width


func generate(z: int, cx: int, cy: int) -> Chunk:
	var c := Chunk.new()
	c.meta = {"gen": ID, "gen_version": VERSION, "z": z}
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			var x := cx * Chunk.SIZE + lx
			var y := cy * Chunk.SIZE + ly
			var cave := is_cave(x, y, z)
			if cave and _water != "" and _pools.get_noise_3d(x, y, z * 9.0) > _water_threshold:
				c.set_cell("ground", lx, ly, _water)  # an underground pool
				continue
			c.set_cell("ground", lx, ly, _floor)
			if not cave:
				c.set_cell("structure", lx, ly, _rock_at(x, y, z))
	# Tunnels from ways shut in rock to the nearest cave: of the ways of this
	# chunk and its neighbours (a tunnel may cross into it), the cells here.
	for ny in range(cy - 1, cy + 2):
		for nx in range(cx - 1, cx + 2):
			for way: Vector2i in [entrance_at(z, nx, ny), entrance_at(z - 1, nx, ny)]:
				if way == NONE:
					continue
				for t: Vector2i in tunnel(way, z):
					var lx := t.x - cx * Chunk.SIZE
					var ly := t.y - cy * Chunk.SIZE
					if lx >= 0 and ly >= 0 and lx < Chunk.SIZE and ly < Chunk.SIZE:
						c.set_cell("ground", lx, ly, _floor)
						c.set_cell("structure", lx, ly, "")
	# Hollows round the ways: up from this depth (a way down from above ends
	# here) and down from it (one starts here).
	var up := entrance_at(z, cx, cy)
	if up != NONE:
		_hollow_at(c, cx, cy, up)
		if way_up != "":
			c.set_cell("structure", up.x - cx * Chunk.SIZE, up.y - cy * Chunk.SIZE, way_up)
	var down := entrance_at(z - 1, cx, cy)
	if down != NONE:
		_hollow_at(c, cx, cy, down)
		if way_down != "":
			c.set_cell("structure", down.x - cx * Chunk.SIZE, down.y - cy * Chunk.SIZE, way_down)
	return c


## The rock of a cell: a deposit's, where its noise says so, else plain rock.
## A deposit is as rich as the land above makes it (ADR-0053): its "relief"
## [lowland, hills, mountains] multiplies how often singles come and how
## much of the land veins run under.
func _rock_at(x: int, y: int, z: int) -> String:
	var above := geography.sample(Geography.HEIGHT, x, y) if geography else -INF
	for d: Dictionary in _deposits:
		if z > int(d["top"]) or z < int(d["bottom"]):
			continue
		var rich := relief_factor(d["relief"], above)
		if rich <= 0.0:
			continue
		var n: FastNoiseLite = d["noise"]
		if d["single"]:
			if _hash3(x, y, z, 21 + _deposits.find(d)) < float(d["threshold"]) * rich:
				return String(d["rock"])
		elif absf(n.get_noise_3d(x, y, z * 6.0)) < float(d["threshold"]) \
				and (d["area"] as FastNoiseLite).get_noise_3d(x, y, z * 6.0) > float(d["presence"]) - 0.25 * (rich - 1.0):
			return String(d["rock"])  # a vein: a ridge of the noise, running on, where veins are
	return _rock


## How rich a deposit is under land of a height: its relief's lowland, hills
## and mountains values, between them by the height (-INF: no land known — 1).
static func relief_factor(relief: Array, height: float) -> float:
	if height == -INF:
		return 1.0
	var low := Geography.HILLS * 0.5
	var mid := (Geography.HILLS + Geography.MOUNTAINS) * 0.5
	if height <= low:
		return float(relief[0])
	if height <= mid:
		return lerpf(float(relief[0]), float(relief[1]), (height - low) / (mid - low))
	return lerpf(float(relief[1]), float(relief[2]), clampf((height - mid) / (Geography.PEAKS - mid), 0.0, 1.0))


func _hollow_at(c: Chunk, cx: int, cy: int, at: Vector2i) -> void:
	for dy in range(-_hollow, _hollow + 1):
		for dx in range(-_hollow, _hollow + 1):
			if dx * dx + dy * dy > _hollow * _hollow + 1:
				continue
			var lx := at.x + dx - cx * Chunk.SIZE
			var ly := at.y + dy - cy * Chunk.SIZE
			if lx < 0 or ly < 0 or lx >= Chunk.SIZE or ly >= Chunk.SIZE:
				continue
			c.set_cell("ground", lx, ly, _floor)
			c.set_cell("structure", lx, ly, "")


func _hash3(x: int, y: int, z: int, salt: int) -> float:
	return float(absi(hash([world_seed, x, y, z, salt])) % 1000003) / 1000003.0
