class_name Crops
## Crops (ADR-0027): a plant with "crop": {"stages", "grow_hours"} sown at a
## world time grows by the world's clock alone — the same on the server and
## every client, nothing to send while it grows; ripe at its last stage.


## The stage (0 .. stages-1) of a crop sown at `planted` (world ms) at `now`.
static func stage(def: Dictionary, planted: float, now: float) -> int:
	var crop: Dictionary = def.get("crop", {})
	var stages := maxi(1, int(crop.get("stages", 1)))
	var grow := float(crop.get("grow_hours", 0.0)) * Daylight.HOUR_MS
	if grow <= 0.0:
		return stages - 1
	return clampi(int(floorf((now - planted) / grow * (stages - 1))), 0, stages - 1)


static func ripe(def: Dictionary, planted: float, now: float) -> bool:
	return stage(def, planted, now) >= maxi(1, int(def.get("crop", {}).get("stages", 1))) - 1
