extends TestCase
## ADR-0014: the world's time and light.


func test_the_clock_and_the_sun() -> void:
	eq(Daylight.rate_for(24), 3000, "a 24-minute day: 3 game seconds a tick")
	eq(Daylight.rate_for(48), 1500)
	eq(Daylight.clock_text(Daylight.START_MS), "07:00", "a world begins in the morning")
	eq(Daylight.day_of(Daylight.DAY_MS * 2 + 5), 3)
	eq(Daylight.sun(12 * Daylight.HOUR_MS), 1.0, "noon")
	eq(Daylight.sun(23 * Daylight.HOUR_MS), 0.0, "night")
	var dawn := Daylight.sun(5.5 * Daylight.HOUR_MS)
	check(dawn > 0.2 and dawn < 0.8, "dawn between: %.2f" % dawn)
	check(Daylight.outdoor_light(2 * Daylight.HOUR_MS) > 0.0, "never quite dark outdoors")
	check(Daylight.is_night(22 * Daylight.HOUR_MS) and not Daylight.is_night(10 * Daylight.HOUR_MS), "night is night")
	check(Daylight.tint(23 * Daylight.HOUR_MS).b > Daylight.tint(23 * Daylight.HOUR_MS).r, "a blue night")


func test_light_of_a_cell() -> void:
	var noon := 12 * Daylight.HOUR_MS
	var night := 23 * Daylight.HOUR_MS
	eq(Lighting.level(noon, false, Vector2i.ZERO, []), 1.0, "noon outdoors")
	check(absf(Lighting.level(noon, true, Vector2i.ZERO, []) - Daylight.INDOOR_SHARE) < 0.001, "under a roof, less")
	eq(Lighting.level(night, false, Vector2i.ZERO, []), Daylight.NIGHT_LIGHT, "night outdoors")
	var torch := [[Vector2i(0, 0), 0.9, 5.0]]
	check(Lighting.level(night, false, Vector2i(1, 0), torch) > 0.7, "by a torch at night")
	check(Lighting.level(night, false, Vector2i(3, 0), torch) < Lighting.level(night, false, Vector2i(1, 0), torch), "less farther")
	eq(Lighting.level(night, false, Vector2i(6, 0), torch), Daylight.NIGHT_LIGHT, "beyond its radius, the night")
