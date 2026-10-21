class_name Mastery
## Knowledge and mastery (ADR-0047): the rules, the same for the server
## (what an attempt gives) and the client (the chances it shows).
##
## Two kinds of progress, both {"level": 0..100, "xp": n} on the character:
## - a skill (content kind "skill": cooking, smithing, woodcutting, melee...)
##   grows with every practice of its kind and gives its "effects" in
##   proportion to its level;
## - the mastery of one recipe grows with every attempt at it.
## A recipe's chance and the quality of what it makes come from its mastery
## (most) and its skill (some), against its "difficulty" (0..100).

## Experience a level comes from: level = 115 · (1 − e^(−xp / K)), at most
## 100 (reached at about 2 K).
const RECIPE_K := 600.0
const SKILL_K := 1000.0
## Mastery experience of an attempt that worked, and of one that did not
## (one learns from mistakes too, less).
const XP_SUCCESS := 10
const XP_FAIL := 6
## How much of the way from one's mastery of a recipe up to one's skill in
## its craft the skill makes good: a smith does a new smithing recipe better
## than a stranger to the forge; it never makes a master worse.
const SKILL_HELPS := 0.25
## A novice's chance against difficulty 0 and 100; a master's at most.
const EASIEST := 0.9
const HARDEST := 0.1
const BEST := 0.99
## The mastery at which one hardly ever fails; past it, quality grows.
const SURE := 0.6
## Quality (the share of the thing's full durability) a novice and a master make.
const WORST_QUALITY := 0.5
## From this mastery on, enhancements come; a master has 2.4 on average
## (always two, sometimes three).
const ENHANCED_FROM := 0.7
const MOST_ENHANCEMENTS := 2.4
## A failed attempt spoils this share of each input (rounded up), but never
## a precious one ("precious": ingots, gems — the metal is melted again).
const FAIL_LOSS := 0.5
## Stackable things made by a master come out more (one more, by chance).
const MOST_EXTRA := 0.3


static func level_of(xp: int, k: float) -> int:
	return mini(100, floori(115.0 * (1.0 - exp(-float(xp) / k))))


## How well one does a thing, 0..1: its mastery, helped by its skill.
static func skill_of(mastery: int, skill: int) -> float:
	return clampf((mastery + SKILL_HELPS * maxi(0, skill - mastery)) / 100.0, 0.0, 1.0)


## The chance an attempt works.
static func chance(difficulty: int, mastery: int, skill: int) -> float:
	var base := lerpf(EASIEST, HARDEST, clampf(difficulty / 100.0, 0.0, 1.0))
	return base + (BEST - base) * minf(1.0, skill_of(mastery, skill) / SURE)


## The quality of what is made: from half to whole as one masters it, a
## novice's work uneven (`roll` 0..1), a master's always whole.
static func quality(mastery: int, skill: int, roll: float) -> float:
	var m := skill_of(mastery, skill)
	if m >= 0.999:
		return 1.0
	var q := WORST_QUALITY + (1.0 - WORST_QUALITY) * clampf((m - 0.2) / 0.8, 0.0, 1.0)
	q += (roll - 0.5) * 0.1 * (1.0 - m)
	return snappedf(clampf(q, WORST_QUALITY, 1.0), 0.01)


## How many enhancements a thing comes out with (`roll` 0..1).
static func enhancements(mastery: int, skill: int, roll: float) -> int:
	var t := clampf((skill_of(mastery, skill) - ENHANCED_FROM) / (1.0 - ENHANCED_FROM), 0.0, 1.0)
	var expected := MOST_ENHANCEMENTS * t
	return floori(expected) + (1 if roll < expected - floori(expected) else 0)


## The chance a stackable output comes out one more.
static func extra(mastery: int, skill: int) -> float:
	return MOST_EXTRA * clampf((skill_of(mastery, skill) - ENHANCED_FROM) / (1.0 - ENHANCED_FROM), 0.0, 1.0)


## What a failed attempt spoils of `inputs` ({item: n}).
static func spoiled(content: ContentRegistry, inputs: Dictionary) -> Dictionary:
	var out := {}
	for item: String in inputs:
		if bool(content.get_def(item).get("precious", false)):
			continue
		var n := ceili(int(inputs[item]) * FAIL_LOSS - 0.0001)
		if n > 0:
			out[item] = n
	return out


## A skill's effect at a level: its value at level 100 is "effects"[name];
## a factor (pace, wear, chance: 1 at level 0) or an amount (damage, yield:
## 0 at level 0).
static func effect(content: ContentRegistry, skill: String, level: int, name: String) -> float:
	var effects: Dictionary = content.get_def(skill).get("effects", {})
	if not effects.has(name):
		return 0.0 if name in AMOUNTS else 1.0
	var at_max := float(effects[name])
	var t := clampf(level / 100.0, 0.0, 1.0)
	return at_max * t if name in AMOUNTS else lerpf(1.0, at_max, t)


## Effects that add (the rest multiply).
const AMOUNTS := ["damage", "yield"]


## Whether what a recipe makes is a thing of its own (a copy with quality,
## enhancements, a maker): a tool, a weapon, armour, clothes.
static func crafted_alone(content: ContentRegistry, item: String) -> bool:
	var d := content.get_def(item)
	return int(d.get("stack", 1)) == 1 and (d.has("durability") or d.has("warmth") or d.has("armor") or d.has("weapon") or d.has("tools"))


## Enhancements that fit a thing (content kind "modifier", "fits": tool,
## weapon, armor, clothes), by id.
static func fitting(content: ContentRegistry, item: String) -> Array[String]:
	var d := content.get_def(item)
	var kinds := []
	if d.has("tools"):
		kinds.append("tool")
	if d.has("weapon") and not bool((d["weapon"] as Dictionary).get("improvised", false)):
		kinds.append("weapon")
	if int(d.get("armor", 0)) > 0:
		kinds.append("armor")
	if int(d.get("warmth", 0)) > 0:
		kinds.append("clothes")
	var out: Array[String] = []
	for id: String in content.defs:
		var m := content.get_def(id)
		if m.get("kind") == "modifier" and (m.get("fits", []) as Array).any(func(k: Variant) -> bool: return kinds.has(k)) \
				and (not (m.get("effects", {}) as Dictionary).has("durability") or d.has("durability")):
			out.append(id)
	out.sort()
	return out
