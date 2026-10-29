class_name Bandits
extends RefCounted
## Camp membership outlives loaded chunks. A missing creature is not dead;
## only the death callback removes a member from the living roster.

const SHIRT := "#dc302d"
const WEAPONS := ["base:spear", "base:iron_axe", "base:bow"]
const FOOD := ["base:cooked_meat", "base:cooked_fish", "base:raw_meat", "base:raw_fish"]
const RAID_HOURS := 8
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
		var shelter: Vector2i = homes[i % homes.size()]
		var home := shelter + Vector2i(0, 1 - i / homes.size())
		var outside := shelter + Vector2i(0, 3 + i / homes.size())
		var c := world.creatures._spawn("base:bandit", Levels.SURFACE, outside, looks, rng.randi())
		c.home = home
		c.job = {"camp": id, "name": "Разбойник", "duty": "fish" if i % 3 == 0 else "hunt",
			"ate_at": world.world_time, "healed_at": world.world_time}
		world.combat.equip_creature(c, WEAPONS[rng.randi() % WEAPONS.size()])
		world.creatures._cold[c.id] = true
		world.operation_creature(c)
		members.append(c.id)
	_camps[id] = {"members": members, "dead": [], "raid": [], "next_raid": world.world_time + Daylight.DAY_MS,
		"meal_at": world.world_time, "abandoned": false, "sortie": 0}
	world.inventory("store|camp|" + id).add("base:raw_meat", members.size() * 2)
	world.inventory("store|camp|" + id).add("base:arrow", members.size() * 8)
	world.touch_inventory("store|camp|" + id)
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
	var id := String(c.job["camp"])
	var plan := world.generator.settlements.camps.by_id(id)
	if plan.is_empty():
		return
	var sim := world.creatures
	var s := state(id)
	if s.is_empty():
		return
	_meals(id)
	if c.health < int(world.content.get_def(c.kind)["health"]) and c.cell().distance_to(c.home) < 8 \
			and world.world_time - int(c.job.get("ate_at", -Daylight.DAY_MS)) <= Daylight.HOUR_MS * 6 \
			and world.world_time - int(c.job.get("healed_at", 0)) >= Daylight.HOUR_MS:
		world.combat.heal(c.id, 1)
		c.job["healed_at"] = world.world_time
		world.operation_creature(c)
	sim._dress(c, "base:fishing_rod" if c.state == "fish" and not c.job.get("raid", false) else String(c.job.get("weapon", "base:spear")), false)
	if not c.job.get("raid", false) and world.world_time >= int(s["next_raid"]) and not Daylight.is_night(world.world_time):
		start_raid(id)
	var retreat := c.health < 6 or c.cell().distance_to(plan["centre"]) > 110
	if c.job.get("weapon", "") == "base:bow" and world.inventory("gear|" + c.id).count("base:arrow") == 0:
		retreat = true
	if c.job.get("raid", false):
		retreat = retreat or world.world_time >= int(s.get("raid_until", 0)) \
			or (s["raid"] as Array).size() * 2 < int(s.get("raid_size", 0))
	if retreat:
		c.memory.clear()
		return_home(c, plan)
		return
	if sim._fight_back(c, world.content.get_def(c.kind)):
		return
	var raid: bool = c.job.get("raid", false)
	var target := _enemy(c, plan, raid)
	if target != "":
		var memory: Dictionary = c.memory[target]
		if int(memory["time"]) == world.world_time:
			sim._engage(c, target, memory["pos"])
		else:
			walk_to(c, memory["pos"], "search", true)
		return
	if _loot(c, raid):
		return
	if raid:
		if not world.inventory("haul|" + c.id).stacks.is_empty():
			return_home(c, plan)
		else:
			walk_to(c, plan["raid_at"], "ambush")
		return
	if Daylight.is_night(world.world_time) or c.health < 12:
		return_home(c, plan)
		if c.target == Creature.NO_TARGET and c.cell().distance_to(c.home) <= 1:
			sim._dress(c, String(c.job["weapon"]), true)
		return
	if not world.inventory("haul|" + c.id).stacks.is_empty():
		return_home(c, plan)
		return
	if c.job.get("duty", "hunt") == "fish" and _fish(c, plan):
		return
	if _hunt(c):
		return
	# Unsuccessful hunters still travel through nearby forest, not stand at
	# a scripted workplace producing meat without any animal being killed.
	if c.target != Creature.NO_TARGET and c.state == "forage":
		return
	var spot := sim._spot_near(c, plan["centre"], 30, int(world.world_time / (Daylight.HOUR_MS / 4)) + c.seed)
	if spot != Creature.NO_TARGET:
		walk_to(c, spot, "forage")


