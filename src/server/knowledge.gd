class_name Knowledge
extends RefCounted
## What characters know and how well (ADR-0047), on the server. Kept with
## the world's copy of a character (its data, as the portable profile has
## them): "known_recipes" (beyond the innate ones), "skills" and "mastery"
## ({id: {"level", "xp"}}). Mastery rules are Mastery's; this keeps them,
## practises them and rolls the dice.

var world: ServerWorld
## World rules: everyone knows every recipe; an attempt never fails (an
## easy world, and tests of what recipes make rather than of mastery).
var all_known := false
var never_fail := false
## Raised whenever a character's knowledge changes (clients get it then).
var _version := {}
## trained_by key ("tool:chopping", "craft"...) -> the skill it trains.
var _trains := {}


func _init(w: ServerWorld) -> void:
	world = w
	for id: String in w.content.defs:
		var d := w.content.get_def(id)
		if d.get("kind") == "skill":
			for k: Variant in d.get("trained_by", []):
				if String(k) != "craft" and not _trains.has(String(k)):
					_trains[String(k)] = id


func _data(actor: String) -> Dictionary:
	var known := world._known_character(actor)
	return known.get("data", {}) if not known.is_empty() else {}


func _changed(actor: String) -> void:
	_version[actor] = int(_version.get(actor, 0)) + 1
	world.note_character_changed(actor)


func version(actor: String) -> int:
	return int(_version.get(actor, 0))


## Whether one knows a recipe: every innate one, and those learned.
func knows(actor: String, recipe: String) -> bool:
	var d := world.content.get_def(recipe)
	if d.get("kind") != "recipe":
		return false
	return all_known or bool(d.get("innate", false)) or (_data(actor).get("known_recipes", []) as Array).has(recipe)


## Learns a recipe for good: false if it was known already.
func learn(actor: String, recipe: String) -> bool:
	var data := _data(actor)
	if data.is_empty() or knows(actor, recipe):
		return false
	var list: Array = data.get("known_recipes", [])
	list.append(recipe)
	data["known_recipes"] = list
	_changed(actor)
	return true


func skill_level(actor: String, skill: String) -> int:
	return int(((_data(actor).get("skills", {}) as Dictionary).get(skill, {}) as Dictionary).get("level", 0))


func mastery_level(actor: String, recipe: String) -> int:
	return int(((_data(actor).get("mastery", {}) as Dictionary).get(recipe, {}) as Dictionary).get("level", 0))


func _grow(actor: String, field: String, id: String, xp: int, k: float) -> void:
	var data := _data(actor)
	if data.is_empty() or id == "" or xp <= 0:
		return
	var all: Dictionary = data.get_or_add(field, {})
	var e: Dictionary = all.get(id, {"level": 0, "xp": 0})
	e["xp"] = int(e.get("xp", 0)) + xp
	e["level"] = Mastery.level_of(int(e["xp"]), k)
	all[id] = e
	_changed(actor)


func practise_skill(actor: String, skill: String, xp := 1) -> void:
	if world.content.kind_of(skill) == "skill":
		_grow(actor, "skills", skill, xp, Mastery.SKILL_K)


func practise_recipe(actor: String, recipe: String, xp: int) -> void:
	_grow(actor, "mastery", recipe, xp, Mastery.RECIPE_K)


## The skill a kind of practice trains ("tool:chopping", "weapon:melee",
## "hand", "crop", "kill", "build"), "" — none.
func skill_for(practice: String) -> String:
	return String(_trains.get(practice, ""))


## A practice done: its skill grows.
func practise(actor: String, practice: String, xp := 1) -> void:
	if world.present.has(actor):
		practise_skill(actor, skill_for(practice), xp)


## What one's skill in a practice gives (Mastery.effect): 1 / 0 without it.
func effect(actor: String, practice: String, name: String) -> float:
	var skill := skill_for(practice)
	if skill == "" or not world.present.has(actor):
		return 0.0 if name in Mastery.AMOUNTS else 1.0
	return Mastery.effect(world.content, skill, skill_level(actor, skill), name)


## A roll 0..1 for one's deed: the same for the same deed in the same tick
## (a repeated request rolls nothing new: it is answered from its result).
func roll(actor: String, salt: Variant) -> float:
	return float(absi(hash([world.world_seed, actor, world.tick, salt])) % 1000003) / 1000003.0


## True with chance `p` (a roll for one's deed).
func by_chance(actor: String, salt: Variant, p: float) -> bool:
	return p >= 1.0 or (p > 0.0 and roll(actor, salt) < p)


## How many of `n` come out with each of the chance `extra` one more.
func with_extra(actor: String, salt: Variant, n: int, extra: float) -> int:
	return n + (1 if by_chance(actor, [salt, "extra"], extra) else 0)


## What one knows, for oneself: the recipes learned, skills, masteries.
func shown(actor: String) -> Dictionary:
	var data := _data(actor)
	return {"known": (data.get("known_recipes", []) as Array).duplicate(), "skills": (data.get("skills", {}) as Dictionary).duplicate(true),
		"mastery": (data.get("mastery", {}) as Dictionary).duplicate(true)}


# --- what is made --------------------------------------------------------------

## The state of a thing one makes by a recipe: its quality and enhancements
## by one's mastery and skill, and the maker's name; by a blueprint, whole
## and plain.
func made_state(actor: String, item: String, recipe: String, by_blueprint: bool, salt: Variant) -> Dictionary:
	var by := String(_data(actor).get("name", ""))
	var out := {"by": by} if by != "" else {}
	if by_blueprint:
		return out
	var d := world.content.get_def(recipe)
	var m := mastery_level(actor, recipe)
	var s := skill_level(actor, String(d.get("skill", "")))
	out["quality"] = Mastery.quality(m, s, roll(actor, [salt, "quality"]))
	var mods := Mastery.fitting(world.content, item)
	var n := mini(mods.size(), Mastery.enhancements(m, s, roll(actor, [salt, "mods"])))
	var chosen: Array = []
	for i in n:
		var at := int(roll(actor, [salt, "mod", i]) * mods.size()) % mods.size()
		chosen.append(mods[at])
		mods.remove_at(at)
	if not chosen.is_empty():
		chosen.sort()
		out["mods"] = chosen
	return out


## The state of a thing a dweller of a trade sells: as well made as its
## trade makes them ("quality" range of the trade), now and then enhanced.
static func goods_state(trade: Dictionary, content: ContentRegistry, item: String, roll_value: float) -> Dictionary:
	if not Mastery.crafted_alone(content, item):
		return {}
	var q: Array = trade.get("quality", [1.0, 1.0])
	var quality := snappedf(lerpf(float(q[0]), float(q[1]), roll_value), 0.01)
	return {} if quality >= 1.0 else {"quality": quality}
