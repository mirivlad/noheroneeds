class_name WorldPlan
extends RefCounted
## A generated, serializable coarse map. Coordinates are coarse points, each
## representing STEP surface cells. The packed fields are the authority, not
## a recipe to re-run when a world is opened.

const FORMAT := 3
const STEP := Chunk.SIZE
const PRESETS := {
	"single_continent": Vector2i(160, 160),
	"small": Vector2i(160, 80),
	"medium": Vector2i(256, 128),
	"large": Vector2i(384, 192),
	"huge": Vector2i(512, 256),
}
## What kind of land a planet preset is, in the same place as its size: the
## continents it is made of (a count, not a noise scale), the share of its
## surface that is land, and the small isles between the continents. A bigger
## planet gets more and larger continents, not more and smaller islands.
const LANDS := {
	"small": {"continents": 3, "share": 0.28, "isles": 2},
	"medium": {"continents": 4, "share": 0.31, "isles": 3},
	"large": {"continents": 5, "share": 0.34, "isles": 4},
	"huge": {"continents": 6, "share": 0.37, "isles": 5},
}
const CLIMATES := ["hot", "temperate", "cold"]

var seed_value := 0
var preset := ""
var climate := ""
var size := Vector2i.ZERO
## Three bytes per point: height, warmth and rainfall, encoded from -1..1.
var fields := PackedByteArray()
var spawn := Vector2i.ZERO
## Precomputed drainage, river widths and lake surfaces for every map point.
var downstream := PackedInt32Array()
var river := PackedFloat32Array()
var lake := PackedFloat32Array()
## Stable global biome ids and the selected index at each coarse point.
var biome_ids: Array[String] = []
var biomes := PackedByteArray()


static func generate(seed_number: int, size_preset: String, climate_preset: String, registry: ContentRegistry = null) -> WorldPlan:
	if not PRESETS.has(size_preset) or not climate_preset in CLIMATES:
		return null
	var plan := WorldPlan.new()
	plan.seed_value = seed_number
	plan.preset = size_preset
	plan.climate = climate_preset
	plan.size = PRESETS[size_preset]
	plan.fields.resize(plan.size.x * plan.size.y * 3)
	var land := FastNoiseLite.new()
	land.seed = seed_number
	land.frequency = 1.0
	land.fractal_octaves = 4
	var mountains := FastNoiseLite.new()
	mountains.seed = seed_number + 2027
	mountains.frequency = 1.0
	mountains.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountains.fractal_octaves = 3
	var moisture := FastNoiseLite.new()
	moisture.seed = seed_number + 1013
	moisture.frequency = 1.0
	moisture.fractal_octaves = 3
	# The coarse shape of a planet: a few large continents (with peninsulas)
	# and a handful of small isles between them. The continents are placed and
	# sized before any cell is looked at, so the preset decides how the world
	# is made, not only how much of it there is.
	var coast := FastNoiseLite.new()
	coast.seed = seed_number + 4099
	coast.fractal_octaves = 3
	var shape := {}
	if size_preset != "single_continent":
		shape = _continents(seed_number, size_preset, plan.size)
	var shift := 0.3 if climate_preset == "hot" else (-0.3 if climate_preset == "cold" else 0.0)
	for y in plan.size.y:
		for x in plan.size.x:
			var u := (float(x) + 0.5) / plan.size.x
			var v := (float(y) + 0.5) / plan.size.y
			var h: float
			var wet: float
			var ridge: float
			if size_preset == "single_continent":
				var p := Vector2((u - 0.5) * 2.0, (v - 0.5) * 2.0)
				var distance := p.length()
				var angle := atan2(p.y, p.x)
				# A radius for every direction keeps all land connected to the centre.
				var coast_r := 0.65 + land.get_noise_2d(cos(angle) * 2.0, sin(angle) * 2.0) * 0.2
				h = (coast_r - distance) * 0.55
				wet = moisture.get_noise_2d(u * 4.0, v * 4.0)
				ridge = mountains.get_noise_2d(u * 6.0, v * 6.0)
			else:
				# Spherical sampling joins longitude at the seam and converges at the poles.
				# The continents are caps on the sphere: one smooth field crossing the sea
				# level at their coasts, so land is a few masses, not scattered islets.
				var lon := u * TAU
				var lat := (v - 0.5) * PI
				var p := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
				var edge := coast.get_noise_3d(p.x * 2.6, p.y * 2.6, p.z * 2.6)
				h = _continent_height(shape, p, edge) * 0.55
				# Detail inland only: a little relief, never new islets at the coast.
				h += land.get_noise_3d(p.x * 6.0, p.y * 6.0, p.z * 6.0) * 0.05 * smoothstep(0.03, 0.14, h)
				wet = moisture.get_noise_3d(p.x * 3.0, p.y * 3.0, p.z * 3.0)
				ridge = mountains.get_noise_3d(p.x * 6.0, p.y * 6.0, p.z * 6.0)
			h += maxf(ridge + 0.25, 0.0) * 0.5 * smoothstep(0.02, 0.15, h)
			var latitude := absf(v - 0.5) * 2.0
			var warmth := clampf(0.85 - latitude * 1.8 + shift - maxf(h, 0.0) * 0.6, -1.0, 1.0)
			var rain := clampf(wet * 1.2 - maxf(shift, 0.0) * 0.35, -1.0, 1.0)
			var idx := (y * plan.size.x + x) * 3
			plan.fields[idx] = _encode(h)
			plan.fields[idx + 1] = _encode(warmth)
			plan.fields[idx + 2] = _encode(rain)
	plan._orographic_rain()
	WorldHydrology.build(plan)
	plan._choose_spawn()
	if registry == null:
		registry = ContentRegistry.load_packs(["res://content/base"])
	if not plan._bake_biomes(registry):
		return null
	return plan


