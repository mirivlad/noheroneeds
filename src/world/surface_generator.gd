class_name SurfaceGenerator
extends RefCounted
## Makes surface chunks from the world seed. The same seed, ID and VERSION
## always give the same chunk. A chunk is generated once and then stored
## whole (ADR-0005), so a new VERSION only shapes places nobody has visited.
##
## Biomes are content: each lists its ground and plants with weights and how
## densely plants grow. Code here only decides where a biome is and samples
## from it, so new biomes come as data.

const ID := "base:surface"
## 2: ground lies in patches instead of per-cell noise.
## 3: cave mouths where the underground has a way up (ADR-0017).
## 4: settlements (ADR-0038).
## 5: settlements closer together, roads between them; biomes by climate
##    (warmth and wetness), taiga, grove, swamp, steppe, tundra, rocky hills.
## 6: geography (ADR-0049): an endless world of regions, each a landmass in
##    the one ocean; relief, climate from latitude, height and a west wind,
##    rivers and lakes by drainage, biomes by climate and height, rock on the
##    heights.
## 7: shallows at the edges of the sea and lakes, fords, deep water (ADR-0051).
## 8: pebbles (flint) on shores (ADR-0053).
## 9: villages in clusters, roads by the land (ADR-0054).
## 10: rugged land in levels with cliffs between them and passes (ADR-0061).
const VERSION := 13  # public houses, only in newly generated chunks
var world_seed := 0
## The land as a whole (shared, read only).
var geography: Geography
## From the generator's own definition (content "base:surface").
var _water := ""
## Water one wades through and deep water (ADR-0051; "" — none, common water).
var _shallows := ""
var _deep := ""
var _shore := ""
var _shore_cover: Array = []
var _shore_density := 0.0
## The rock the heights are made of (natural, dug with a pick).
var _rock := ""
## Grounds of a chasm and of a hanging bridge over it (ADR-0064); "" for none.
var _chasm := ""
var _hanging := ""
## All dry land of one height (no geography): asked for, or no generator
## described at all.
var _flat := true
## Cells around the spawn point kept free of anything solid.
var _clearing := 0
var _biomes: Array = []
## The same biomes' heights (low, high), climates and needing wet lowland,
## packed (they are looked through for every cell).
var _b_span := PackedVector2Array()
var _b_climate := PackedVector2Array()
var _b_wet := PackedByteArray()
## Biome ids in the order of _biomes.
var biome_ids: Array = []
## Plants that block walking (from their definitions), kept out of the spawn clearing.
var _solid := {}
## Small detail over the coarse land: its height's grain, the edges of biomes.
var _grain := FastNoiseLite.new()
var _rock_noise := FastNoiseLite.new()
## How rugged a place is beside its height, and where the passes are (ADR-0061).
var _rugged_noise := FastNoiseLite.new()
var _bumps_noise := FastNoiseLite.new()
var _pass_noise := FastNoiseLite.new()
## Rivers wind: a cell is measured to a course from a place shifted by this.
var _meander := FastNoiseLite.new()
## One noise field per patch slot (the n-th lesser ground of any biome uses field n).
var _patch_noise: Array[FastNoiseLite] = []
## Where the ways into the underground are (null: none).
var underground: UndergroundGenerator
## Where the settlements are and how they lie (ADR-0038).
var settlements: Settlements
## The river courses near the chunk last asked about (its key and segments).
var _rivers_key := Vector2i(1 << 30, 0)
var _rivers: Array = []


