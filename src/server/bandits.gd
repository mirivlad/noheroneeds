class_name Bandits
extends RefCounted
## Camp membership outlives loaded chunks. A missing creature is not dead;
## only the death callback removes a member from the living roster.

const SHIRT := "#dc302d"
const WEAPONS := ["base:spear", "base:iron_axe", "base:bow"]
var world: ServerWorld
var _camps := {}


func _init(w: ServerWorld) -> void:
	world = w


func state(id: String) -> Dictionary:
	if not _camps.has(id):
		var text := world.fact("bandit_camp|" + id)
		var saved: Variant = JSON.parse_string(text) if text != "" else null
		_camps[id] = saved if saved is Dictionary else {}
	return _camps[id]


func _save(id: String) -> void:
	world.operation_fact("bandit_camp|" + id, JSON.stringify(state(id)))


func populate(id: String) -> void:
	if not state(id).is_empty():
		return
	var plan := world.generator.settlements.camps.by_id(id)
	if plan.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world.world_seed, id, "residents"])
	var members := []
	var homes: Array = plan["shelters"]
	for i in int(plan["population"]):
		var looks := CreatureSim.villager_looks(rng)
		looks["colors"]["shirt"] = SHIRT
		var home: Vector2i = homes[i % homes.size()] + Vector2i(i / homes.size() - 1, 1)
		var c := world.creatures._spawn("base:bandit", Levels.SURFACE, home, looks, rng.randi())
		c.job = {"camp": id, "name": "Разбойник", "weapon": WEAPONS[rng.randi() % WEAPONS.size()],
			"arrows": 20, "duty": "fish" if i % 3 == 0 else "hunt"}
		c.held = c.job["weapon"]
		world.creatures._cold[c.id] = true
		world.operation_creature(c)
		members.append(c.id)
	_camps[id] = {"members": members, "dead": [], "raid": [], "next_raid": world.world_time + Daylight.DAY_MS,
		"meal_at": world.world_time, "abandoned": false}
	_save(id)


func died(c: Creature) -> void:
	var id := String(c.job.get("camp", ""))
	if id == "":
		return
	var s := state(id)
	if s.is_empty() or (s["dead"] as Array).has(c.id):
		return
	(s["dead"] as Array).append(c.id)
	(s["raid"] as Array).erase(c.id)
	s["abandoned"] = (s["dead"] as Array).size() >= (s["members"] as Array).size()
	_save(id)


func think(c: Creature) -> void:
	world.creatures._dress(c, String(c.job.get("weapon", "base:spear")), Daylight.is_night(world.world_time))
	world.creatures._go(c, "rest", Creature.NO_TARGET, false)
