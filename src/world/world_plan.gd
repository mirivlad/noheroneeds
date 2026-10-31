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
	# The coarse shape of a planet: lithospheric plates on the sphere, some
	# carrying continental crust, drifting and colliding. The plates are placed
	# before any cell is looked at, so the preset decides how the world is
	# made, not only how much of it there is.
	var warp := FastNoiseLite.new()
	warp.seed = seed_number + 4099
	warp.frequency = 1.0
	warp.fractal_octaves = 3
	var coast := FastNoiseLite.new()
	coast.seed = seed_number + 4253
	coast.frequency = 1.0
	coast.fractal_octaves = 4
	var fine := FastNoiseLite.new()
	fine.seed = seed_number + 4441
	fine.frequency = 1.0
	fine.fractal_octaves = 3
	var shape := {}
	if size_preset != "single_continent":
		shape = _tectonics(seed_number, size_preset, plan.size, warp, coast, fine)
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
				h += maxf(ridge + 0.25, 0.0) * 0.5 * smoothstep(0.02, 0.15, h)
			else:
				# Spherical sampling joins longitude at the seam and converges at the poles.
				# A planet's continents come from its tectonic plates, spines and boundaries,
				# with collision foldbelts and rift valleys built into the relief.
				var lon := u * TAU
				var lat := (v - 0.5) * PI
				var p := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
				var r := _tectonic_relief(shape, p, warp, coast, fine)
				h = r.x
				wet = moisture.get_noise_3d(p.x * 3.0, p.y * 3.0, p.z * 3.0)
				ridge = mountains.get_noise_3d(p.x * 6.0, p.y * 6.0, p.z * 6.0)
				h += land.get_noise_3d(p.x * 6.0, p.y * 6.0, p.z * 6.0) * 0.04 * smoothstep(0.02, 0.14, h)
				h += (maxf(ridge + 0.2, 0.0) * (0.28 + 0.55 * r.y) + r.y * 0.22 - r.z * 0.14) * smoothstep(0.01, 0.12, h)
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


## A map point's direction on the sphere (longitude wraps at the seam, the
## latitude lines converge at the poles).
static func _on_sphere(x: int, y: int, size: Vector2i) -> Vector3:
	var lon := (float(x) + 0.5) / size.x * TAU
	var lat := ((float(y) + 0.5) / size.y - 0.5) * PI
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))