func _init(seed_value: int, content: ContentRegistry, plan: WorldPlan = null) -> void:
	world_seed = seed_value
	var ids: Array = []
	for id: String in content.defs:
		if content.kind_of(id) == "biome":
			ids.append(id)
	ids.sort()  # a stable order: the same content gives the same world
	for id: String in ids:
		var d := content.get_def(id)
		var span: Array = d.get("elevation", [-1.0, 2.0])
		_biomes.append({"ground": _patches(d["ground"]), "cover": _table(d.get("cover", {})),
			"density": float(d["cover_density"]), "climate": Vector2(d["climate"][0], d["climate"][1]),
			"low": float(span[0]), "high": float(span[1]), "wet_lowland": bool(d.get("wet_lowland", false))})
		biome_ids.append(id)
		_b_span.append(Vector2(span[0], span[1]))
		_b_climate.append(Vector2(d["climate"][0], d["climate"][1]))
		_b_wet.append(1 if d.get("wet_lowland", false) else 0)
		for plant: String in d.get("cover", {}):
			if content.get_def(plant).get("solid", false):
				_solid[plant] = true
	var g := content.get_def(ID)
	if g.get("kind") == "generator":
		_water = g["water"]
		_shallows = String(g.get("shallows", ""))
		_deep = String(g.get("deep", ""))
		_shore = g["shore"]
		_shore_cover = _table(g.get("shore_cover", {}))
		_shore_density = g["shore_cover_density"]
		_clearing = g["spawn_clearing"]
		_rock = String(g.get("rock", ""))
		_chasm = String(g.get("chasm", ""))
		_hanging = String(g.get("hanging_bridge", ""))
		_flat = bool(g["flat"])
	geography = (PlannedGeography.new(plan) if plan else Geography.of(seed_value)) if can_generate() and not _flat else null
	_grain.seed = seed_value + 7919
	_grain.frequency = 0.045
	_grain.fractal_octaves = 3
	_rock_noise.seed = seed_value + 9137
	_rock_noise.frequency = 0.09
	_rock_noise.fractal_octaves = 2
	_rugged_noise.seed = seed_value + 6007
	_rugged_noise.frequency = 0.006
	_rugged_noise.fractal_octaves = 2
	_bumps_noise.seed = seed_value + 7177
	_bumps_noise.frequency = 0.018
	_bumps_noise.fractal_octaves = 3
	_pass_noise.seed = seed_value + 8111
	_pass_noise.frequency = 0.045
	_pass_noise.fractal_octaves = 2
	_meander.seed = seed_value + 3571
	_meander.frequency = 0.03
	_meander.fractal_octaves = 2
	settlements = Settlements.new(seed_value, content, is_unfit, _clearing, biome_id_at, land_at if geography else Callable())
	for i in 8:
		var n := FastNoiseLite.new()
		n.seed = seed_value + 104729 * (i + 1)
		n.frequency = 0.07
		n.fractal_octaves = 2
		_patch_noise.append(n)


## Whether this content has anything to generate from.
func can_generate() -> bool:
	return not _biomes.is_empty() and _water != ""


