class_name Daylight
## The world's time of day and its light, shared by the server (rules:
## perception, ADR-0014) and the client (the picture, the music).
##
## World time is game milliseconds since the world began (an int, the same on
## every side). A game day is 24 game hours; how long it lasts in real time is
## a world rule (day_minutes): the server advances the clock by
## rate_for(day_minutes) game ms each tick.

const DAY_MS := 24 * 60 * 60 * 1000
const HOUR_MS := 60 * 60 * 1000
## A new world starts in the morning.
const START_MS := 7 * HOUR_MS
const DEFAULT_DAY_MINUTES := 24
## Light outdoors at the darkest of night (moon and stars), 0..1.
const NIGHT_LIGHT := 0.12
## Under a roof or a ceiling, of the light outdoors (no windows yet).
const INDOOR_SHARE := 0.35


## Game ms a server tick moves the clock for a day of `day_minutes` real minutes.
static func rate_for(day_minutes: float) -> int:
	return maxi(1, int(round(float(DAY_MS) / (maxf(day_minutes, 0.1) * 60.0 * Movement.TICK_RATE))))


static func day_of(time_ms: int) -> int:
	return time_ms / DAY_MS + 1


## Hours since midnight, 0..24 (fractional).
static func hour_of(time_ms: float) -> float:
	return fposmod(time_ms, float(DAY_MS)) / HOUR_MS


static func clock_text(time_ms: float) -> String:
	var h := hour_of(time_ms)
	return "%02d:%02d" % [int(h), int((h - floorf(h)) * 60.0)]


## Sunlight outdoors, 0 (night) .. 1 (day): dawn 4-7, day 7-18, dusk 18-21.
static func sun(time_ms: float) -> float:
	var h := hour_of(time_ms)
	if h < 4.0 or h >= 21.0:
		return 0.0
	if h < 7.0:
		return smoothstep(4.0, 7.0, h)
	if h < 18.0:
		return 1.0
	return 1.0 - smoothstep(18.0, 21.0, h)


static func is_night(time_ms: float) -> bool:
	var h := hour_of(time_ms)
	return h >= 21.0 or h < 6.0


## How light it is outdoors, 0..1 (for perception): never fully dark.
static func outdoor_light(time_ms: float) -> float:
	return lerpf(NIGHT_LIGHT, 1.0, sun(time_ms))


## The colour the world is drawn in: daylight white, a warm dawn and dusk,
## a dark blue night.
static func tint(time_ms: float) -> Color:
	var s := sun(time_ms)
	var h := hour_of(time_ms)
	var night := Color(0.30, 0.34, 0.55)
	var day := Color(1.0, 1.0, 1.0)
	var low_sun := Color(1.0, 0.78, 0.6)
	var c := night.lerp(day, s)
	# Warm near sunrise and sunset, where the sun is low.
	var warm := 1.0 - absf(s - 0.5) * 2.0
	if h > 12.0 or h < 8.0:
		c = c.lerp(c * low_sun, warm * 0.8)
	return c
