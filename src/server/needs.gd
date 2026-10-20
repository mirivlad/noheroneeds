class_name Needs
extends RefCounted
## What a character needs to keep going (ADR-0032, ADR-0034), the server's alone.
## Satiety (0..100): it goes down with the world's time and with work; food
## brings it back. Hungry (below HUNGRY), health does not come back; at
## nothing, hunger takes health, one an hour, but never the last: hunger
## alone does not kill. Each player is told only their own.

## Full to nothing in this many game hours of doing nothing much.
const EMPTY_HOURS := 36.0
## What a blow, a cast, a stroke of a hoe costs.
const WORK := 0.25
const HUNGRY := 20.0
const FULL := 100.0
## After death one comes back neither full nor starving.
const AFTER_DEATH := 50.0
## Warmth (0..100, ADR-0034): what the night and the rain take an hour
## outdoors, what a roof gives back, how far a fire's "heat" reaches.
const NIGHT_CHILL := 12.0
const RAIN_CHILL := 20.0
const SHELTER_WARMS := 10.0
const DAY_WARMS := 5.0
const FIRE_REACH := 3
## Energy (0..100, ADR-0035): awake it lasts this many game hours; in a bed
## it comes back this much an hour. Below TIRED one does not run.
const AWAKE_HOURS := 40.0
const BED_RESTS := 34.0
const TIRED := 20.0
## Below this one is cold: food goes faster, health does not come back.
const COLD := 25.0
## Each point of what one wears ("warmth") keeps off this share, to MOST_KEPT.
const KEPT_A_POINT := 0.12
const MOST_KEPT := 0.8

var world: ServerWorld
var _last_time := -1
## Game ms of hunger not yet taken as health, by character.
var _starving := {}


func _init(w: ServerWorld) -> void:
	world = w


func satiety_of(id: String) -> float:
	return float(world.present[id].get("satiety", FULL)) if world.present.has(id) else FULL


func set_satiety(id: String, value: float) -> void:
	if not world.present.has(id):
		return
	var p: Dictionary = world.present[id]
	var was := int(ceilf(float(p.get("satiety", FULL))))
	p["satiety"] = clampf(value, 0.0, FULL)
	if int(ceilf(p["satiety"])) != was:
		p["needs_v"] = int(p.get("needs_v", 0)) + 1  # what the player is told changed
		world.note_character(id)


func warmth_of(id: String) -> float:
	return float(world.present[id].get("warmth", FULL)) if world.present.has(id) else FULL


func set_warmth(id: String, value: float) -> void:
	if not world.present.has(id):
		return
	var p: Dictionary = world.present[id]
	var was := int(ceilf(float(p.get("warmth", FULL))))
	p["warmth"] = clampf(value, 0.0, FULL)
	if int(ceilf(p["warmth"])) != was:
		p["needs_v"] = int(p.get("needs_v", 0)) + 1
		world.note_character(id)


func energy_of(id: String) -> float:
	return float(world.present[id].get("energy", FULL)) if world.present.has(id) else FULL


func set_energy(id: String, value: float) -> void:
	if not world.present.has(id):
		return
	var p: Dictionary = world.present[id]
	var was := int(ceilf(float(p.get("energy", FULL))))
	p["energy"] = clampf(value, 0.0, FULL)
	if int(ceilf(p["energy"])) != was:
		p["needs_v"] = int(p.get("needs_v", 0)) + 1
		world.note_character(id)


## Whether one may run (not when tired).
func may_run(id: String) -> bool:
	return energy_of(id) >= TIRED


func asleep(id: String) -> bool:
	return world.present.has(id) and world.present[id].has("asleep")


## Whether health may come back (not while hungry or cold).
func may_heal(id: String) -> bool:
	return satiety_of(id) >= HUNGRY and warmth_of(id) >= COLD


## How warm it is where one stands, game hours' worth a game hour:
## below 0 it chills (night, rain, outdoors), above it warms (a roof, a fire).
func warming(id: String) -> float:
	var p: Dictionary = world.present[id]
	var loc := String(p["location"])
	var cell := Movement.cell_of(p["pos"])
	var heat := _fire_near(loc, cell)
	var sky := world.has_daylight(loc) and not world.sheltered(loc, cell.x, cell.y)
	var chill := 0.0
	if sky:
		if Daylight.is_night(world.world_time):
			chill += NIGHT_CHILL
		chill += RAIN_CHILL * Weather.rain(world.weather_seed, world.world_time)
	chill *= 1.0 - minf(MOST_KEPT, KEPT_A_POINT * float(clothes_warmth(id)))
	if chill > 0.0:
		return heat - chill
	return heat + (DAY_WARMS if sky else SHELTER_WARMS)


## What one wears against the cold: the "warmth" of each worn thing.
func clothes_warmth(id: String) -> int:
	var total := 0
	for item: Variant in (world.present[id].get("appearance", {}).get("worn", {}) as Dictionary).values():
		total += int(world.content.get_def(String(item)).get("warmth", 0))
	return total


## The most "heat" of a part within FIRE_REACH cells (a campfire, a forge).
func _fire_near(location: String, at: Vector2i) -> float:
	var best := 0.0
	for y in range(at.y - FIRE_REACH, at.y + FIRE_REACH + 1):
		for x in range(at.x - FIRE_REACH, at.x + FIRE_REACH + 1):
			var part := world.part_at(location, x, y)
			if part != "":
				best = maxf(best, float(world.content.get_def(part).get("heat", 0.0)))
	return best


## Work done (a blow, a cast): it costs a little satiety.
func worked(id: String) -> void:
	if world.present.has(id):
		set_satiety(id, satiety_of(id) - WORK)


## What the player is told of their own needs, and its version.
func shown(id: String) -> Dictionary:
	return {"satiety": int(ceilf(satiety_of(id))), "warmth": int(ceilf(warmth_of(id))), "energy": int(ceilf(energy_of(id)))}


func version(id: String) -> int:
	return int(world.present[id].get("needs_v", 0)) if world.present.has(id) else 0


## Once a second or so: the time gone since takes its share.
func step() -> void:
	var now := world.world_time
	if _last_time < 0 or now < _last_time:
		_last_time = now
		return
	var gone := now - _last_time
	_last_time = now
	if gone <= 0:
		return
	var hours := float(gone) / Daylight.HOUR_MS
	for id: String in world.present:
		# Awake it runs down; asleep in a bed it comes back, and full one wakes.
		var sleeping := asleep(id)
		set_energy(id, energy_of(id) + (BED_RESTS if sleeping else -FULL / AWAKE_HOURS) * hours)
		if sleeping and energy_of(id) >= FULL:
			world.wake(id)
		var warm := warmth_of(id) + warming(id) * hours
		set_warmth(id, warm)
		# The cold burns food: half as fast again.
		var left := satiety_of(id) - FULL / EMPTY_HOURS * hours * (1.5 if warm < COLD else 1.0) * (0.5 if sleeping else 1.0)
		set_satiety(id, left)
		if left > 0.0 and warm > 0.0:
			_starving.erase(id)
			continue
		var owed := int(_starving.get(id, 0)) + gone  # starving or freezing: an hour, a health
		while owed >= Daylight.HOUR_MS:
			owed -= Daylight.HOUR_MS
			if world.combat.health_of(id) > 1:
				world.combat.hurt(id, 1, "")
		_starving[id] = owed