func generate(cx: int, cy: int) -> Chunk:
	var c := Chunk.new()
	c.meta = {"gen": ID, "gen_version": VERSION}
	for ly in Chunk.SIZE:
		for lx in Chunk.SIZE:
			var x := cx * Chunk.SIZE + lx
			var y := cy * Chunk.SIZE + ly
			var clearing := absi(x) <= _clearing and absi(y) <= _clearing
			var land := land_at(x, y)
			var what := String(land["what"])
			if what in ["water", "deep", "shallows"] and not clearing:
				c.set_cell("ground", lx, ly, _water if what == "water" else (_deep if what == "deep" else _shallows))
				continue
			if what == "shore" and not clearing:
				c.set_cell("ground", lx, ly, _shore)
				if _hash(x, y, 4) < _shore_density:
					c.set_cell("cover", lx, ly, _pick(_shore_cover, _hash(x, y, 5)))
				continue
			var b: Dictionary = _biomes[int(land["biome"])]
			c.set_cell("ground", lx, ly, _ground_at(b["ground"], x, y))
			if what == "rock" and not clearing:
				c.set_cell("structure", lx, ly, _rock)
				continue
			if what in ["chasm", "bridge"] and not clearing:
				c.set_cell("ground", lx, ly, _chasm if what == "chasm" else _hanging)
				continue
			if _hash(x, y, 2) < float(b["density"]):
				var plant := _pick(b["cover"], _hash(x, y, 3))
				if plant != "" and not (clearing and _solid.has(plant)):
					c.set_cell("cover", lx, ly, plant)
	# Roads between settlements, under them (a settlement's own cells win).
	for road: Dictionary in settlements.roads_touching(cx, cy):
		var cells: Dictionary = road["cells"]
		for at: Vector2i in cells:
			var lx := at.x - cx * Chunk.SIZE
			var ly := at.y - cy * Chunk.SIZE
			if lx >= 0 and ly >= 0 and lx < Chunk.SIZE and ly < Chunk.SIZE:
				var on: Dictionary = cells[at]
				var under := c.get_cell("ground", lx, ly)
				if _swum(under):
					if String(on.get("over_water", "")) == "":
						continue
					c.set_cell("ground", lx, ly, on["over_water"])  # a bridge
				elif under != "" and under in [_chasm, _hanging]:
					c.set_cell("ground", lx, ly, _hanging)  # a road goes over a chasm on a hanging bridge
				else:
					c.set_cell("ground", lx, ly, on["ground"])
				c.set_cell("cover", lx, ly, "")
				c.set_cell("structure", lx, ly, "")  # a road is cut through rock
	# Settlements: the cells of each whose plan falls in this chunk (the same
	# in any order the chunks are made).
	for plan: Dictionary in settlements.plans_touching(cx, cy):
		# No trees in or round it (their crowns over roofs and streets); grass
		# and flowers stay.
		var free := (plan["bounds"] as Rect2i).grow(Settlements.TREE_FREE)
		for y in range(maxi(free.position.y, cy * Chunk.SIZE), mini(free.end.y, (cy + 1) * Chunk.SIZE)):
			for x in range(maxi(free.position.x, cx * Chunk.SIZE), mini(free.end.x, (cx + 1) * Chunk.SIZE)):
				if _solid.has(c.get_cell("cover", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE)):
					c.set_cell("cover", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, "")
				var ground := c.get_cell("ground", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE)
				if ground != "" and ground in [_chasm, _hanging]:  # no chasm through a village
					c.set_cell("ground", x - cx * Chunk.SIZE, y - cy * Chunk.SIZE, _ground_at(_biomes[int(land_at(x, y)["biome"])]["ground"], x, y))
		var cells: Dictionary = plan["cells"]
		for at: Vector2i in cells:
			var lx := at.x - cx * Chunk.SIZE
			var ly := at.y - cy * Chunk.SIZE
			if lx < 0 or ly < 0 or lx >= Chunk.SIZE or ly >= Chunk.SIZE:
				continue
			var spec: Dictionary = cells[at]
			if not spec.has("structure") and c.get_cell("structure", lx, ly) == _rock:
				c.set_cell("structure", lx, ly, "")  # a settlement's ground is cleared of rock
			for layer: String in ["ground", "cover", "structure", "roof"]:
				if spec.has(layer):
					c.set_cell(layer, lx, ly, spec[layer])
			if _wet(c.get_cell("ground", lx, ly)):
				c.set_cell("ground", lx, ly, _shore)  # a little water at its edge is made land
			if spec.has("props"):
				c.set_props(lx, ly, (spec["props"] as Dictionary).duplicate(true))
	for camp: Dictionary in settlements.camps.plans_touching(cx, cy):
		for at: Vector2i in camp["cells"]:
			var local := at - Vector2i(cx, cy) * Chunk.SIZE
			if local.x < 0 or local.y < 0 or local.x >= Chunk.SIZE or local.y >= Chunk.SIZE:
				continue
			var spec: Dictionary = camp["cells"][at]
			for layer: String in ["cover", "structure"]:
				c.set_cell(layer, local.x, local.y, String(spec.get(layer, "")))
			if spec.has("props"):
				c.set_props(local.x, local.y, spec["props"].duplicate(true))
		var middle: Vector2i = camp["centre"] - Vector2i(cx, cy) * Chunk.SIZE
		if middle.x >= 0 and middle.y >= 0 and middle.x < Chunk.SIZE and middle.y < Chunk.SIZE:
			c.meta["bandit_camp"] = camp["id"]
	for inn: Dictionary in settlements.inns.plans_touching(cx, cy):
		for at: Vector2i in inn["cells"]:
			var local := at - Vector2i(cx, cy) * Chunk.SIZE
			if local.x < 0 or local.y < 0 or local.x >= Chunk.SIZE or local.y >= Chunk.SIZE:
				continue
			var spec: Dictionary = inn["cells"][at]
			for layer: String in ["ground", "cover", "structure", "ceiling", "roof"]:
				if spec.has(layer):
					c.set_cell(layer, local.x, local.y, String(spec[layer]))
			if spec.has("props"):
				c.set_props(local.x, local.y, spec["props"].duplicate(true))
		var host: Vector2i = inn["host"]
		if host.x >> 5 == cx and host.y >> 5 == cy:
			c.meta["hospitality"] = inn["id"]
	if underground and underground.way_down_surface != "":
		var mouth := underground.entrance_at(-1, cx, cy)
		if mouth != UndergroundGenerator.NONE:
			place_mouth(c, mouth.x - cx * Chunk.SIZE, mouth.y - cy * Chunk.SIZE, underground.way_down_surface)
	return c


