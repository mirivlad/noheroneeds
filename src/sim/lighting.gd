class_name Lighting
## How light a cell is (0..1): the base for perception (ADR-0014; creatures
## see less in the dark) and for the picture. Shared by server and client.
##   outdoors — the daylight of the hour (Daylight.outdoor_light);
##   indoors  — under a roof or a ceiling, a share of it (windows later);
##   sources  — parts with "light" in their definition (a torch, a lamp, a
##              window lit from inside later): full near them, falling off to
##              their radius; the brightest of all wins.
## Light passes through nothing yet but distance (walls do not cast shadows:
## a later refinement, with windows).

## How far around a cell sources are looked for (cells): no source shines
## farther than this.
const MAX_RADIUS := 8


## A source's light at a distance (cells): its intensity near it, smoothly
## less to nothing at its radius.
static func from_source(intensity: float, radius: float, distance: float) -> float:
	if distance >= radius:
		return 0.0
	var k := 1.0 - distance / radius
	return intensity * k * k * (3.0 - 2.0 * k)


## The light of a cell: ambient (outdoors or in) and the sources around it,
## each [Vector2 cell, intensity, radius] - the brightest wins.
## daylight: false underground (ADR-0017): only the sources light it.
static func level(time_ms: float, indoors: bool, cell: Vector2i, sources: Array, daylight := true) -> float:
	var ambient := Daylight.outdoor_light(time_ms) if daylight else 0.0
	if indoors:
		ambient *= Daylight.INDOOR_SHARE
	var best := ambient
	for s: Array in sources:
		var d := Vector2(cell).distance_to(Vector2(s[0]))
		best = maxf(best, from_source(float(s[1]), float(s[2]), d))
	return clampf(best, 0.0, 1.0)
