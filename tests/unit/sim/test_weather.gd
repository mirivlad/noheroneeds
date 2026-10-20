extends TestCase
## ADR-0033: the weather is a function of a seed and the time — the same
## everywhere, smooth, sometimes rain (now and then a storm), fog on
## mornings; rain waters crops; it shortens how far creatures see.

const SEED := 12345


func test_the_same_seed_and_time_give_the_same_weather_and_it_changes_smoothly() -> void:
	var t := 40.0 * Daylight.HOUR_MS
	eq(Weather.wetness(SEED, t), Weather.wetness(SEED, t), "the same, asked twice")
	check(Weather.wetness(SEED, t) != Weather.wetness(SEED + 1, t) or Weather.wetness(SEED, t + 30 * Daylight.HOUR_MS) != Weather.wetness(SEED + 1, t + 30 * Daylight.HOUR_MS),
		"another world, other weather")
	var worst := 0.0
	for m in 24 * 60:
		var a := m * 60000.0
		worst = maxf(worst, absf(Weather.wetness(SEED, a + 60000.0) - Weather.wetness(SEED, a)))
	check(worst < 0.01, "no jumps from minute to minute: %.4f" % worst)


func test_rain_now_and_then_storms_within_it_fog_on_mornings() -> void:
	var counts := {}
	var hours := 24 * 90
	for h in hours:
		var t := (h + 0.5) * Daylight.HOUR_MS
		var k := Weather.kind(SEED, t)
		counts[k] = int(counts.get(k, 0)) + 1
		if k == "storm":
			check(Weather.rain(SEED, t) > 0.6, "a storm is hard rain")
		if k == "fog":
			var hour := Daylight.hour_of(t)
			check(hour >= 4.0 and hour <= 10.0, "fog only in the morning: %.1f" % hour)
	var wet := float(int(counts.get("rain", 0)) + int(counts.get("storm", 0))) / hours
	check(wet > 0.08 and wet < 0.35, "rain some of the time: %.2f %s" % [wet, str(counts)])
	check(int(counts.get("storm", 0)) > 0 and int(counts.get("fog", 0)) > 0 and int(counts.get("clear", 0)) > hours / 3,
		"storms, fogs, and mostly clear: %s" % str(counts))


func test_rain_waters_crops() -> void:
	var sum := 0.0
	for m in 48 * 4:
		sum += Weather.rain(SEED, (m + 0.5) * Daylight.HOUR_MS / 4.0) / 4.0
	check(absf(Weather.rain_hours(SEED, 0.0, 48.0 * Daylight.HOUR_MS) - sum) < 0.6, "rain hours add up")
	eq(Weather.rain_hours(SEED, 5.0 * Daylight.HOUR_MS, 5.0 * Daylight.HOUR_MS), 0.0)
	# A crop sown before a rainy spell is ahead of one sown in a dry one.
	var wheat := {"crop": {"stages": 49, "grow_hours": 48.0}}  # a stage an hour
	var start := -1.0
	for h in 24 * 60:
		if Weather.rain_hours(SEED, h * Daylight.HOUR_MS, (h + 24) * Daylight.HOUR_MS) > 6.0:
			start = h * Daylight.HOUR_MS
			break
	check(start >= 0.0, "a rainy day somewhere")
	var later := start + 24.0 * Daylight.HOUR_MS
	eq(Crops.stage(wheat, start, later), 24, "a day: a day's growing, without the sky")
	check(Crops.stage(wheat, start, later, SEED) >= 30, "with six hours' rain, six more: %d" % Crops.stage(wheat, start, later, SEED))


func test_rain_and_fog_shorten_sight() -> void:
	var rainy := -1.0
	for h in 24 * 60:
		if Weather.rain(SEED, h * Daylight.HOUR_MS) >= 1.0:
			rainy = h * Daylight.HOUR_MS
			break
	check(rainy >= 0.0, "a downpour somewhere")
	check(Weather.sight(SEED, rainy) <= 0.66, "in a downpour, two thirds")
	eq(Weather.sight(SEED, 13.0 * Daylight.HOUR_MS) if Weather.kind(SEED, 13.0 * Daylight.HOUR_MS) == "clear" else 1.0, 1.0)