## The continents of a planet, ready to sample: a few large caps, each an
## elongated mass with lobes (peninsulas and wide bays), and `isles` small
## isles in the ocean between them. Their radii are tuned so the land covers
## `share` of the map: the preset says how much land and how many masses, not
## a noise scale. No mass is round: each is stretched along its own axis and
## bent by the coast noise, so a coast is a coast, not a circle.
static func _continents(seed_number: int, preset_id: String, size: Vector2i) -> Dictionary:
	var rules: Dictionary = LANDS[preset_id]
	var count := int(rules["continents"])
	var share := float(rules["share"])
	var isles := int(rules["isles"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_number
	# An even spread of the masses round the sphere (a Fibonacci lattice, kept
	# off the poles so the poles stay open sea), each a little off its place.
	var base := acos(clampf(1.0 - 2.0 * share / count, -1.0, 1.0))
	var out: Array = []
	for i in count:
		var t := (float(i) + 0.5) / count
		var y := (1.0 - 2.0 * t) * 0.78
		var across := sqrt(maxf(0.0, 1.0 - y * y))
		var angle := float(i) * 2.399963 + rng.randf_range(-0.3, 0.3)
		var at := Vector3(across * cos(angle), y, across * sin(angle)).normalized()
		var radius := base * rng.randf_range(0.9, 1.15)
		var side := Vector3.UP.cross(at)
		if side.length() < 0.01:
			side = Vector3.RIGHT
		side = side.normalized()
		var up := at.cross(side).normalized()
		# A few lobes out from the rim (peninsulas); a stretch along one axis
		# (a long land, not a round one).
		var lobes: Array = []
		for l in 3:
			var way := side * cos(rng.randf() * TAU) + up * sin(rng.randf() * TAU)
			var out_along := radius * rng.randf_range(0.45, 0.85)
			var turned := (at * cos(out_along) + way * sin(out_along)).normalized()
			lobes.append({"at": turned, "radius": radius * rng.randf_range(0.45, 0.72), "stretch": 1.0})
		out.append({"at": at, "radius": radius, "side": side, "up": up, "stretch": rng.randf_range(1.0, 1.65),
			"lobes": lobes})
	var small: Array = []
	var placed := 0
	for attempt in 400:
		if placed >= isles:
			break
		var z := rng.randf_range(-0.8, 0.8)
		var across := sqrt(maxf(0.0, 1.0 - z * z))
		var angle := rng.randf() * TAU
		var at := Vector3(across * cos(angle), z, across * sin(angle))
		var clear := true
		for c: Dictionary in out:
			for spot: Dictionary in [c] + (c["lobes"] as Array):
				if at.angle_to(spot["at"]) < float(spot["radius"]) * 2.1 + 0.08:
					clear = false
					break
			if not clear:
				break
		if clear:
			small.append({"at": at, "radius": rng.randf_range(0.018, 0.038)})
			placed += 1
	# Scale every radius so land is `share` of the map's points (two passes:
	# caps overlap a little, so the first guess comes up short). Measured on a
	# sample of the map's points: a whole huge map is millions of look-ups.
	var stride := maxi(1, mini(size.x, size.y) / 64)
	var samples := 0
	var got := 0.0
	for pass_index in 2:
		got = 0.0
		samples = 0
		for y in range(0, size.y, stride):
			for x in range(0, size.x, stride):
				samples += 1
				if _mask(out, small, _on_sphere(x, y, size), 0.0) > 0.0:
					got += 1.0
		var have := got / float(samples)
		if have <= 0.0:
			break
		var scale := clampf(sqrt(share / have), 0.5, 2.0)
		for c: Dictionary in out:
			c["radius"] = float(c["radius"]) * scale
			for lobe: Dictionary in c["lobes"]:
				lobe["radius"] = float(lobe["radius"]) * scale
		for isle: Dictionary in small:
			isle["radius"] = float(isle["radius"]) * scale
	return {"continents": out, "isles": small}


## A map point's direction on the sphere (longitude wraps at the seam, the
## latitude lines converge at the poles).
static func _on_sphere(x: int, y: int, size: Vector2i) -> Vector3:
	var lon := (float(x) + 0.5) / size.x * TAU
	var lat := ((float(y) + 0.5) / size.y - 0.5) * PI
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))