## The tectonic history of a planet: lithospheric plates on the sphere, some
## continental and some oceanic, each with its own tangent drift velocity and
## deformed crustal spine. Continents emerge from continental plate domains,
## terranes accreted along the drifting margin, collision sutures, rifts and
## island arcs — never from round, elliptical or radially fading masks. Sea level is calibrated on a spherical sample so
## the preset's land share holds while continent sizes vary naturally.
static func _tectonics(seed_number: int, preset_id: String, size: Vector2i, warp: FastNoiseLite, coast: FastNoiseLite, fine: FastNoiseLite) -> Dictionary:
	var rules: Dictionary = LANDS[preset_id]
	var count := int(rules["continents"])
	var share := float(rules["share"])
	var isles := int(rules["isles"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_number
	var plate_count := count * 2 + 4
	var spin := rng.randf_range(0.0, TAU)
	# Where the plates are, before anything is grown on them. A Fibonacci
	# lattice spreads them over the sphere; each is then pushed away from its
	# neighbours a few times, so no two nuclei (and therefore no two continents)
	# start on top of each other. Nuclei stay off the poles: a plate centred on
	# a pole becomes a full-width band of land on an equirectangular map.
	var centers: Array[Vector3] = []
	for i in plate_count:
		var t := (float(i) + 0.5) / float(plate_count)
		var y := clampf((1.0 - 2.0 * t) * 0.86, -0.86, 0.86)
		var across := sqrt(maxf(0.0, 1.0 - y * y))
		var angle := float(i) * 2.399963 + spin
		centers.append(Vector3(across * cos(angle), y, across * sin(angle)).normalized())
	for round_index in 6:
		for i in plate_count:
			var push := Vector3.ZERO
			for k in plate_count:
				if k == i:
					continue
				var away: Vector3 = centers[i] - centers[k]
				var d := maxf(away.length(), 0.001)
				push += away / d * maxf(0.0, 0.62 - d)
			centers[i] = _away_from_poles(centers[i] + push * 0.5, 0.86)
	# Which plates carry continental crust: spread by farthest point, not drawn
	# blind. Two nuclei that happened to land side by side would weld into one
	# template supercontinent along the whole shared boundary. Weights and drift
	# still make them unequal, and two nuclei may still meet across a boundary.
	var chosen: Array[int] = []
	while chosen.size() < mini(count, plate_count):
		var best := -1
		var best_score := -INF
		for i in plate_count:
			if i in chosen:
				continue
			var clearance := 1.0
			if not chosen.is_empty():
				clearance = TAU
				for c in chosen:
					clearance = minf(clearance, centers[i].angle_to(centers[c]))
			var score := clearance * rng.randf_range(0.70, 1.30)
			if score > best_score:
				best_score = score
				best = i
		chosen.append(best)
	var cont_set := {}
	for k in chosen.size():
		cont_set[chosen[k]] = k
	var plates: Array = []
	var terranes: Array = []
	var basins: Array = []
	# A weld: a narrow isthmus that joins two continents where their plates
	# converge, the way India meets Asia. Only one per world, so continents
	# stay separate masses and are joined only by a land bridge. That same
	# pair is the world's suture: their terranes may meet at the seam and raise
	# a fold belt, while every other continental boundary keeps its sea.
	var welds: Array = []
	var sutures := {}
	# Nothing may be thinner than a few map points: a sub-point fragment is a
	# speck of noise, not an island. The same world at another resolution keeps
	# its geography, not its aliasing.
	var grain := TAU / float(size.x)
	var smallest := maxf(0.03, grain * 2.6)
	for i in plate_count:
		var center := centers[i]
		var side := Vector3.UP.cross(center)
		if side.length() < 0.01:
			side = Vector3.RIGHT
		side = side.normalized()
		var up := center.cross(side).normalized()
		var v_ang := rng.randf_range(0.0, TAU)
		var vel := (side * cos(v_ang) + up * sin(v_ang)).normalized() * rng.randf_range(0.45, 1.35)
		var is_cont := cont_set.has(i)
		# Continental plates are large and of comparable extent: they carry the
		# cratons, shelves and the room for terranes to accrete, while ocean
		# plates are smaller and may differ in size. Without that contrast the
		# continental domains cannot hold more crust than the sea will leave
		# dry, and every coast would sit on the edge of its own cell.
		var weight := rng.randf_range(1.22, 1.42) if is_cont else rng.randf_range(0.62, 0.92)
		var buoyancy := rng.randf_range(0.32, 0.68) if is_cont else rng.randf_range(-0.62, -0.26)
		plates.append({
			"at": center, "vel": vel, "weight": weight,
			"cont": is_cont, "buoyancy": buoyancy,
		})
		if not is_cont:
			continue
		# A continent is a chain of accreted terranes, not a blob: a shield at
		# the nucleus, then an arc of smaller terranes welded onto it in the
		# direction the plate drifts, with spurs and a tapered end. Terranes
		# overlap a little (an isthmus) or a lot (one mass) and leave bays
		# between the arms; how they meet is the plate's history, not a template.
		var rank: int = cont_set[i]
		# One continent may dominate, but not swallow the world: areas stay
		# within about a factor of two, as Eurasia, Africa and the Americas do.
		var scale := rng.randf_range(0.95, 1.12) if rank == 0 else rng.randf_range(0.72, 1.05)
		var reach := rng.randf_range(0.30, 0.44) * scale
		var thick := rng.randf_range(0.55, 0.95)
		terranes.append(_terrane(rng, center, reach, thick, rng.randi_range(6, 9), i, vel))
		var tang: Vector3 = vel.normalized()
		tang = (tang - center * center.dot(tang)).normalized()
		# Some continents grew along a steady drift and are long and narrow;
		# others turned with every collision and stayed compact. The world
		# needs both, or every landmass is the same blob in a new place.
		var turning := rng.randf_range(-0.6, 0.6)
		var meander := rng.randf_range(0.22, 1.05)
		var at := center
		var steps := rng.randi_range(4, 7)
		for s in steps:
			turning += rng.randf_range(-meander, meander)
			var step_dir := (tang * cos(turning) + center.cross(tang).normalized() * sin(turning)).normalized()
			var step_len := reach * rng.randf_range(0.85, 1.22)
			at = _away_from_poles(at * cos(step_len) + step_dir * sin(step_len), 0.80)
			reach = reach * rng.randf_range(0.88, 1.0)
			if s == steps - 1:
				reach *= 0.85
			thick = clampf(thick * rng.randf_range(0.86, 1.04), 0.35, 1.1)
			terranes.append(_terrane(rng, at, maxf(smallest, reach), thick, rng.randi_range(5, 8), i, step_dir))
		# Spurs: peninsulas and horn-like projections off the main chain.
		for b in rng.randi_range(2, 4):
			var anchor: Vector3 = terranes[terranes.size() - 1 - rng.randi_range(0, mini(steps, 2))]["at"]
			var spur_dir := (side * cos(rng.randf() * TAU) + up * sin(rng.randf() * TAU)).normalized()
			spur_dir = (spur_dir - anchor * anchor.dot(spur_dir)).normalized()
			var spur_len := reach * rng.randf_range(1.0, 1.9)
			var tip := _away_from_poles(anchor * cos(spur_len) + spur_dir * sin(spur_len), 0.82)
			terranes.append(_terrane(rng, tip, maxf(smallest * 0.8, reach * rng.randf_range(0.42, 0.66)), thick * 0.75, rng.randi_range(4, 6), i, spur_dir))
		# Epicontinental seas and rift troughs: a hole in the shield, so a
		# continent can have an inland sea instead of being solid all through.
		for m in rng.randi_range(1, 2):
			var anchor: Vector3 = terranes[terranes.size() - 3 - rng.randi_range(0, mini(2, steps))]["at"]
			var hole_dir := (side * cos(rng.randf() * TAU) + up * sin(rng.randf() * TAU)).normalized()
			hole_dir = (hole_dir - anchor * anchor.dot(hole_dir)).normalized()
			# The sea opens toward the margin often: a gulf or a sound rather
			# than a perfectly closed ring of land around a round hole.
			var off := reach * rng.randf_range(0.45, 1.05)
			var hole := _away_from_poles(anchor * cos(off) + hole_dir * sin(off), 0.80)
			basins.append(_terrane(rng, hole, reach * rng.randf_range(0.34, 0.62),
				rng.randf_range(0.30, 0.55), rng.randi_range(5, 7), i, hole_dir))
	# Where two continental plates converge, a narrow isthmus may weld them into
	# one landmass (India to Asia). It is the only place two continents touch;
	# otherwise every continent keeps its own coast and its own history.
	for i in plates.size():
		if not bool(plates[i]["cont"]):
			continue
		for k in range(i + 1, plates.size()):
			if not bool(plates[k]["cont"]):
				continue
			var gap: Vector3 = plates[k]["at"] - plates[i]["at"]
			var angle: float = plates[i]["at"].angle_to(plates[k]["at"])
			var closing: float = (plates[i]["vel"] - plates[k]["vel"]).dot(gap)
			if welds.size() > 0 or angle > 1.5 or angle < 0.45 or closing <= 0.30 or rng.randf() > 0.35:
				continue
			var at: Vector3 = (plates[i]["at"] + plates[k]["at"]).normalized()
			sutures[Vector2i(mini(i, k), maxi(i, k))] = true
			# The isthmus runs from one continent toward the other, across the
			# suture between them, not along the boundary.
			var tang: Vector3 = (plates[k]["at"] - plates[i]["at"])
			tang = (tang - at * at.dot(tang)).normalized()
			var length := rng.randf_range(0.20, 0.36) * mini(1.4, angle)
			var a: Vector3 = (at * cos(length * 0.5) - tang * sin(length * 0.5)).normalized()
			var b: Vector3 = (at * cos(length * 0.5) + tang * sin(length * 0.5)).normalized()
			var beads := maxi(3, roundi(length / maxf(smallest, 0.05)))
			for step in beads:
				var along := (float(step) + 0.5) / float(beads)
				welds.append({
					"at": (a * cos(length * along) + tang * sin(length * along)).normalized(),
					"radius": smallest * rng.randf_range(0.85, 1.15),
				})
	# Island arcs: along a subduction margin, a line of volcanic isles, not a
	# dotted line. Each isle is its own small terrane with a gap to the next, so
	# an arc is a chain of islands the player can sail between.
	for a_idx in isles:
		var ocean: Array[int] = []
		for i in plates.size():
			if not bool(plates[i]["cont"]):
				ocean.append(i)
		if ocean.is_empty():
			break
		var source: int = ocean[a_idx % ocean.size()]
		var nearest := -1
		var distance := INF
		for i in plates.size():
			if i == source:
				continue
			var delta: Vector3 = plates[i]["at"] - plates[source]["at"]
			var velocity: Vector3 = plates[source]["vel"] - plates[i]["vel"]
			var angle: float = plates[source]["at"].angle_to(plates[i]["at"])
			if velocity.dot(delta) > 0.0 and angle < distance:
				nearest = i
				distance = angle
		if nearest < 0:
			continue
		var start: Vector3 = (plates[source]["at"] + plates[nearest]["at"]).normalized()
		var tang: Vector3 = plates[source]["at"].cross(plates[nearest]["at"]).normalized()
		var arc_len := rng.randf_range(0.10, 0.20)
		var beads := rng.randi_range(4, 9)
		var bead := maxf(smallest, arc_len / float(beads) * rng.randf_range(0.45, 0.75))
		for k in beads:
			var along := (float(k) + 0.5) / float(beads) * arc_len
			var at := (start * cos(along) + tang * sin(along)).normalized()
			if rng.randf() < 0.18:
				continue
			terranes.append(_terrane(rng, at, bead * rng.randf_range(0.8, 1.6),
				rng.randf_range(0.45, 0.85), rng.randi_range(4, 6), source, tang))
		# A rifted microcontinent beside the arc, a fragment left behind.
		var off := start.cross(tang).normalized() * rng.randf_range(0.06, 0.12)
		var fragment := (start + off).normalized()
		terranes.append(_terrane(rng, fragment, maxf(smallest, rng.randf_range(0.035, 0.06)),
			rng.randf_range(0.55, 0.95), rng.randi_range(5, 7), source))
	var model := {
		"plates": plates, "terranes": terranes, "basins": basins,
		"welds": welds, "sutures": sutures, "sea_level": 0.0,
	}
	# Continental crust budget: the preset's land share has to come from
	# terranes, not from bare plate showing through the water. Each continent
	# gets its own share of that budget, so a long random walk cannot swallow
	# the world: sizes vary by about a factor of two, as Earth's do.
	var cont: Array[int] = []
	var mass_sum := 0.0
	for i in plates.size():
		if not bool(plates[i]["cont"]):
			continue
		cont.append(i)
		var mass := 1.0 if int(cont_set[i]) == 0 else rng.randf_range(0.62, 1.05)
		plates[i]["mass"] = mass
		mass_sum += mass
	var goal := clampf(share * 1.32, 0.10, 0.64)
	for attempt in 3:
		var covered := 0.0
		for i in cont:
			covered += _terrane_coverage(model, {i: true}, 24, warp, coast)
		if absf(covered - goal) <= 0.025 or mass_sum <= 0.0:
			break
		for i in cont:
			var covered_i := _terrane_coverage(model, {i: true}, 24, warp, coast)
			var target_i := goal * float(plates[i]["mass"]) / mass_sum
			var factor := clampf(sqrt(target_i / maxf(covered_i, 0.003)), 0.72, 1.45)
			for t: Dictionary in terranes:
				if int(t["plate"]) == i:
					_rescale_terrane(t, factor)
	# Calibrate sea_level on a spherical grid sample so the planet's land share
	# matches `share` closely regardless of how plates merged or rifted.
	var stride := maxi(1, mini(size.x, size.y) / 64)
	var vals: Array[float] = []
	for y in range(0, size.y, stride):
		for x in range(0, size.x, stride):
			var p := _on_sphere(x, y, size)
			vals.append(_tectonic_relief(model, p, warp, coast, fine).x / 0.62)
	vals.sort()
	if not vals.is_empty():
		var target_idx := clampi(int(round((1.0 - share) * float(vals.size() - 1))), 0, vals.size() - 1)
		model["sea_level"] = vals[target_idx]
	return model


## Keep a terrane off the poles: a continent centred on a pole becomes a cap
## that spans every longitude, and an equirectangular map then shows one band
## of land welding the whole world together.
static func _away_from_poles(at: Vector3, limit: float) -> Vector3:
	if absf(at.y) <= limit:
		return at.normalized()
	return Vector3(at.x, signf(at.y) * limit, at.z).normalized()


## One accreted terrane: a convex spherical polygon, not a disc. Its rim is a
## set of great-circle chords between vertices at uneven radii, so the same
## terrane in two seeds is not the same shape; the domain warp later bends the
## chords into coasts, bays and headlands.
static func _terrane(rng: RandomNumberGenerator, center: Vector3, reach: float, thickness: float, sides: int, plate: int, along: Vector3 = Vector3.ZERO) -> Dictionary:
	var side := Vector3.UP.cross(center)
	if side.length() < 0.01:
		side = Vector3.RIGHT
	side = side.normalized()
	var up := center.cross(side).normalized()
	# Terranes accrete elongated: along the direction they were carried, not as
	# discs. The major axis follows the plate's drift or the chain's step.
	var base := rng.randf_range(0.0, TAU)
	if along.length_squared() > 1e-6:
		var flat_along := (along - center * center.dot(along))
		if flat_along.length_squared() > 1e-6:
			base = atan2(flat_along.dot(up), flat_along.dot(side))
	# Vertices on a wandering, stretched circle: an uneven radius per vertex
	# makes bays and headlands, the stretch makes an elongated terrane rather
	# than a blob, and a random lobe is where an arc welded on.
	var points: Array[Vector3] = []
	var far := 0.02
	var stretch := rng.randf_range(0.40, 0.78)
	var lean := rng.randf_range(0.0, 0.35)
	for k in sides:
		var angle := base + TAU * (float(k) + rng.randf_range(-0.30, 0.30)) / float(sides)
		var along_axis := absf(cos(angle - base - lean))
		var radius := reach * (stretch + (1.18 - stretch) * pow(along_axis, 0.8)) * rng.randf_range(0.90, 1.06)
		var direction := (side * cos(angle) + up * sin(angle)).normalized()
		var vertex := (center * cos(radius) + direction * sin(radius)).normalized()
		var flat := clampf(vertex.y, -0.90, 0.90)
		if absf(vertex.y) > 0.90:
			vertex = Vector3(vertex.x, flat, vertex.z).normalized()
		points.append(vertex)
		far = maxf(far, radius)
	var body := _terrane_edges(center, points)
	body["at"] = center
	body["cos"] = cos(minf(far * 1.15, PI * 0.95))
	body["thickness"] = thickness
	body["plate"] = plate
	return body


## Edge planes of a convex spherical polygon: the interior is where every
## edge's outward normal points away from the centre, so the coast is a real
## rim and the centre is strictly inside.
static func _terrane_edges(center: Vector3, points: Array[Vector3]) -> Dictionary:
	var normals: Array[Vector3] = []
	for k in points.size():
		var a := points[k]
		var b := points[(k + 1) % points.size()]
		var normal := a.cross(b)
		if normal.length_squared() < 1e-8:
			normal = center
		normal = normal.normalized()
		if normal.dot(center) < 0.0:
			normal = -normal
		normals.append(normal)
	return {"normals": normals, "points": points}


## Resize a terrane about its own centre, keeping the accreton shape. The
## continent's crust budget is set by the preset, its outline by its history.
static func _rescale_terrane(t: Dictionary, factor: float) -> void:
	var center: Vector3 = t["at"]
	var points: Array[Vector3] = t["points"]
	var scaled: Array[Vector3] = []
	for v in points:
		var theta := center.angle_to(v) * factor
		var dir := v - center * center.dot(v)
		dir = dir.normalized() if dir.length_squared() > 1e-10 else Vector3.UP
		var p := (center * cos(theta) + dir * sin(theta)).normalized()
		if absf(p.y) > 0.90:
			p = Vector3(p.x, signf(p.y) * 0.90, p.z).normalized()
		scaled.append(p)
	var body := _terrane_edges(center, scaled)
	t["normals"] = body["normals"]
	t["points"] = scaled
	var far := 0.02
	for v in scaled:
		far = maxf(far, center.angle_to(v))
	t["cos"] = cos(minf(far * 1.15, PI * 0.95))


## Effective terrane cover at q: the fraction of a terrane the point lies in,
## after the plate-domain rules that cut continents at their own coasts. Shared
## by the relief field and the crust budget so both measure one geography.
static func _terrane_cover(shape: Dictionary, q: Vector3, p1: int, p2: int, d1: float, convergence: float, only: Dictionary = {}) -> Vector2:
	var plates: Array = shape["plates"]
	var pl1: Dictionary = plates[p1]
	var pl2: Dictionary = plates[p2]
	var cover := 0.0
	var cover_thick := 0.0
	var terranes: Array = shape["terranes"]
	for t: Dictionary in terranes:
		if not only.is_empty() and not only.has(int(t["plate"])):
			continue
		if q.dot(t["at"]) < float(t["cos"]):
			continue
		# Margin is an angle: how far inside this terrane's rim the point lies.
		# Angular measure keeps the coastline soft at every terrane size.
		var margin := 1.0
		var normals: Array = t["normals"]
		for k in normals.size():
			margin = minf(margin, q.dot(normals[k]))
			if margin < -0.05:
				break
		if margin < -0.05:
			continue
		var inside := smoothstep(-0.05, 0.02, margin)
		# The terrane is cut where its plate ends: a continent keeps its own
		# coast rather than spilling into the next ocean plate. On a passive
		# margin the two shores also keep a shelf between them. The exception is
		# a collision suture: the one continental boundary this world chose to
		# close, where both margins reach the seam and a fold belt rises.
		var owner := int(t["plate"])
		var home := q.angle_to(plates[owner]["at"]) / float(plates[owner]["weight"])
		var welded := false
		if (owner == p1 or owner == p2) and bool(plates[owner]["cont"]) \
				and bool(pl1["cont"]) and bool(pl2["cont"]) and convergence > 0.35:
			var partner := p1 if owner == p2 else p2
			var sutures: Dictionary = shape.get("sutures", {})
			welded = sutures.has(Vector2i(mini(owner, partner), maxi(owner, partner)))
		if not welded:
			var clearance := INF
			for k in plates.size():
				if k == owner or not bool(plates[k]["cont"]):
					continue
				clearance = minf(clearance, q.angle_to(plates[k]["at"]) / float(plates[k]["weight"]) - home)
			if clearance < 0.07:
				inside *= smoothstep(0.0, 0.07, clearance)
			# The terrane owns its own domain and reaches the boundary, but
			# fades as soon as the point is nearer another plate: a continent
			# keeps its own coast instead of spilling into the next ocean.
			if owner != p1:
				inside *= 1.0 - smoothstep(0.0, 0.035, home - d1)
		if inside > cover:
			cover = inside
			cover_thick = float(t["thickness"])
	return Vector2(cover, cover_thick)


## Effective continental area of the sphere, measured through the same plate
## rules as the relief. A preset's land share is budgeted against this, not
## against raw polygon area, so bare shelf never becomes land.
static func _terrane_coverage(shape: Dictionary, only: Dictionary, samples: int, warp: FastNoiseLite, coast: FastNoiseLite) -> float:
	var plates: Array = shape["plates"]
	var hits := 0
	var total := 0
	var rows := maxi(8, samples)
	var cols := rows * 2
	for iy in rows:
		var lat := ((float(iy) + 0.5) / float(rows) - 0.5) * PI
		for ix in cols:
			var lon := (float(ix) + 0.5) / float(cols) * TAU
			var at := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			total += 1
			# Measure the same warped sphere the relief field is sampled on: a
			# boundary displaced by the domain warp moves the continent with it.
			var wx := warp.get_noise_3d(at.x * 2.1 + 11.3, at.y * 2.1 - 7.1, at.z * 2.1 + 3.7)
			var wy := warp.get_noise_3d(at.x * 2.1 - 5.9, at.y * 2.1 + 13.7, at.z * 2.1 - 9.2)
			var wz := warp.get_noise_3d(at.x * 2.1 + 17.1, at.y * 2.1 + 4.3, at.z * 2.1 + 8.9)
			var fx := coast.get_noise_3d(at.x * 5.2 - 3.1, at.y * 5.2 + 8.4, at.z * 5.2 - 6.7)
			var fy := coast.get_noise_3d(at.x * 5.2 + 9.6, at.y * 5.2 - 4.8, at.z * 5.2 + 2.5)
			var fz := coast.get_noise_3d(at.x * 5.2 - 7.3, at.y * 5.2 - 2.9, at.z * 5.2 + 12.1)
			var q := (at + Vector3(wx, wy, wz) * 0.24 + Vector3(fx, fy, fz) * 0.085).normalized()
			var p1 := 0
			var p2 := 1
			var d1 := INF
			var d2 := INF
			var d3 := INF
			for k in plates.size():
				var d: float = q.angle_to(plates[k]["at"]) / float(plates[k]["weight"])
				if d < d1:
					d3 = d2
					d2 = d1
					p2 = p1
					d1 = d
					p1 = k
				elif d < d2:
					d3 = d2
					d2 = d
					p2 = k
				elif d < d3:
					d3 = d
			var pl1: Dictionary = plates[p1]
			var pl2: Dictionary = plates[p2]
			var gap := clampf((d2 - d1) / 0.24, 0.0, 1.0)
			var prox := (1.0 - smoothstep(0.0, 1.0, gap)) * smoothstep(0.0, 0.09, d3 - d2)
			var dir: Vector3 = pl2["at"] - pl1["at"]
			if dir.length_squared() > 0.0001:
				dir = dir.normalized()
			var stress := clampf((pl1["vel"] - pl2["vel"]).dot(dir), -1.2, 1.2)
			var convergence := maxf(stress, 0.0) * prox
			if _terrane_cover(shape, q, p1, p2, d1, convergence, only).x > 0.5:
				hits += 1
	return float(hits) / float(total)


## Evaluates crustal elevation (x), convergent mountain belt intensity (y), and
## divergent rift intensity (z) at a point on the unit sphere.
static func _tectonic_relief(shape: Dictionary, at: Vector3, warp: FastNoiseLite, coast: FastNoiseLite, fine: FastNoiseLite) -> Vector3:
	# Multi-scale spherical domain warp: deforms plate boundaries and spines so
	# no line is a raw geometric arc or circle.
	var wx := warp.get_noise_3d(at.x * 2.1 + 11.3, at.y * 2.1 - 7.1, at.z * 2.1 + 3.7)
	var wy := warp.get_noise_3d(at.x * 2.1 - 5.9, at.y * 2.1 + 13.7, at.z * 2.1 - 9.2)
	var wz := warp.get_noise_3d(at.x * 2.1 + 17.1, at.y * 2.1 + 4.3, at.z * 2.1 + 8.9)
	var fx := coast.get_noise_3d(at.x * 5.2 - 3.1, at.y * 5.2 + 8.4, at.z * 5.2 - 6.7)
	var fy := coast.get_noise_3d(at.x * 5.2 + 9.6, at.y * 5.2 - 4.8, at.z * 5.2 + 2.5)
	var fz := coast.get_noise_3d(at.x * 5.2 - 7.3, at.y * 5.2 - 2.9, at.z * 5.2 + 12.1)
	var q := (at + Vector3(wx, wy, wz) * 0.24 + Vector3(fx, fy, fz) * 0.085).normalized()
	# Find the two nearest lithospheric plates in warped spherical space.
	var plates: Array = shape["plates"]
	var p1 := 0
	var p2 := 1
	var d1 := INF
	var d2 := INF
	var d3 := INF
	for i in plates.size():
		var pl: Dictionary = plates[i]
		var d := q.angle_to(pl["at"]) / float(pl["weight"])
		if d < d1:
			d3 = d2
			d2 = d1
			p2 = p1
			d1 = d
			p1 = i
		elif d < d2:
			d3 = d2
			d2 = d
			p2 = i
		elif d < d3:
			d3 = d
	# Blend all nearby domains, not only the runner-up: changing the second
	# nearest plate at a Voronoi vertex must not cut a straight crack in the sea.
	var buoyancy_sum := 0.0
	var buoyancy_weight := 0.0
	for pl: Dictionary in plates:
		var distance := q.angle_to(pl["at"]) / float(pl["weight"])
		var blend := exp(-(distance - d1) * 13.0)
		buoyancy_sum += float(pl["buoyancy"]) * blend
		buoyancy_weight += blend
	var pl1: Dictionary = plates[p1]
	var pl2: Dictionary = plates[p2]
	var boundary_gap := clampf((d2 - d1) / 0.24, 0.0, 1.0)
	var boundary_prox := (1.0 - smoothstep(0.0, 1.0, boundary_gap)) * smoothstep(0.0, 0.09, d3 - d2)
	# Relative plate motion across the boundary: positive = convergence (collision /
	# subduction), negative = divergence (rift valley / mid-ocean ridge / strait).
	var dir_12: Vector3 = (pl2["at"] - pl1["at"])
	if dir_12.length_squared() > 0.0001:
		dir_12 = dir_12.normalized()
	var rel_vel: Vector3 = pl1["vel"] - pl2["vel"]
	var stress := clampf(rel_vel.dot(dir_12), -1.2, 1.2)
	var convergence := maxf(stress, 0.0) * boundary_prox
	var divergence := maxf(-stress, 0.0) * boundary_prox
	# Base plate crustal buoyancy, smoothly transitioning across plate boundaries.
	var plate_base := buoyancy_sum / buoyancy_weight
	# Accreted terranes: each is a convex polygon on the sphere, and the coast
	# is where their union crosses sea level. The same helper is used by the
	# crust budget, so the land the preset asks for is the land the relief
	# actually delivers.
	var gained := _terrane_cover(shape, q, p1, p2, d1, convergence)
	var cover: float = gained.x
	var cover_thick: float = gained.y
	var trough_cut := 0.0
	for b: Dictionary in shape["basins"]:
		if q.dot(b["at"]) < float(b["cos"]):
			continue
		var margin := 1.0
		var normals: Array = b["normals"]
		for k in normals.size():
			margin = minf(margin, q.dot(normals[k]))
		trough_cut = maxf(trough_cut, smoothstep(-0.03, 0.03, margin) * float(b["thickness"]))
	# Combine plate interior crust with the terranes welded onto it. The plate
	# itself sits below sea level even where it is continental — it is shelf and
	# craton root, not a landmass. Land exists only where terranes were welded
	# on, so a continent's area follows its accretion history, not its plate.
	var crust := cover * (0.78 + 0.30 * cover_thick + plate_base * 0.05)
	# Tectonic boundary effects:
	# - Continent-continent convergence welds land into a suture with high fold mountains.
	# - Continent-ocean convergence raises a coastal cordillera or volcanic island arc
	#   along the margin and deepens an offshore trench.
	# - Divergence opens rift valleys, narrow seas (Red Sea), or ocean straits.
	var both_cont := bool(pl1["cont"]) and bool(pl2["cont"])
	var one_cont := bool(pl1["cont"]) != bool(pl2["cont"])
	var orogeny := 0.0
	var rift := 0.0
	# The two sides agree at the boundary itself. Otherwise a change from
	# overriding to subducting side produces a one-cell straight coastline.
	convergence *= smoothstep(0.0, 0.10, boundary_gap)
	divergence *= smoothstep(0.0, 0.10, boundary_gap)
	if both_cont:
		if convergence > 0.0:
			crust += convergence * 0.26 * cover
			orogeny = convergence * 1.15 * cover
		if divergence > 0.0:
			crust -= divergence * 0.38 * cover
			rift = divergence * 1.1 * cover
	elif one_cont:
		if convergence > 0.0:
			if bool(pl1["cont"]):
				var margin_band := smoothstep(0.0, 0.25, boundary_gap) * (1.0 - smoothstep(0.25, 0.85, boundary_gap))
				crust += margin_band * convergence * 0.22 * cover
				orogeny = margin_band * convergence * 1.1 * cover
			else:
				# Subduction island arc just off the trench. It rides on the
				# shelf, so it never becomes a ridge of bare ocean floor.
				var arc_band := smoothstep(0.02, 0.18, boundary_gap) * (1.0 - smoothstep(0.18, 0.48, boundary_gap))
				var bead := fine.get_noise_3d(at.x * 14.0, at.y * 14.0, at.z * 14.0)
				crust += (arc_band * convergence * (0.28 + 0.25 * bead) - convergence * (1.0 - smoothstep(0.0, 0.18, boundary_gap)) * 0.22) * cover
				orogeny = arc_band * convergence * 0.75 * cover
		if divergence > 0.0:
			crust -= divergence * 0.30
			rift = divergence * 0.85
	else:
		# Mid-ocean ridges and arcs only modify crust that exists: no boundary
		# process may lift bare ocean floor above the sea.
		crust += divergence * 0.24 * cover
		if convergence > 0.0:
			var bead := fine.get_noise_3d(at.x * 16.0, at.y * 16.0, at.z * 16.0)
			var arc_band := smoothstep(0.0, 0.15, boundary_gap) * (1.0 - smoothstep(0.15, 0.38, boundary_gap))
			crust += arc_band * convergence * (0.35 + 0.32 * bead) * cover
	# Ancient sutures inside a continent: the seams where terranes met are
	# fold belts, so the relief remembers the accretion history.
	if cover > 0.15:
		var seam := cover * (1.0 - cover) * 4.0
		orogeny = maxf(orogeny, seam * 0.55)
	# Carve epicontinental seas, gulfs and rift troughs.
	crust -= trough_cut
	# Welds: a low isthmus of land joining two converging continents, rising
	# just above sea level along its narrow chain of beads.
	for weld: Dictionary in shape["welds"]:
		var d := q.angle_to(weld["at"])
		var reach := float(weld["radius"])
		if d < reach * 2.2:
			crust = maxf(crust, float(shape["sea_level"]) + 0.10 * (1.0 - d / (reach * 2.2)))
	# Multi-scale coastal and structural detail (fjords, bays, headlands, peninsulas).
	# Every scale rides on the terrane cover, so inland is rough and the open
	# ocean is smooth: detailed noise may sharpen a coast, never seed an islet.
	var medium_n := coast.get_noise_3d(q.x * 3.4, q.y * 3.4, q.z * 3.4)
	var fine_n := fine.get_noise_3d(at.x * 8.5, at.y * 8.5, at.z * 8.5)
	var micro_n := fine.get_noise_3d(at.x * 18.0, at.y * 18.0, at.z * 18.0)
	crust += cover * (medium_n * 0.14 + fine_n * 0.045 + micro_n * 0.010)
	# The poles are oceanic. A polar land cap wraps every longitude into one
	# band on an equirectangular map and welds continents that only touch near
	# the pole, so both caps sit under a polar sea. This is a global ocean, not
	# a map-edge cut: the same rule applies on the globe and in every view.
	crust -= smoothstep(0.965, 0.998, absf(at.y)) * 1.6
	var h := (crust - float(shape["sea_level"])) * 0.62
	return Vector3(clampf(h, -1.0, 1.0), clampf(orogeny, 0.0, 1.0), clampf(rift, 0.0, 1.0))


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