func start_raid(id: String) -> Array:
	var s := state(id)
	if s.is_empty() or s.get("abandoned", false) or not (s["raid"] as Array).is_empty():
		return []
	var eligible: Array[Creature] = []
	for member: String in s["members"]:
		var c := world.creatures.get_creature(member)
		if c != null and c.health >= 12 and not c.job.get("raid", false) and c.cell().distance_to(c.home) < 50:
			eligible.append(c)
	if eligible.is_empty():
		s["next_raid"] = world.world_time + Daylight.HOUR_MS * 6
		_save(id)
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world.world_seed, id, int(s.get("sortie", 0)), world.world_time])
	for i in range(eligible.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := eligible[i]
		eligible[i] = eligible[j]
		eligible[j] = tmp
	var count := rng.randi_range(1, mini(4, maxi(1, eligible.size() - 2)))
	var selected := []
	for i in count:
		var c := eligible[i]
		c.job["raid"] = true
		c.memory.clear()
		selected.append(c.id)
		world.operation_creature(c)
		world.creatures.alarm(c)
	s["sortie"] = int(s.get("sortie", 0)) + 1
	s["raid"] = selected
	s["raid_size"] = count
	s["raid_until"] = world.world_time + Daylight.HOUR_MS * RAID_HOURS
	s["next_raid"] = world.world_time + Daylight.DAY_MS
	_save(id)
	return selected.duplicate()


func attacked(c: Creature, attacker: String, at: Vector2i) -> void:
	var camp := String(c.job.get("camp", ""))
	if camp == "":
		return
	for member: String in state(camp).get("members", []):
		var other := world.creatures.get_creature(member)
		if other == null or other.location != c.location or other.cell().distance_to(c.cell()) > 12:
			continue
		other.memory[attacker] = {"pos": Movement.cell_of(at), "time": world.world_time, "what": "attacker"}
		other.changed()
		world.creatures.alarm(other)


func _enemy(c: Creature, plan: Dictionary, raid: bool) -> String:
	var best := ""
	var distance := INF
	for id: String in c.memory:
		var m: Dictionary = c.memory[id]
		if m["what"] == "noise" or world.combat.allied(c.id, id):
			continue
		var other := world.creatures.get_creature(id)
		var caravan: bool = other != null and (other.job.get("profession", "") == "base:trader" or other.job.has("guard_driver"))
		var person := world.present.has(id)
		var intruder := person and (m["pos"] as Vector2i).distance_to(plan["centre"]) <= 11
		if not intruder and not (raid and (caravan or person) and (m["pos"] as Vector2i).distance_to(plan["raid_at"]) <= 30):
			continue
		var d := c.cell().distance_to(m["pos"])
		if d < distance:
			distance = d
			best = id
	return best


func _loot(c: Creature, raid: bool) -> bool:
	if not world.inventory("haul|" + c.id).stacks.is_empty():
		return false
	var item := world.creatures._thing_near(c, 10 if raid else 6)
	if item == "":
		return false
	var it: Dictionary = world.items[item]
	if not raid and not FOOD.has(String(it["item"])) and not it["item"] in ["base:hide", "base:arrow"]:
		return false
	var at := Vector2i(int(it["x"]), int(it["y"]))
	if Vector2(c.pos).distance_to(Vector2(at)) <= Movement.UNIT:
		world.take_item(item, world.inventory("haul|" + c.id))
		world.touch_inventory("haul|" + c.id)
		world.operation_creature(c)
	else:
		walk_to(c, Movement.cell_of(at), "loot")
	return true


func return_home(c: Creature, plan: Dictionary) -> void:
	if c.cell().distance_to(plan["centre"]) > 7:
		walk_to(c, plan["centre"], "return", true)
		return
	var haul := world.inventory("haul|" + c.id)
	var owner := "store|camp|" + String(plan["id"])
	# Destroying the store does not create an invisible replacement chest.
	var chest: Vector2i = plan["chest"]
	var chunk := world.chunk(c.location, chest.x >> 5, chest.y >> 5)
	if chunk.get_cell("structure", posmod(chest.x, 32), posmod(chest.y, 32)) == "base:chest" \
			and chunk.get_props(posmod(chest.x, 32), posmod(chest.y, 32)).get("store", "") == "camp|" + String(plan["id"]):
		for item: String in haul.stacks.keys():
			world.inventory(owner).add(item, haul.count(item), haul.take(item, haul.count(item)))
		world.touch_inventory(owner)
		world.touch_inventory("haul|" + c.id)
		if c.job.get("weapon", "") == "base:bow":
			var gear := world.inventory("gear|" + c.id)
			var arrows := mini(20 - gear.count("base:arrow"), world.inventory(owner).count("base:arrow"))
			if arrows > 0:
				world.inventory(owner).remove("base:arrow", arrows)
				gear.add("base:arrow", arrows)
				world.touch_inventory("gear|" + c.id)
	else:
		for item: String in haul.stacks.keys():
			world.place_item(c.location, c.pos, item, haul.count(item), "", 0, haul.take(item, haul.count(item)))
		world.touch_inventory("haul|" + c.id)
	if c.job.get("raid", false):
		c.job["raid"] = false
		(state(plan["id"])["raid"] as Array).erase(c.id)
		_save(plan["id"])
	world.operation_creature(c)
	walk_to(c, c.home, "home")


func walk_to(c: Creature, goal: Vector2i, activity: String, run := false) -> void:
	var sim := world.creatures
	if c.cell().distance_to(goal) <= 1:
		sim._go(c, activity, Creature.NO_TARGET, false)
		return
	if c.path_to != goal or c.path.is_empty() or c.stuck > 12:
		c.path = sim._route(c, goal)
		c.path_to = goal
	while not c.path.is_empty() and c.path[0] == c.cell():
		c.path.pop_front()
	sim._go(c, activity, c.path[0] if not c.path.is_empty() else Creature.NO_TARGET, run)


func _hunt(c: Creature) -> bool:
	for id: String in c.memory:
		var other := world.creatures.get_creature(id)
		if other != null and other.kind in ["base:hare", "base:deer"] and c.cell().distance_to(c.memory[id]["pos"]) < 14:
			world.creatures._engage(c, id, c.memory[id]["pos"])
			return true
	return false


func _fish(c: Creature, plan: Dictionary) -> bool:
	var spot: Vector2i = plan["water"]
	if spot == Settlements.NONE:
		return false
	if c.cell().distance_to(spot) > 1:
		walk_to(c, spot, "fish")
		return true
	world.creatures._dress(c, "base:fishing_rod", false)
	if world.world_time - int(c.job.get("fished_at", 0)) >= Daylight.HOUR_MS:
		c.job["fished_at"] = world.world_time
		for d: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var water := spot + d
			var chunk := world.chunk(c.location, water.x >> 5, water.y >> 5)
			var ground := chunk.get_cell("ground", posmod(water.x, 32), posmod(water.y, 32))
			var gather: Dictionary = world.content.get_def(ground).get("gather", {})
			if gather.has("chance"):
				world.combat.swung(c.id, water * Movement.UNIT + Vector2i(128, 128))
				world._gather_by_luck(c.id, chunk, [c.location, water.x >> 5, water.y >> 5, posmod(water.x, 32), posmod(water.y, 32)],
					ground, gather, 1.0, "haul|" + c.id)
				break
		world.operation_creature(c)
	world.creatures._go(c, "fish", Creature.NO_TARGET, false)
	return true


func _meals(id: String) -> void:
	var s := state(id)
	if world.world_time - int(s["meal_at"]) < Daylight.HOUR_MS * 6:
		return
	s["meal_at"] = world.world_time
	var stock := world.inventory("store|camp|" + id)
	var plan := world.generator.settlements.camps.by_id(id)
	var fire: Vector2i = plan.get("centre", Vector2i.ZERO)
	var chunk := world.chunk(Levels.SURFACE, fire.x >> 5, fire.y >> 5)
	if chunk.get_cell("structure", posmod(fire.x, 32), posmod(fire.y, 32)) == "base:campfire":
		for recipe: Array in [["base:raw_meat", "base:cooked_meat"], ["base:raw_fish", "base:cooked_fish"],
				["base:perch", "base:cooked_fish"]]:
			var n := mini(8, stock.count(recipe[0]))
			if n > 0:
				stock.remove(recipe[0], n)
				stock.add(recipe[1], n)
	for member: String in s["members"]:
		var c := world.creatures.get_creature(member)
		if c == null or c.cell().distance_to(c.home) > 12:
			continue
		for food: String in FOOD:
			if stock.count(food) > 0:
				stock.remove(food, 1)
				c.job["ate_at"] = world.world_time
				world.operation_creature(c)
				break
	world.touch_inventory("store|camp|" + id)
	_save(id)