## Whether the surface at a world cell is water or its shore.
func is_wet(x: int, y: int) -> bool:
	return String(land_at(x, y)["what"]) in ["water", "deep", "shallows", "shore"]


## Whether a ground is water one swims in (bridges go over it).
func _swum(ground: String) -> bool:
	return ground != "" and (ground == _water or ground == _deep)


## Whether a ground is any of the generator's waters.
func _wet(ground: String) -> bool:
	return ground != "" and (ground == _water or ground == _deep or ground == _shallows)


## Whether a settlement may not stand on a cell: water, shore, rock, the
## heights.
func is_unfit(x: int, y: int) -> bool:
	var land := land_at(x, y)
	return String(land["what"]) != "land" or float(land["height"]) > Geography.MOUNTAINS


## What a world cell is (ADR-0049), from the land as a whole and a little
## grain: {"what": "water" | "deep" | "shallows" | "shore" | "rock" | "land",
## "height", "biome" (an index of the biomes, for land and rock)}. Deep is
## the open sea and the middle of big lakes; shallows (ADR-0051) the sea's
## and lakes' edges and fords on rivers, where one wades.
func land_at(x: int, y: int) -> Dictionary:
	var geo := geography
	if geo == null:
		return {"what": "land", "height": 0.1, "biome": _biome_at(x, y, 0.1, false)} if _flat else {"what": "water", "height": -1.0, "biome": 0}
	var h := height_at(x, y)
	if h < Geography.SEA:
		return {"what": _water_by_depth(Geography.SEA - h), "height": h, "biome": 0}
	if h < Geography.SEA + 0.012:
		return {"what": "shore", "height": h, "biome": 0}
	var lake := geo.lake_level_at(x, y)
	if h < lake:
		return {"what": _water_by_depth(lake - h), "height": h, "biome": 0}
	if h < lake + 0.008:
		return {"what": "shore", "height": h, "biome": 0}
	var key := Vector2i(floori(x / 32.0), floori(y / 32.0))
	if key != _rivers_key:
		_rivers_key = key
		# Only the courses that come within reach of the chunk (10 cells: what
		# counts as "by the water"; and their winding).
		_rivers = []
		var box := Rect2(Vector2(key * Chunk.SIZE), Vector2(Chunk.SIZE, Chunk.SIZE)).grow(20.0)
		for r: Array in geo.rivers_near(key.x, key.y):
			var a: Vector2 = r[0]
			var b: Vector2 = r[1]
			if Rect2(a, Vector2.ZERO).expand(b).grow(maxf(r[2], r[3])).intersects(box):
				_rivers.append(r)
	var near := INF
	var ford := false
	var at := Vector2(x + 0.5, y + 0.5)
	if not _rivers.is_empty():
		at += Vector2(_meander.get_noise_2d(x, y), _meander.get_noise_2d(y + 7919.0, x)) * 9.0
	for r: Array in _rivers:
		var a: Vector2 = r[0]
		var b: Vector2 = r[1]
		var ab := b - a
		var t := clampf((at - a).dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
		var half := lerpf(float(r[2]), float(r[3]), t) * 0.5
		var d := at.distance_to(a + ab * t) - half
		if d < near:
			near = d
			# A ford: across the river, in the middle of its stretch.
			ford = r[4] and absf(t - 0.5) * ab.length() < FORD_HALF
	if near < 0.0:
		return {"what": "shallows" if ford and _shallows != "" else "water", "height": h, "biome": 0}
	if near < 1.0 and _hash(x, y, 8) < 0.6:
		return {"what": "shore", "height": h, "biome": 0}
	var biome := _biome_at(x, y, h, near < 10.0)
	var chasm := chasm_at(x, y) if _chasm != "" and near > CHASM_FROM_WATER and _stepped(x, y, h) >= 0.5 else NO_CHASM
	if chasm == CHASM or chasm == BRIDGE:
		return {"what": "chasm" if chasm == CHASM else "bridge", "height": h, "biome": biome}
	if chasm != APPROACH and _rock != "" and (h + _rock_noise.get_noise_2d(x, y) * 0.07 > Geography.PEAKS - 0.06 or is_cliff(x, y, h)):
		return {"what": "rock", "height": h, "biome": biome}
	return {"what": "land", "height": h, "biome": biome}


# --- Chasms and hanging bridges (ADR-0064) -----------------------------------
# Rugged land is split here and there by a narrow chasm, too deep to climb, and
# a hanging bridge goes over each one between the levels on its two sides. The
# chasms run along some of the borders between sites strewn one to a square of
# CHASM_GRID cells (the borders of a Voronoi diagram); the bridge over the
# border of two sites crosses it where the line between them does, straight
# along the axis nearest that line: one row (or column) of cells, its ends cut
# through any cliff to the level beyond. Cells only: the same on every machine.

## Kinds of a cell for chasms.
enum {NO_CHASM, CHASM, BRIDGE, APPROACH}
const CHASM_GRID := 40.0
## Half a chasm's width, cells (3–4 across), and what share of the borders are chasms.
const CHASM_HALF := 1.7
const CHASM_SHARE := 0.3
## How far a bridge's ends are cut through cliffs beyond the chasm, cells.
const CHASM_APPROACH := 3.0
## No chasm this near a river (cells).
const CHASM_FROM_WATER := 4.0
## How far a hanging bridge sags in its middle, metres.
const BRIDGE_SAG := 0.7


## The site of a square of the chasms' grid (a point inside it, not near its edges).
func _chasm_site(k: Vector2i) -> Vector2:
	return (Vector2(k) + Vector2(0.2 + 0.6 * _hash(k.x, k.y, 31), 0.2 + 0.6 * _hash(k.x, k.y, 32))) * CHASM_GRID


## What a cell is for chasms, by the two nearest sites, wherever the land allows
## one (land_at): NO_CHASM, CHASM, BRIDGE (over it) or APPROACH (a bridge's way on).
func chasm_at(x: int, y: int) -> int:
	var c := _chasm_cut(x, y)
	return int(c[0])


## How far a hanging bridge's deck would sag at a cell (metres): deepest over
## the chasm's middle line, nothing at its edges or off it (a road's bridge too).
func bridge_sag(x: int, y: int) -> float:
	var c := _chasm_cut(x, y)
	return BRIDGE_SAG * (1.0 - pow(float(c[1]) / CHASM_HALF, 2.0)) if int(c[0]) in [CHASM, BRIDGE] else 0.0


## [kind, distance from the chasm's middle line (cells)].
func _chasm_cut(x: int, y: int) -> Array:
	var p := Vector2(x + 0.5, y + 0.5)
	var g := Vector2i(floori(p.x / CHASM_GRID), floori(p.y / CHASM_GRID))
	var a := g
	var b := g
	var da := INF
	var db := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var k := g + Vector2i(dx, dy)
			var d := p.distance_squared_to(_chasm_site(k))
			if d < da:
				b = a
				db = da
				a = k
				da = d
			elif d < db:
				b = k
				db = d
	var lo := a if a.x < b.x or (a.x == b.x and a.y < b.y) else b
	var hi := b if lo == a else a
	if _hash(lo.x * 9176 + hi.x, lo.y * 7919 + hi.y, 33) >= CHASM_SHARE:
		return [NO_CHASM, INF]
	var sa := _chasm_site(a)
	var sb := _chasm_site(b)
	var across := (db - da) / (2.0 * sa.distance_to(sb))  # from the border, toward the nearer site
	var mid := (sa + sb) * 0.5
	var row := y == floori(mid.y) if absf(sb.x - sa.x) >= absf(sb.y - sa.y) else x == floori(mid.x)
	if across < CHASM_HALF:
		return [BRIDGE if row else CHASM, across]
	if row and across < CHASM_HALF + CHASM_APPROACH:
		return [APPROACH, across]
	return [NO_CHASM, across]


# --- Relief in levels (ADR-0061) ---------------------------------------------
# Low land rolls gently; rugged land (hills and mountains, and some rugged
# lowland) rises in mesas and lies in flat levels LEVEL_METRES apart. The
# upper edge of a level is a cliff (the rock of the heights: it blocks walking, a
# pick digs it) except in passes, where the land runs smoothly from one level to
# the next. The server only ever sees the cliffs; the 3D view stands the land at
# metres_at().

## Metres a unit of height is, and of the fine grain over it.
const RELIEF_METRES := 28.0
const GRAIN_METRES := 4.0
## Levels of cells lately asked about (each cell's neighbours ask again); the
## chunk loader's thread and the simulation both ask.
var _levels := {}
var _levels_lock := Mutex.new()
## Metres between two levels, and how far rugged land rises and sinks round its height.
const LEVEL_METRES := 3.0
const BUMPS_METRES := 10.0


## The height of a cell (the coarse land and its grain), in the land's units.
func height_at(x: int, y: int) -> float:
	return _with_grain(x, y, geography.sample(Geography.HEIGHT, x, y)) if geography else 0.1


func _with_grain(x: int, y: int, macro: float) -> float:
	return macro + _grain.get_noise_2d(x, y) * 0.035


## How rugged land is, 0 (rolling) to 1 (levels and cliffs): by its height, hills
## upwards, and somewhat by place.
func ruggedness(x: int, y: int, h: float) -> float:
	return clampf(smoothstep(Geography.HILLS * 0.6, Geography.MOUNTAINS * 0.85, h) + _rugged_noise.get_noise_2d(x, y) * 0.7, 0.0, 1.0)


## How far a cell lies in a pass, 0 (none) to 1: a winding band of open land.
func openness(x: int, y: int) -> float:
	return smoothstep(0.2, 0.3, _pass_noise.get_noise_2d(x, y))


## Metres of the land before it is stepped: the height, the grain and, on rugged
## land, its mesas (only ever raised: no land sinks under the water beside it).
func _rolling(x: int, y: int, macro: float, h: float) -> float:
	return (macro - Geography.SEA) * RELIEF_METRES + (h - macro) * GRAIN_METRES \
		+ (_bumps_noise.get_noise_2d(x, y) * 0.5 + 0.5) * BUMPS_METRES * ruggedness(x, y, h)


## The level a cell is on.
func level_at(x: int, y: int) -> int:
	if geography == null:
		return 0
	var at := Vector2i(x, y)
	_levels_lock.lock()
	var known: Variant = _levels.get(at)
	_levels_lock.unlock()
	if known != null:
		return known
	var macro := geography.sample(Geography.HEIGHT, x, y)
	var level := floori(_rolling(x, y, macro, _with_grain(x, y, macro)) / LEVEL_METRES)
	_levels_lock.lock()
	if _levels.size() > 40000:
		_levels.clear()
	_levels[at] = level
	_levels_lock.unlock()
	return level


## Metres over the sea the ground of a cell stands at: rolling land as it rises,
## rugged land flat on its level, passes in between.
func metres_at(x: int, y: int) -> float:
	if geography == null:
		return 0.0
	var macro := geography.sample(Geography.HEIGHT, x, y)
	var h := _with_grain(x, y, macro)
	var rolling := _rolling(x, y, macro, h)
	return lerpf(rolling, floorf(rolling / LEVEL_METRES) * LEVEL_METRES, _stepped(x, y, h))


## How much of a cell stands on its level rather than on the rolling land.
func _stepped(x: int, y: int, h: float) -> float:
	return smoothstep(0.35, 0.6, ruggedness(x, y, h) * (1.0 - openness(x, y)))


## Whether a dry cell is the cliff at the upper edge of its level: stepped land
## between its level (or a higher one) and a lower one (the land below, or
## water). A strip of a level one cell wide is no cliff, just a hump.
func is_cliff(x: int, y: int, h: float) -> bool:
	if geography == null or _stepped(x, y, h) < 0.5:
		return false
	var level := level_at(x, y)
	var lower := false
	var level_beside := false
	for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var other := level_at(x + d.x, y + d.y)
		lower = lower or other < level
		level_beside = level_beside or other >= level
	return lower and level_beside


## Cells a ford is along a river (each way from its middle).
const FORD_HALF := 2.5
## Depths (in heights) below which water is deep, above which it is shallow.
const DEEP := 0.09
const SHALLOW := 0.006


func _water_by_depth(depth: float) -> String:
	if depth > DEEP and _deep != "":
		return "deep"
	if depth < SHALLOW and _shallows != "":
		return "shallows"
	return "water"


## A cave mouth at a cell of a chunk, on dry ground with nothing around it.
func place_mouth(c: Chunk, lx: int, ly: int, part: String) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := lx + dx
			var y := ly + dy
			if x < 0 or y < 0 or x >= Chunk.SIZE or y >= Chunk.SIZE:
				continue
			c.set_cell("cover", x, y, "")
			if _wet(c.get_cell("ground", x, y)) or c.get_cell("ground", x, y) == "":
				c.set_cell("ground", x, y, _shore)
	c.set_cell("structure", lx, ly, part)


## The biome a cell lies in (who lives there, ADR-0018); "" on water.
func biome_id_at(x: int, y: int) -> String:
	if _biomes.is_empty():
		return ""
	var land := land_at(x, y)
	if String(land["what"]) in ["water", "shore"]:
		return ""
	return String(biome_ids[int(land["biome"])])


## The biome of a dry cell: of those whose heights it lies in (and that
## need wet lowland, only there), the one whose climate (warmth, rain) is
## nearest the place's — a little jitter, so the edges are ragged.
func _biome_at(x: int, y: int, h: float, by_water: bool) -> int:
	var geo := geography
	var here := (geo.climate_at(x, y) if geo else Vector2.ZERO) \
		+ Vector2(_hash(x, y, 6) - 0.5, _hash(x, y, 7) - 0.5) * 0.08
	var soggy := by_water and h < Geography.HILLS * 0.6 and here.y > 0.15
	var best := 0
	var best_d := INF
	for i in _b_span.size():
		var span := _b_span[i]
		if h < span.x or h > span.y or (_b_wet[i] and not soggy):
			continue
		var d := here.distance_squared_to(_b_climate[i])
		if d < best_d:
			best_d = d
			best = i
	return best


## The dominant ground of a biome covers everything except patches of the
## lesser ones; a lesser ground with share s of the weights shows where its
## noise field is above a threshold that leaves about s of the area.
func _ground_at(g: Dictionary, x: int, y: int) -> String:
	var jitter := (_hash(x, y, 1) - 0.5) * 0.04  # ragged patch edges
	var lesser: Array = g["lesser"]
	for i in mini(lesser.size(), _patch_noise.size()):
		if _patch_noise[i].get_noise_2d(x, y) + jitter > lesser[i][1]:
			return lesser[i][0]
	return g["main"]


static func _patches(weights: Dictionary) -> Dictionary:
	var ids: Array = weights.keys()
	ids.sort()
	var total := 0.0
	var main := ""
	for id: String in ids:
		total += float(weights[id])
		if main == "" or float(weights[id]) > float(weights[main]):
			main = id
	var lesser: Array = []
	for id: String in ids:
		if id != main:
			# Fractal simplex noise is roughly normal with sd ~0.2 here.
			var share := float(weights[id]) / total
			lesser.append([id, 0.2 * sqrt(-2.0 * log(maxf(share, 0.001))) * 0.8])
	return {"main": main, "lesser": lesser}


## [[id, cumulative weight], ...] with the total last.
static func _table(weights: Dictionary) -> Array:
	var ids: Array = weights.keys()
	ids.sort()
	var out: Array = []
	var total := 0.0
	for id: String in ids:
		total += float(weights[id])
		out.append([id, total])
	return out


static func _pick(table: Array, r: float) -> String:
	if table.is_empty():
		return ""
	var t: float = r * table[-1][1]
	for e: Array in table:
		if t < e[1]:
			return e[0]
	return table[-1][0]


## Deterministic value in [0, 1) for a cell and a purpose.
func _hash(x: int, y: int, salt: int) -> float:
	var n := (x * 374761393 + y * 668265263 + salt * 2246822519 + world_seed * 3266489917) & 0xFFFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
	return float((n ^ (n >> 16)) & 0xFFFFFF) / float(0x1000000)
