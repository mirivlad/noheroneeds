class_name WorldPlan
extends RefCounted
## A generated, serializable coarse map. Coordinates are coarse points, each
## representing STEP surface cells. The packed fields are the authority, not
## a recipe to re-run when a world is opened.

const FORMAT := 1
const STEP := Chunk.SIZE
const PRESETS := {
	"single_continent": Vector2i(160, 160),
	"small": Vector2i(160, 80),
	"medium": Vector2i(256, 128),
	"large": Vector2i(384, 192),
	"huge": Vector2i(512, 256),
}
const CLIMATES := ["hot", "temperate", "cold"]

var seed_value := 0
var preset := ""
var climate := ""
var size := Vector2i.ZERO
## Three bytes per point: height, warmth and rainfall, encoded from -1..1.
var fields := PackedByteArray()
var spawn := Vector2i.ZERO


static func generate(seed_number: int, size_preset: String, climate_preset: String) -> WorldPlan:
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
	var moisture := FastNoiseLite.new()
	moisture.seed = seed_number + 1013
	moisture.frequency = 1.0
	moisture.fractal_octaves = 3
	var shift := 0.3 if climate_preset == "hot" else (-0.3 if climate_preset == "cold" else 0.0)
	var best := -INF
	for y in plan.size.y:
		for x in plan.size.x:
			var u := (float(x) + 0.5) / plan.size.x
			var v := (float(y) + 0.5) / plan.size.y
			var h: float
			var wet: float
			if size_preset == "single_continent":
				var p := Vector2((u - 0.5) * 2.0, (v - 0.5) * 2.0)
				var distance := p.length()
				var angle := atan2(p.y, p.x)
				# A radius for every direction keeps all land connected to the centre.
				var coast := 0.65 + land.get_noise_2d(cos(angle) * 2.0, sin(angle) * 2.0) * 0.2
				h = (coast - distance) * 0.55
				wet = moisture.get_noise_2d(u * 4.0, v * 4.0)
			else:
				# Spherical sampling joins longitude at the seam and converges at the poles.
				var lon := u * TAU
				var lat := (v - 0.5) * PI
				var p := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
				var scale := float(plan.size.x) / 80.0
				h = land.get_noise_3d(p.x * scale, p.y * scale, p.z * scale) * 0.8 + 0.015
				wet = moisture.get_noise_3d(p.x * scale, p.y * scale, p.z * scale)
			var latitude := absf(v - 0.5) * 2.0
			var warmth := clampf(0.85 - latitude * 1.8 + shift - maxf(h, 0.0) * 0.6, -1.0, 1.0)
			var rain := clampf(wet * 1.2 - maxf(shift, 0.0) * 0.35, -1.0, 1.0)
			var idx := (y * plan.size.x + x) * 3
			plan.fields[idx] = _encode(h)
			plan.fields[idx + 1] = _encode(warmth)
			plan.fields[idx + 2] = _encode(rain)
			if h > 0.08:
				var score := -absf(warmth - 0.1) - absf(rain) * 0.3 - absf(h - 0.12) - absf(v - 0.5) * 0.2
				if score > best:
					best = score
					plan.spawn = Vector2i(x, y)
	return plan


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
	return {"format": FORMAT, "seed": seed_value, "type": "single_continent" if preset == "single_continent" else "planet",
		"preset": preset, "climate": climate,
		"width": size.x, "height": size.y, "spawn_x": spawn.x, "spawn_y": spawn.y,
		"fields": Marshalls.raw_to_base64(fields)}


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
	var at := Vector2i(int(data.get("spawn_x", -1)), int(data.get("spawn_y", -1)))
	if at.x < 0 or at.y < 0 or at.x >= dimensions.x or at.y >= dimensions.y:
		return null
	var plan := WorldPlan.new()
	plan.seed_value = int(data.get("seed", 0))
	plan.preset = preset_id
	plan.climate = climate_id
	plan.size = dimensions
	plan.fields = bytes
	plan.spawn = at
	return plan
