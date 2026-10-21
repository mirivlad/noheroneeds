class_name Wear
## Wear of things (ADR-0046): a tool, a weapon, armour lasts its
## "durability" in uses (a blow of work, a hit, a shot, a cast, a blow
## taken). Each copy keeps what it has spent in its own state ({"wear": n,
## "repairs": n}, Inventory.states). Worn down to a quarter it is dull —
## slower and weaker; at its limit it is broken and does nothing until
## mended. Mending ("repair" of its def: the station and the materials of a
## full mend) costs in proportion to the wear, and every mend takes a share
## off what it lasts from then on: a thing is mended a few times, then it is
## spent and must be made anew. A broken thing that can be mended no more
## (or never could: flint) falls apart.
##
## The same rules serve the server (what a use does) and the client (the bar
## on a cell, ItemCard).

## Below this share of what it lasts a thing is dull.
const DULL := 0.25
## A dull thing works this much slower (its cooldown) ...
const DULL_PACE := 1.3
## ... and strikes with this share of its damage.
const DULL_DAMAGE := 0.75
## Every mend takes this share of the new thing's durability off its limit.
const REPAIR_LOSS := 0.15
## A thing is not mended below this share of what it lasted new.
const LEAST_LIMIT := 0.4
## A broken thing sells for this share of a whole one.
const BROKEN_VALUE := 0.1


## Uses a new copy lasts (0: it does not wear).
static func durability(content: ContentRegistry, id: String) -> int:
	return int(content.get_def(id).get("durability", 0)) if id != "" else 0


static func wears(content: ContentRegistry, id: String) -> bool:
	return durability(content, id) > 0


static func spent(state: Dictionary) -> int:
	return int(state.get("wear", 0))


static func repairs(state: Dictionary) -> int:
	return int(state.get("repairs", 0))


## The quality it was made with (ADR-0047): the share of the full
## durability (1 — as the content says: a trader's, a starter's, by a
## blueprint).
static func quality(state: Dictionary) -> float:
	return clampf(float(state.get("quality", 1.0)), 0.0, 1.0)


## Its enhancements (modifier ids).
static func mods(state: Dictionary) -> Array:
	return state.get("mods", []) if typeof(state.get("mods")) == TYPE_ARRAY else []


## What its enhancements do to `name`: their factors multiplied, or their
## amounts added (`adds`).
static func mod_effect(content: ContentRegistry, state: Dictionary, name: String, adds := false) -> float:
	var out := 0.0 if adds else 1.0
	for m: Variant in mods(state):
		var e: Dictionary = content.get_def(String(m)).get("effects", {})
		if e.has(name):
			out = out + float(e[name]) if adds else out * float(e[name])
	return out


## Uses this copy lasts now: its quality, enhancements and mends counted.
static func limit(content: ContentRegistry, id: String, state: Dictionary) -> int:
	return maxi(1, roundi(durability(content, id) * quality(state) * mod_effect(content, state, "durability")
		* (1.0 - REPAIR_LOSS * repairs(state))))


## What is left of it, 0..1 (1 for things that do not wear).
static func condition(content: ContentRegistry, id: String, state: Dictionary) -> float:
	if not wears(content, id):
		return 1.0
	return clampf(1.0 - float(spent(state)) / limit(content, id, state), 0.0, 1.0)


static func broken(content: ContentRegistry, id: String, state: Dictionary) -> bool:
	return wears(content, id) and spent(state) >= limit(content, id, state)


static func dull(content: ContentRegistry, id: String, state: Dictionary) -> bool:
	return wears(content, id) and not broken(content, id, state) and condition(content, id, state) < DULL


## How much slower it works (a cooldown's factor).
static func pace(content: ContentRegistry, id: String, state: Dictionary) -> float:
	return (DULL_PACE if dull(content, id, state) else 1.0) * mod_effect(content, state, "pace")


## Its damage as it is now (enhancements added, dull less).
static func damage(content: ContentRegistry, id: String, state: Dictionary, base: int) -> int:
	if base <= 0:
		return base
	var d := base + roundi(mod_effect(content, state, "damage", true))
	return maxi(1, roundi(d * DULL_DAMAGE)) if dull(content, id, state) else d


## What it keeps off a blow (worn armour): nothing broken.
static func armor(content: ContentRegistry, id: String, state: Dictionary) -> int:
	var base := int(content.get_def(id).get("armor", 0))
	if base <= 0 or broken(content, id, state):
		return 0
	return base + roundi(mod_effect(content, state, "armor", true))


## What it keeps off the cold (worn).
static func warmth(content: ContentRegistry, id: String, state: Dictionary) -> int:
	var base := int(content.get_def(id).get("warmth", 0))
	return base + roundi(mod_effect(content, state, "warmth", true)) if base > 0 else 0


## The chance a gather with it gives one more of each thing.
static func extra_yield(content: ContentRegistry, state: Dictionary) -> float:
	return mod_effect(content, state, "yield", true)


## A copy after `n` uses.
static func used(state: Dictionary, n := 1) -> Dictionary:
	var s := state.duplicate()
	s["wear"] = spent(state) + n
	return s


## Mends it may still take (0: none, or it is not mended at all).
static func mends_left(content: ContentRegistry, id: String, state: Dictionary) -> int:
	if not wears(content, id) or not content.get_def(id).has("repair"):
		return 0
	var most := floori((1.0 - LEAST_LIMIT) / REPAIR_LOSS + 0.0001)
	return maxi(0, most - repairs(state))


## Whether it can be mended now: worn, and a mend left.
static func mendable(content: ContentRegistry, id: String, state: Dictionary) -> bool:
	return spent(state) > 0 and mends_left(content, id, state) > 0


## The station it is mended at ("" — none).
static func mend_station(content: ContentRegistry, id: String) -> String:
	return String((content.get_def(id).get("repair", {}) as Dictionary).get("station", ""))


## What a mend costs: the full mend's materials in proportion to the wear,
## rounded up, at least one of the first.
static func mend_cost(content: ContentRegistry, id: String, state: Dictionary) -> Dictionary:
	var full: Dictionary = (content.get_def(id).get("repair", {}) as Dictionary).get("materials", {})
	var share := clampf(float(spent(state)) / limit(content, id, state), 0.0, 1.0)
	var out := {}
	for m: String in full:
		var n := ceili(float(full[m]) * share - 0.0001)
		if n > 0:
			out[m] = n
	if out.is_empty() and not full.is_empty():
		out[full.keys()[0]] = 1
	return out


## A copy mended: no wear, one more mend.
static func mended(state: Dictionary) -> Dictionary:
	var s := state.duplicate()
	s.erase("wear")
	s["repairs"] = repairs(state) + 1
	return s


## Its worth against a whole one (trade): what is left of it (broken,
## little), how well it was made and what enhances it (ADR-0047): a
## master's thing is worth more than a trader's plain one.
static func value(content: ContentRegistry, id: String, state: Dictionary) -> float:
	var left := BROKEN_VALUE if broken(content, id, state) else maxf(BROKEN_VALUE, condition(content, id, state))
	return left * worth(content, state)


## How much a copy is worth for how it was made: quality 1 — as the
## content's price; a novice's half-quality thing less, every enhancement
## more ("value" of a modifier, else 1.2).
static func worth(content: ContentRegistry, state: Dictionary) -> float:
	var w := 0.4 + 0.6 * quality(state)
	for m: Variant in mods(state):
		w *= float(content.get_def(String(m)).get("value", 1.2))
	return w
