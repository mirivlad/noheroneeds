class_name Needs
extends RefCounted
## What a character needs to keep going (ADR-0032), the server's alone.
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


## Whether health may come back (not while hungry).
func may_heal(id: String) -> bool:
	return satiety_of(id) >= HUNGRY


## Work done (a blow, a cast): it costs a little satiety.
func worked(id: String) -> void:
	if world.present.has(id):
		set_satiety(id, satiety_of(id) - WORK)


## What the player is told of their own needs, and its version.
func shown(id: String) -> Dictionary:
	return {"satiety": int(ceilf(satiety_of(id)))}


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
	var loss := FULL / EMPTY_HOURS * float(gone) / Daylight.HOUR_MS
	for id: String in world.present:
		var left := satiety_of(id) - loss
		set_satiety(id, left)
		if left > 0.0:
			_starving.erase(id)
			continue
		var owed := int(_starving.get(id, 0)) + gone
		while owed >= Daylight.HOUR_MS:
			owed -= Daylight.HOUR_MS
			if world.combat.health_of(id) > 1:
				world.combat.hurt(id, 1, "")
		_starving[id] = owed