## How far inside the land a direction is: 1 deep within a continent, 0 on its
## coast, negative at sea. The coast noise bends every coast as one, so the
## continents keep their shape instead of breaking into an archipelago.
static func _continent_height(shape: Dictionary, at: Vector3, edge: float) -> float:
	return maxf(_mask(shape["continents"], shape["isles"], at, edge), -1.0)


static func _mask(continents: Array, isles: Array, at: Vector3, edge: float) -> float:
	var best := -1.0
	var bend := 1.0 + 0.5 * edge
	for c: Dictionary in continents:
		best = maxf(best, 1.0 - _cap_distance(at, c) / maxf(float(c["radius"]) * bend, 0.02))
		for lobe: Dictionary in c["lobes"]:
			best = maxf(best, 1.0 - _cap_distance(at, lobe) / maxf(float(lobe["radius"]) * bend, 0.02))
	for isle: Dictionary in isles:
		best = maxf(best, 1.0 - at.angle_to(isle["at"]) / maxf(float(isle["radius"]) * bend, 0.01))
	return best


## The angular distance from a direction to a cap's middle, stretched along the
## cap's axis (an ellipse on the sphere, not a round cap).
static func _cap_distance(at: Vector3, cap: Dictionary) -> float:
	var theta := at.angle_to(cap["at"])
	if theta < 0.0001:
		return 0.0
	var stretch := float(cap.get("stretch", 1.0))
	if stretch == 1.0 or not cap.has("side"):
		return theta
	var along := absf(at.dot(cap["side"]))
	var across := absf(at.dot(cap["up"]))
	var length := sqrt(along * along + across * across)
	if length < 0.0001:
		return theta
	var axis := along / length
	var other := across / length
	return theta * sqrt(pow(axis / stretch, 2.0) + pow(other * stretch, 2.0))


## Choose after hydrology: the origin must not be in a lake or river.
func _choose_spawn() -> void:
	var best := -INF
	for k in size.x * size.y:
		var h := float(fields[k * 3]) / 127.5 - 1.0
		if h < 0.05 or lake[k] > 0.0 or river[k] > 0.0:
			continue
		var warmth := float(fields[k * 3 + 1]) / 127.5 - 1.0
		var rain := float(fields[k * 3 + 2]) / 127.5 - 1.0
		var score := -absf(warmth - 0.1) - absf(rain) * 0.3 - absf(h - 0.12) * 2.0
		if score > best:
			best = score
			spawn = Vector2i(k % size.x, k / size.x)


