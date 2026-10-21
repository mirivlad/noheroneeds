class_name Weather
## Weather of a world's surface (ADR-0033, ADR-0055): a function of its
## weather seed, the world's time, the place and the place's climate — the
## server and every client work it out alike, nothing is stored or sent
## while it changes. A slow "wetness" drifts between knots every KNOT_HOURS,
## each area of FRONT cells on its own and the areas blended into each other
## (fronts pass over the land): high, clouds gather and it rains (now and
## then a storm); a middling one on a morning is fog; low, clear sky. A wet
## climate (by the sea, on the windward side) rains more, a dry one less;
## where it freezes (winter, the north, the heights) it snows instead.
##
## place: a world cell; climate: Vector2(warmth, rain), -1..1 each, of the
## place (Geography.climate_at; zero — a mild middling place).

const KNOT_HOURS := 6.0
## Cells across an area of weather.
const FRONT := 512
## Wetness above which clouds start, and where rain starts and is full.
const CLOUDS_FROM := 0.45
const RAIN_FROM := 0.66
const RAIN_FULL := 0.8
## A rainy knot is stormy past this (its own roll).
const STORM_FROM := 0.65
## How much a place's rain (its climate) makes its air wetter or drier.
const WET_CLIMATE := 0.12

## Rain hours from world time 0 to each whole game hour, by seed, area and
## climate (a cache: crops ask how much it rained since they were sown).
static var _rain_sums := {}


## 0..1, smooth over time and over the land: how wet the air is.
static func wetness(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	var px := float(place.x) / FRONT
	var py := float(place.y) / FRONT
	var ax := floori(px)
	var ay := floori(py)
	var fx := px - ax
	var fy := py - ay
	var top := lerpf(_area(seed, time_ms, ax, ay), _area(seed, time_ms, ax + 1, ay), fx)
	var bottom := lerpf(_area(seed, time_ms, ax, ay + 1), _area(seed, time_ms, ax + 1, ay + 1), fx)
	return lerpf(top, bottom, fy) + Seasons.wetter(time_ms) + WET_CLIMATE * climate.y


## An area's own wetness now, between its knots. Kept for the moment asked
## about: a tick asks about the same few areas many times (every creature
## looking about).
static var _areas_at := -1.0
static var _areas_seed := 0
static var _areas := {}


static func _area(seed: int, time_ms: float, ax: int, ay: int) -> float:
	if time_ms != _areas_at or seed != _areas_seed:
		_areas_at = time_ms
		_areas_seed = seed
		_areas.clear()
	var key := Vector2i(ax, ay)
	var known: Variant = _areas.get(key)
	if known != null:
		return known
	var k := time_ms / (KNOT_HOURS * Daylight.HOUR_MS)
	var i := floori(k)
	var f := k - i
	f = f * f * (3.0 - 2.0 * f)
	var s := hash([seed, ax, ay])
	var v := lerpf(_roll(s, i), _roll(s, i + 1), f)
	_areas[key] = v
	return v


## How hard it rains or snows now, 0..1.
static func precipitation(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	return clampf((wetness(seed, time_ms, place, climate) - RAIN_FROM) / (RAIN_FULL - RAIN_FROM), 0.0, 1.0)


## How hard it rains now, 0..1 (where it freezes it snows instead, ADR-0036).
static func rain(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	return 0.0 if Seasons.freezing(time_ms, climate.x) else precipitation(seed, time_ms, place, climate)


## How hard it snows now, 0..1.
static func snow(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	return precipitation(seed, time_ms, place, climate) if Seasons.freezing(time_ms, climate.x) else 0.0


## How overcast the sky is, 0..1 (rain is overcast too).
static func clouds(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	return clampf((wetness(seed, time_ms, place, climate) - CLOUDS_FROM) / (RAIN_FROM - CLOUDS_FROM), 0.0, 1.0)


## Morning fog, 0..1: a middling wetness between four and ten.
static func fog(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	var h := Daylight.hour_of(time_ms)
	if h < 4.0 or h > 10.0:
		return 0.0
	var by_hour := 1.0 - absf(h - 6.5) / 3.5
	var w := wetness(seed, time_ms, place, climate)
	var by_wet := 1.0 - absf(w - 0.55) / 0.1
	return clampf(minf(by_hour * 1.5, by_wet), 0.0, 1.0)


## A storm: hard rain with thunder.
static func storm(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> bool:
	var i := floori(time_ms / (KNOT_HOURS * Daylight.HOUR_MS))
	return rain(seed, time_ms, place, climate) > 0.6 and _roll(seed * 31 + 7, i) > STORM_FROM


## What it is like, in a word: "clear", "cloudy", "rain", "storm", "snow", "fog".
static func kind(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> String:
	if storm(seed, time_ms, place, climate):
		return "storm"
	if rain(seed, time_ms, place, climate) > 0.15:
		return "rain"
	if snow(seed, time_ms, place, climate) > 0.15:
		return "snow"
	if fog(seed, time_ms, place, climate) > 0.4:
		return "fog"
	return "cloudy" if clouds(seed, time_ms, place, climate) > 0.5 else "clear"


## How far one sees in it, a share of a clear day's (creatures, ADR-0018).
static func sight(seed: int, time_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	return 1.0 - 0.35 * precipitation(seed, time_ms, place, climate) - 0.5 * fog(seed, time_ms, place, climate)


## Game hours of rain (by its strength) between two world times at a place.
static func rain_hours(seed: int, from_ms: float, to_ms: float, place := Vector2i.ZERO, climate := Vector2.ZERO) -> float:
	if to_ms <= from_ms:
		return 0.0
	# Rain sums are kept by area and climate in steps (a field's own place
	# within its area would make a sum of its own for each field).
	var area := Vector2i(roundi(float(place.x) / FRONT) * FRONT, roundi(float(place.y) / FRONT) * FRONT)
	var near := Vector2(snappedf(climate.x, 0.1), snappedf(climate.y, 0.1))
	return _rain_sum(seed, to_ms, area, near) - _rain_sum(seed, from_ms, area, near)


static func _rain_sum(seed: int, time_ms: float, area: Vector2i, climate: Vector2) -> float:
	var hours := maxf(0.0, time_ms / Daylight.HOUR_MS)
	var h := floori(hours)
	var key := "%d|%d|%d|%.1f|%.1f" % [seed, area.x, area.y, climate.x, climate.y]
	var sums: PackedFloat32Array = _rain_sums.get(key, PackedFloat32Array([0.0]))
	while sums.size() <= h + 1:
		var at := sums.size() - 1
		sums.append(sums[at] + rain(seed, (at + 0.5) * Daylight.HOUR_MS, area, climate))
	if _rain_sums.size() > 256:
		_rain_sums.clear()
	_rain_sums[key] = sums
	return lerpf(sums[h], sums[h + 1], hours - h)


static func _roll(seed: int, i: int) -> float:
	return float(absi(hash([seed, i])) % 100003) / 100003.0
