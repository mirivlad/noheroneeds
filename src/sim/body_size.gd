class_name BodySize
## How big a body is (ADR-0024), from a body plan's or a creature's "size":
##   half   — [cells, cells]: half the width and depth of the box at its feet
##            it collides with (Movement); a hare 0.15, a man 0.3, a dragon 1.5;
##   radius — cells round its position where blows and arrows reach it;
##   height — storeys (one storey: a wall, 64 px on screen); an arrow above
##            it passes over;
##   eye    — storeys: where it looks from (Sight); a hare in the grass sees
##            little, a dragon over a wall;
##   body   — storeys: where others look at it (Sight).
## Nothing given: a man's size, which the rules always had.

const HUMAN := {"half": Vector2i(80, 48), "radius": 80, "height": 0.8, "eye": 0.75, "body": 0.5}


## A normalized size, or the errors of a malformed one appended.
static func parse(id: String, raw: Variant, errors: PackedStringArray) -> Dictionary:
	if raw == null:
		return HUMAN.duplicate()
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("%s: size must be {half, radius, height, eye, body}" % id)
		return HUMAN.duplicate()
	var s := HUMAN.duplicate()
	var half: Variant = raw.get("half", [0.3125, 0.1875])
	if typeof(half) != TYPE_ARRAY or (half as Array).size() != 2 or (half as Array).any(
			func(n: Variant) -> bool: return typeof(n) not in [TYPE_INT, TYPE_FLOAT] or float(n) <= 0.0 or float(n) > 4.0):
		errors.append("%s: size.half needs two sizes in cells, above 0 and up to 4" % id)
	else:
		s["half"] = Vector2i(roundi(float(half[0]) * Movement.UNIT), roundi(float(half[1]) * Movement.UNIT))
	for f: String in ["radius", "height", "eye", "body"]:
		if not raw.has(f):
			continue
		var v: Variant = raw[f]
		if typeof(v) not in [TYPE_INT, TYPE_FLOAT] or float(v) <= 0.0 or float(v) > 8.0:
			errors.append("%s: size.%s must be above 0 and up to 8" % [id, f])
		elif f == "radius":
			s[f] = roundi(float(v) * Movement.UNIT)
		else:
			s[f] = float(v)
	if not raw.has("radius") and raw.has("half"):
		s["radius"] = maxi(s["half"].x, s["half"].y)
	if not raw.has("eye") and raw.has("height"):
		s["eye"] = float(s["height"]) * 0.9
	if not raw.has("body") and raw.has("height"):
		s["body"] = float(s["height"]) * 0.6
	return s


## The size of a definition already loaded (ContentRegistry keeps it as "body_size").
static func of(def: Dictionary) -> Dictionary:
	return def.get("body_size", HUMAN)


## The cells a box of half extents `half` at `pos` (units) covers.
static func cells(pos: Vector2i, half: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cy in range((pos.y - half.y) >> Movement.UNIT_SHIFT, ((pos.y + half.y - 1) >> Movement.UNIT_SHIFT) + 1):
		for cx in range((pos.x - half.x) >> Movement.UNIT_SHIFT, ((pos.x + half.x - 1) >> Movement.UNIT_SHIFT) + 1):
			out.append(Vector2i(cx, cy))
	return out
