class_name Seasons
## The year (ADR-0036): four seasons of DAYS each, from the first day of a
## world, spring first. Like the weather, a function of the time alone.

const DAYS := 7
const SPRING := 0
const SUMMER := 1
const AUTUMN := 2
const WINTER := 3
const NAMES := ["весна", "лето", "осень", "зима"]
const SEASON_MS := DAYS * Daylight.DAY_MS
const YEAR_MS := 4 * SEASON_MS
## How much wetter the air is (Weather): spring and autumn rain more.
const WETTER := [0.06, -0.08, 0.08, 0.0]


## The season's WETTER, eased into the next over a season's last day.
static func wetter(time_ms: float) -> float:
	var s := of(time_ms)
	var into := fposmod(time_ms, float(SEASON_MS))
	var ease := clampf((into - (SEASON_MS - Daylight.DAY_MS)) / Daylight.DAY_MS, 0.0, 1.0)
	return lerpf(WETTER[s], WETTER[(s + 1) % 4], ease)


static func of(time_ms: float) -> int:
	return int(fposmod(time_ms, float(YEAR_MS)) / SEASON_MS)


static func name_of(time_ms: float) -> String:
	return NAMES[of(time_ms)]


## The day of its season, 1..DAYS.
static func day_of(time_ms: float) -> int:
	return int(fposmod(time_ms, float(SEASON_MS)) / Daylight.DAY_MS) + 1


## Game ms of winter between two world times (crops stand still in it).
static func winter_ms(from_ms: float, to_ms: float) -> float:
	if to_ms <= from_ms:
		return 0.0
	return _winter_until(to_ms) - _winter_until(from_ms)


## Winter ms from time 0 up to `t`.
static func _winter_until(t: float) -> float:
	var years := floorf(t / YEAR_MS)
	var into := t - years * YEAR_MS
	return years * SEASON_MS + clampf(into - 3.0 * SEASON_MS, 0.0, float(SEASON_MS))