## Select biomes once from the content's existing elevation and climate rules.
func _bake_biomes(registry: ContentRegistry) -> bool:
	var defs: Array[Dictionary] = []
	for id: String in registry.defs:
		if registry.kind_of(id) == "biome":
			biome_ids.append(id)
	biome_ids.sort()
	if biome_ids.is_empty() or biome_ids.size() > 256:
		return false
	for id: String in biome_ids:
		defs.append(registry.get_def(id))
	biomes.resize(size.x * size.y)
	for k in biomes.size():
		var h := float(fields[k * 3]) / 127.5 - 1.0
		var climate_here := Vector2(float(fields[k * 3 + 1]) / 127.5 - 1.0, float(fields[k * 3 + 2]) / 127.5 - 1.0)
		var soggy := (lake[k] > 0.0 or river[k] > 0.0) and h < Geography.HILLS * 0.6 and climate_here.y > 0.15
		var best := 0
		var best_distance := INF
		for i in defs.size():
			var d := defs[i]
			var span: Array = d.get("elevation", [-1.0, 2.0])
			if h < float(span[0]) or h > float(span[1]) or (bool(d.get("wet_lowland", false)) and not soggy):
				continue
			var climate_value: Array = d.get("climate", [0.0, 0.0])
			var distance := climate_here.distance_squared_to(Vector2(climate_value[0], climate_value[1]))
			if distance < best_distance:
				best_distance = distance
				best = i
		biomes[k] = best
	return true


func biome_at(cell: Vector2i) -> String:
	var p := Vector2i(roundi(float(cell.x) / STEP), roundi(float(cell.y) / STEP)) + spawn
	var k := WorldHydrology.index_at(self, p)
	return biome_ids[biomes[k]] if k >= 0 and not biomes.is_empty() else ""


## Moisture brought by the prevailing west wind falls over rising land.
## The first circuit of a planet supplies the initial moisture at the seam.
func _orographic_rain() -> void:
	for y in size.y:
		var water := 1.0
		var last := 0.0
		var circuits := 2 if preset != "single_continent" else 1
		for i in size.x * circuits:
			var x := i % size.x
			var k := (y * size.x + x) * 3
			var h := float(fields[k]) / 127.5 - 1.0
			if h < 0.0:
				water = minf(1.0, water + 0.12)
			else:
				var rise := maxf(0.0, h - last)
				var rainout := clampf(water * (0.025 + 1.5 * rise), 0.0, water)
				water = minf(1.0, water - rainout + 0.008)
				if i >= size.x * (circuits - 1):
					var noise := float(fields[k + 2]) / 127.5 - 1.0
					fields[k + 2] = _encode(clampf(noise * 0.55 + water * 0.8 + rainout * 2.0 - 0.45, -1.0, 1.0))
			last = maxf(h, 0.0)


static func _encode(value: float) -> int:
	return clampi(roundi((value + 1.0) * 127.5), 0, 255)


func value(field: int, point: Vector2i) -> float:
	if field < 0 or field > 2:
		return 0.0
	var p := point
	if preset == "single_continent":
		if p.x < 0 or p.y < 0 or p.x >= size.x or p.y >= size.y:
			return -0.5 if field == 0 else 0.0
	else:
		# Crossing either pole reverses latitude and turns longitude halfway.
		p.y = posmod(p.y, size.y * 2)
		if p.y >= size.y:
			p.y = size.y * 2 - 1 - p.y
			p.x += size.x / 2
		p.x = posmod(p.x, size.x)
	return float(fields[(p.y * size.x + p.x) * 3 + field]) / 127.5 - 1.0


## Bilinear sample in world cells, with world (0, 0) at the chosen spawn.
func sample(field: int, cell: Vector2i) -> float:
	var position := Vector2(cell) / STEP + Vector2(spawn)
	var x := floori(position.x)
	var y := floori(position.y)
	var fx := position.x - x
	var fy := position.y - y
	var top := lerpf(value(field, Vector2i(x, y)), value(field, Vector2i(x + 1, y)), fx)
	var bottom := lerpf(value(field, Vector2i(x, y + 1)), value(field, Vector2i(x + 1, y + 1)), fx)
	return lerpf(top, bottom, fy)


