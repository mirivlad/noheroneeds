class_name Weather
## Weather of a world's surface (ADR-0033): a function of its weather seed
## and the world's time — the server and every client work it out alike,
## nothing is stored or sent while it changes. A slow "wetness" drifts
## between knots every KNOT_HOURS: high, clouds gather and it rains (now and
## then a storm); a middling one on a morning is fog; low, clear sky.

const KNOT_HOURS := 6.0
## Wetness above which clouds start, and where rain starts and is full.
const CLOUDS_FROM := 0.45
const RAIN_FROM := 0.66
const RAIN_FULL := 0.8
## A rainy knot is stormy past this (its own roll).
const STORM_FROM := 0.65

## Rain hours from world time 0 to each whole game hour, by seed (a cache:
## crops ask how much it rained since they were sown).
static var _rain_sums := {}


## 0..1, smooth over time: how wet the air is.
static func wetness(seed: int, time_ms: float) -> float:
	var k := time_ms / (KNOT_HOURS * Daylight.HOUR_MS)
	var i := floori(k)
	var f := k - i
	f = f * f * (3.0 - 2.0 * f)
	return lerpf(_roll(seed, i), _roll(seed, i + 1), f)


## How hard it rains now, 0..1.
static func rain(seed: int, time_ms: float) -> float:
	return clampf((wetness(seed, time_ms) - RAIN_FROM) / (RAIN_FULL - RAIN_FROM), 0.0, 1.0)


## How overcast the sky is, 0..1 (rain is overcast too).
static func clouds(seed: int, time_ms: float) -> float:
	return clampf((wetness(seed, time_ms) - CLOUDS_FROM) / (RAIN_FROM - CLOUDS_FROM), 0.0, 1.0)


## Morning fog, 0..1: a middling wetness between four and ten.
static func fog(seed: int, time_ms: float) -> float:
	var h := Daylight.hour_of(time_ms)
	if h < 4.0 or h > 10.0:
		return 0.0
	var by_hour := 1.0 - absf(h - 6.5) / 3.5
	var w := wetness(seed, time_ms)
	var by_wet := 1.0 - absf(w - 0.55) / 0.1
	return clampf(minf(by_hour * 1.5, by_wet), 0.0, 1.0)


## A storm: hard rain with thunder.
static func storm(seed: int, time_ms: float) -> bool:
	var i := floori(time_ms / (KNOT_HOURS * Daylight.HOUR_MS))
	return rain(seed, time_ms) > 0.6 and _roll(seed * 31 + 7, i) > STORM_FROM


## What it is like, in a word: "clear", "cloudy", "rain", "storm", "fog".
static func kind(seed: int, time_ms: float) -> String:
	if storm(seed, time_ms):
		return "storm"
	if rain(seed, time_ms) > 0.15:
		return "rain"
	if fog(seed, time_ms) > 0.4:
		return "fog"
	return "cloudy" if clouds(seed, time_ms) > 0.5 else "clear"


## How far one sees in it, a share of a clear day's (creatures, ADR-0018).
static func sight(seed: int, time_ms: float) -> float:
	return 1.0 - 0.35 * rain(seed, time_ms) - 0.5 * fog(seed, time_ms)


## Game hours of rain (by its strength) between two world times.
static func rain_hours(seed: int, from_ms: float, to_ms: float) -> float:
	if to_ms <= from_ms:
		return 0.0
	return _rain_sum(seed, to_ms) - _rain_sum(seed, from_ms)


static func _rain_sum(seed: int, time_ms: float) -> float:
	var hours := maxf(0.0, time_ms / Daylight.HOUR_MS)
	var h := floori(hours)
	var sums: PackedFloat32Array = _rain_sums.get(seed, PackedFloat32Array([0.0]))
	while sums.size() <= h + 1:
		var at := sums.size() - 1
		sums.append(sums[at] + rain(seed, (at + 0.5) * Daylight.HOUR_MS))
	_rain_sums[seed] = sums
	return lerpf(sums[h], sums[h + 1], hours - h)


static func _roll(seed: int, i: int) -> float:
	return float(absi(hash([seed, i])) % 100003) / 100003.0
