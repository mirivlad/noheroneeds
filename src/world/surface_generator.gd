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
const VERSION := 5
var world_seed := 0
## From the generator's own definition (content "base:surface").
var _water := ""
var _shore := ""
var _shore_cover: Array = []
var _shore_density := 0.0
## Water where the water noise (-1..1) is above this; shore just below it.
var _water_level := 0.5
var _shore_width := 0.0
## Cells around the spawn point kept free of anything solid.
var _clearing := 0
var _biomes: Array = []
## Biome ids in the order of _biomes.
var biome_ids: Array = []
## Plants that block walking (from their definitions), kept out of the spawn clearing.
var _solid := {}
## Warmth and wetness of the land (-1..1 each, slow): a place's biome is the
## one whose climate is nearest (so snow lies by the taiga, not by the steppe).
var _biome_noise := FastNoiseLite.new()
var _wet_noise := FastNoiseLite.new()
var _water_noise := FastNoiseLite.new()
## One noise field per patch slot (the n-th lesser ground of any biome uses field n).
var _patch_noise: Array[FastNoiseLite] = []
## Where the ways into the underground are (null: none).
var underground: UndergroundGenerator
## Where the settlements are and how they lie (ADR-0038).
var settlements: Settlements


func _init(seed_value: int, content: ContentRegistry) -> void:
	world_seed = seed_value
	var ids: Array = []
	for id: String in content.defs:
		if content.kind_of(id) == "biome":
			ids.append(id)
	ids.sort()  # a stable order: the same content gives the same world
	for id: String in ids:
		var d := content.get_def(id)
		_biomes.append({"ground": _patches(d["ground"]), "cover": _table(d.get("cover", {})),
			"density": float(d["cover_density"]), "climate": Vector2(d["climate"][0], d["climate"][1])})
		biome_ids.append(id)
		for plant: String in d.get("cover", {}):
			if content.get_def(plant).get("solid", false):
				_solid[plant] = true
	var g := content.get_def(ID)
	if g.get("kind") == "generator":
		_water = g["water"]
		_shore = g["shore"]
		_shore_cover = _table(g.get("shore_cover", {}))
		_shore_density = g["shore_cover_density"]
		_clearing = g["spawn_clearing"]
		_water_level = g["water_threshold"]
		_shore_width = g["shore_width"]
	_biome_noise.seed = seed_value
	_biome_noise.frequency = 0.0025
	_biome_noise.fractal_octaves = 3
	_wet_noise.seed = seed_value + 4241
	_wet_noise.frequency = 0.003
	_wet_noise.fractal_octaves = 3
	_water_noise.seed = seed_value + 7919
	_water_noise.frequency = 0.03
	_water_noise.fractal_octaves = 2
	settlements = Settlements.new(seed_value, content, is_wet, _clearing, biome_id_at)
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
			var water := _water_noise.get_noise_2d(x, y)
			if water > _water_level and not clearing:
				c.set_cell("ground", lx, ly, _water)
				continue
			if water > _water_level - _shore_width and not clearing:
				c.set_cell("ground", lx, ly, _shore)
				if _hash(x, y, 4) < _shore_density:
					c.set_cell("cover", lx, ly, _pick(_shore_cover, _hash(x, y, 5)))
				continue
			var b: Dictionary = _biomes[_biome_at(x, y)]
			c.set_cell("ground", lx, ly, _ground_at(b["ground"], x, y))
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
				if c.get_cell("ground", lx, ly) == _water:
					if String(on.get("over_water", "")) == "":
						continue
					c.set_cell("ground", lx, ly, on["over_water"])  # a bridge
				else:
					c.set_cell("ground", lx, ly, on["ground"])
				c.set_cell("cover", lx, ly, "")
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
		var cells: Dictionary = plan["cells"]
		for at: Vector2i in cells:
			var lx := at.x - cx * Chunk.SIZE
			var ly := at.y - cy * Chunk.SIZE
			if lx < 0 or ly < 0 or lx >= Chunk.SIZE or ly >= Chunk.SIZE:
				continue
			var spec: Dictionary = cells[at]
			for layer: String in ["ground", "cover", "structure", "roof"]:
				if spec.has(layer):
					c.set_cell(layer, lx, ly, spec[layer])
			if c.get_cell("ground", lx, ly) == _water:
				c.set_cell("ground", lx, ly, _shore)  # a little water at its edge is made land
			if spec.has("props"):
				c.set_props(lx, ly, (spec["props"] as Dictionary).duplicate(true))
	if underground and underground.way_down_surface != "":
		var mouth := underground.entrance_at(-1, cx, cy)
		if mouth != UndergroundGenerator.NONE:
			place_mouth(c, mouth.x - cx * Chunk.SIZE, mouth.y - cy * Chunk.SIZE, underground.way_down_surface)
	return c


## Whether the surface at a world cell is water or its shore (no settlement there).
func is_wet(x: int, y: int) -> bool:
	return _water_noise.get_noise_2d(x, y) > _water_level - _shore_width


## A cave mouth at a cell of a chunk, on dry ground with nothing around it.
func place_mouth(c: Chunk, lx: int, ly: int, part: String) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := lx + dx
			var y := ly + dy
			if x < 0 or y < 0 or x >= Chunk.SIZE or y >= Chunk.SIZE:
				continue
			c.set_cell("cover", x, y, "")
			if c.get_cell("ground", x, y) == _water or c.get_cell("ground", x, y) == "":
				c.set_cell("ground", x, y, _shore)
	c.set_cell("structure", lx, ly, part)


## The biome a cell lies in (who lives there, ADR-0018); "" on water.
func biome_id_at(x: int, y: int) -> String:
	if _biomes.is_empty() or _water_noise.get_noise_2d(x, y) > _water_level - _shore_width:
		return ""
	return String(biome_ids[_biome_at(x, y)])


func _biome_at(x: int, y: int) -> int:
	# Fractal noise keeps mostly within -0.6..0.6: stretched to the climates' range,
	# a little jitter so the edges between biomes are ragged.
	var here := Vector2(_biome_noise.get_noise_2d(x, y), _wet_noise.get_noise_2d(x, y)) * 1.4 \
		+ Vector2(_hash(x, y, 6) - 0.5, _hash(x, y, 7) - 0.5) * 0.06
	var best := 0
	var best_d := INF
	for i in _biomes.size():
		var d := here.distance_squared_to(_biomes[i]["climate"])
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