func to_dict() -> Dictionary:
	return {"format": FORMAT, "seed": str(seed_value), "type": "single_continent" if preset == "single_continent" else "planet",
		"preset": preset, "climate": climate,
		"width": size.x, "height": size.y, "spawn_x": spawn.x, "spawn_y": spawn.y,
		"fields": Marshalls.raw_to_base64(fields),
		"downstream": Marshalls.raw_to_base64(downstream.to_byte_array()),
		"river": Marshalls.raw_to_base64(river.to_byte_array()),
		"lake": Marshalls.raw_to_base64(lake.to_byte_array()),
		"biome_ids": biome_ids, "biomes": Marshalls.raw_to_base64(biomes)}


static func from_dict(data: Dictionary) -> WorldPlan:
	if int(data.get("format", 0)) != FORMAT:
		return null
	var preset_id := String(data.get("preset", ""))
	var climate_id := String(data.get("climate", ""))
	if not PRESETS.has(preset_id) or not climate_id in CLIMATES:
		return null
	var expected_type := "single_continent" if preset_id == "single_continent" else "planet"
	if String(data.get("type", "")) != expected_type:
		return null
	var dimensions: Vector2i = PRESETS[preset_id]
	if int(data.get("width", 0)) != dimensions.x or int(data.get("height", 0)) != dimensions.y:
		return null
	var bytes := Marshalls.base64_to_raw(String(data.get("fields", "")))
	if bytes.size() != dimensions.x * dimensions.y * 3:
		return null
	var down_bytes := Marshalls.base64_to_raw(String(data.get("downstream", "")))
	var river_bytes := Marshalls.base64_to_raw(String(data.get("river", "")))
	var lake_bytes := Marshalls.base64_to_raw(String(data.get("lake", "")))
	if down_bytes.size() != dimensions.x * dimensions.y * 4 or river_bytes.size() != down_bytes.size() or lake_bytes.size() != down_bytes.size():
		return null
	var down := down_bytes.to_int32_array()
	var rivers := river_bytes.to_float32_array()
	var lakes := lake_bytes.to_float32_array()
	for k in down.size():
		if down[k] < -1 or down[k] >= down.size() or not is_finite(rivers[k]) or not is_finite(lakes[k]) \
				or rivers[k] < 0.0 or rivers[k] > 9.0 or lakes[k] < 0.0 or lakes[k] > 1.01:
			return null
	var biome_values: Variant = data.get("biome_ids")
	var biome_data := Marshalls.base64_to_raw(String(data.get("biomes", "")))
	if not biome_values is Array or biome_values.is_empty() or biome_values.size() > 256 or biome_data.size() != dimensions.x * dimensions.y:
		return null
	var ids: Array[String] = []
	for entry: Variant in biome_values:
		if not entry is String or entry == "" or entry in ids:
			return null
		ids.append(entry)
	for i in biome_data:
		if i >= ids.size():
			return null
	var at := Vector2i(int(data.get("spawn_x", -1)), int(data.get("spawn_y", -1)))
	if at.x < 0 or at.y < 0 or at.x >= dimensions.x or at.y >= dimensions.y:
		return null
	var plan := WorldPlan.new()
	plan.seed_value = int(data.get("seed", 0))
	plan.preset = preset_id
	plan.climate = climate_id
	plan.size = dimensions
	plan.fields = bytes
	plan.downstream = down
	plan.river = rivers
	plan.lake = lakes
	plan.biome_ids = ids
	plan.biomes = biome_data
	plan.spawn = at
	return plan


## Canonical coordinates on a planet, in any integral units per map point.
## At a pole the local y axis reverses and longitude moves half a turn.
## A continent has no wrapping: its ocean continues in all directions.
func canonical_point(point: Vector2i, units_per_point: int) -> Vector2i:
	if preset == "single_continent":
		return point
	var origin := spawn * units_per_point
	var width := size.x * units_per_point
	var height := size.y * units_per_point
	var p := point + origin
	p.y = posmod(p.y, height * 2)
	if p.y >= height:
		p.y = height * 2 - 1 - p.y
		p.x += width / 2
	p.x = posmod(p.x, width)
	return p - origin
