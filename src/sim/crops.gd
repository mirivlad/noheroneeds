class_name Crops
## Crops (ADR-0027): a plant with "crop": {"stages", "grow_hours"} sown at a
## world time grows by the world's clock alone — the same on the server and
## every client, nothing to send while it grows; ripe at its last stage.


## Rain waters a field (ADR-0033): an hour of rain grows a crop as two.
const RAIN_GROWTH := 1.0


## The stage (0 .. stages-1) of a crop sown at `planted` (world ms) at `now`;
## under the sky (`weather_seed` >= 0) the rain since counts too.
static func stage(def: Dictionary, planted: float, now: float, weather_seed := -1) -> int:
	var crop: Dictionary = def.get("crop", {})
	var stages := maxi(1, int(crop.get("stages", 1)))
	var grow := float(crop.get("grow_hours", 0.0)) * Daylight.HOUR_MS
	if grow <= 0.0:
		return stages - 1
	var grown := now - planted
	if weather_seed >= 0 and grown > 0.0:
		grown += RAIN_GROWTH * Weather.rain_hours(weather_seed, planted, now) * Daylight.HOUR_MS
	return clampi(int(floorf(grown / grow * (stages - 1))), 0, stages - 1)


static func ripe(def: Dictionary, planted: float, now: float, weather_seed := -1) -> bool:
	return stage(def, planted, now, weather_seed) >= maxi(1, int(def.get("crop", {}).get("stages", 1))) - 1
