class_name Caravans
extends RefCounted
## Escort membership and hiring. The old single "guard" field remains a
## first-member alias for existing saves; the roster is authoritative.

const HIRE := 10
const MAX_GUARDS := 6
const WEAPONS := ["base:iron_sword", "base:spear", "base:bow"]
const DAILY_PAY := 12
var world: ServerWorld
var _contracts := {}
var _seen_online := {}


func _init(w: ServerWorld) -> void:
	world = w


func guards(c: Creature) -> Array:
	if not c.job.has("guards"):
		var old := String(c.job.get("guard", ""))
		c.job["guards"] = [old] if old != "" else []
		c.changed()
	for id: String in (c.job["guards"] as Array).duplicate():
		if world.creatures._caravan_lost(id):
			(c.job["guards"] as Array).erase(id)
			c.job["guard"] = String(c.job["guards"][0]) if not (c.job["guards"] as Array).is_empty() else ""
			world.operation_creature(c)
	return c.job["guards"]


func desired(c: Creature) -> int:
	var value := 0
	var stock := world.inventory("trade|" + c.id)
	for item: String in stock.stacks:
		var each := world.economy.price(String(c.job.get("from", "")), item)
		var states: Array = stock.states.get(item, [])
		for i in stock.count(item):
			value += roundi(each * Wear.value(world.content, item, states[i] if i < states.size() else {}))
	return clampi(1 + (int(c.job.get("purse", 0)) + value) / 120, 1, MAX_GUARDS)


func reserve(c: Creature) -> int:
	return mini(int(c.job.get("purse", 0)) / 3, desired(c) * HIRE)


func hire(c: Creature, budget: int) -> void:
	var roster := guards(c)
	var wanted := mini(desired(c), mini(int(c.job.get("purse", 0)), budget) / HIRE)
	# Existing people are retained first. A temporarily unloaded guard keeps
	# its place; a new guard is never substituted for mere absence.
	while roster.size() < wanted:
		var guard := spawn_guard(c, WEAPONS[roster.size() % WEAPONS.size()])
		roster.append(guard.id)
	for i in range(roster.size() - 1, -1, -1):
		var guard := world.creatures.get_creature(String(roster[i]))
		if i >= wanted and guard != null:
			guard.job.erase("guard_driver")
			guard.job["retired"] = true
			world.operation_creature(guard)
			roster.remove_at(i)
		elif i < wanted and guard != null:
			c.job["purse"] = int(c.job.get("purse", 0)) - HIRE
			guard.job["purse"] = int(guard.job.get("purse", 0)) + HIRE
			world.operation_creature(guard)
	c.job["guard"] = String(roster[0]) if not roster.is_empty() else ""
	world.operation_creature(c)


func spawn_guard(c: Creature, weapon := "base:iron_sword") -> Creature:
	for cy in range((c.cell().y - 20) >> 5, ((c.cell().y + 20) >> 5) + 1):
		for cx in range((c.cell().x - 20) >> 5, ((c.cell().x + 20) >> 5) + 1):
			for id: String in world.creatures.in_chunk(c.location, cx, cy, "base:caravan_guard"):
				var available := world.creatures.get_creature(id)
				if available.job.get("retired", false) and available.health >= 12 and available.cell().distance_to(c.cell()) <= 20:
					available.job.erase("retired")
					available.job["guard_driver"] = c.id
					world.operation_creature(available)
					return available
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([c.seed, guards(c).size(), "escort"])
	var offset := Vector2i(-2 if guards(c).size() % 2 == 0 else 2, 1 + guards(c).size() / 2)
	var place := world.creatures._spot_near(c, c.cell() + offset, 2, rng.randi())
	if place == Creature.NO_TARGET:
		place = c.cell()
	var guard := world.creatures._spawn("base:caravan_guard", c.location, place, CreatureSim.villager_looks(rng), rng.randi())
	guard.job = {"guard_driver": c.id}
	world.combat.equip_creature(guard, weapon, true)
	return guard


func attacked(victim: Creature, attacker: String, at: Vector2i) -> void:
	var driver_id := String(victim.job.get("guard_driver", victim.job.get("caravan_driver", victim.id)))
	var driver := world.creatures.get_creature(driver_id)
	if driver == null or driver.job.get("profession", "") != "base:trader":
		return
	for id: String in guards(driver):
		var guard := world.creatures.get_creature(id)
		if guard == null or guard.location != victim.location or guard.cell().distance_to(victim.cell()) > 20:
			continue
		guard.memory[attacker] = {"pos": Movement.cell_of(at), "time": world.world_time, "what": "attacker"}
		guard.changed()
		world.creatures.alarm(guard)


func removed(c: Creature) -> void:
	if c.job.get("profession", "") == "base:trader":
		finish_for(c, "dead")
	var driver := world.creatures.get_creature(String(c.job.get("guard_driver", "")))
	if driver != null:
		var roster := guards(driver)
		roster.erase(c.id)
		driver.job["guard"] = String(roster[0]) if not roster.is_empty() else ""
		world.operation_creature(driver)
	for id: String in c.job.get("guards", [c.job["guard"]] if c.job.get("guard", "") != "" else []):
		var guard := world.creatures.get_creature(id)
		if guard != null:
			guard.job.erase("guard_driver")
			guard.job["retired"] = true
			world.operation_creature(guard)
			world.creatures.alarm(guard)


func contract(actor: String) -> Dictionary:
	if not _contracts.has(actor):
		var raw := world.fact("escort|" + actor)
		var parsed: Variant = JSON.parse_string(raw) if raw != "" else null
		_contracts[actor] = parsed if parsed is Dictionary else {}
	return _contracts[actor]


func _save_contract(actor: String) -> void:
	world.operation_fact("escort|" + actor, JSON.stringify(contract(actor)))


func offer(actor: String, c: Creature) -> Dictionary:
	var current := contract(actor)
	if current.get("state", "") == "active":
		return current.duplicate(true)
	return {"state": "offered", "trader": c.id, "rate": DAILY_PAY,
		"destination": world.chronicles.village_name(String(c.job.get("toward", ""))),
		"can_hire": int(c.job.get("purse", 0)) >= DAILY_PAY}


func hire_player(actor: String, c: Creature) -> Dictionary:
	if contract(actor).get("state", "") == "active":
		return {"ok": false, "reason": "escort_active"}
	if int(c.job.get("purse", 0)) < DAILY_PAY:
		return {"ok": false, "reason": "no_money_there"}
	c.job["purse"] = int(c.job["purse"]) - DAILY_PAY
	(c.job.get_or_add("player_guards", []) as Array).append(actor)
	_contracts[actor] = {"state": "active", "trader": c.id, "name": String(c.job.get("name", "Торговец")),
		"destination": world.chronicles.village_name(String(c.job.get("toward", ""))), "rate": DAILY_PAY,
		"escrow": DAILY_PAY, "elapsed": 0, "paid": 0, "last": world.world_time, "accompanying": true}
	_seen_online[actor] = world.tick
	_save_contract(actor)
	world.operation_creature(c)
	return {"ok": true}


func step() -> void:
	for actor: String in _seen_online.keys():
		if not world.present.has(actor):
			_seen_online.erase(actor)
	for actor: String in world.present:
		var s := contract(actor)
		if s.get("state", "") != "active":
			continue
		var last_tick := int(_seen_online.get(actor, -100000))
		_seen_online[actor] = world.tick
		var previous := int(s.get("last", world.world_time))
		s["last"] = world.world_time
		var driver := world.creatures.get_creature(String(s["trader"]))
		if driver == null:
			if world.creatures._caravan_lost(String(s["trader"])):
				finish(actor, "dead")
			else:
				s["accompanying"] = false
				_save_contract(actor)
			continue
		var p: Dictionary = world.present[actor]
		var nearby: bool = p["location"] == driver.location and Vector2(p["pos"]).distance_to(Vector2(driver.pos)) <= 18 * Movement.UNIT
		var was_near: bool = s.get("accompanying", false)
		s["accompanying"] = nearby
		# No offline/restart catch-up, and no payment for an interval spent away.
		if nearby and was_near and world.tick - last_tick <= Movement.TICK_RATE * 2:
			s["elapsed"] = int(s["elapsed"]) + maxi(0, world.world_time - previous)
		while int(s["elapsed"]) >= Daylight.DAY_MS and s["state"] == "active":
			s["elapsed"] = int(s["elapsed"]) - Daylight.DAY_MS
			_pay(actor, int(s["rate"]))
			if int(driver.job.get("purse", 0)) < int(s["rate"]):
				finish(actor, "funds")
				break
			driver.job["purse"] = int(driver.job["purse"]) - int(s["rate"])
			s["escrow"] = int(s["escrow"]) + int(s["rate"])
			world.operation_creature(driver)
		_save_contract(actor)


func _pay(actor: String, coins: int) -> void:
	var s := contract(actor)
	coins = mini(coins, int(s.get("escrow", 0)))
	if coins <= 0:
		return
	world.inventory(actor).add("base:coin", coins)
	world.touch_inventory(actor)
	s["escrow"] = int(s["escrow"]) - coins
	s["paid"] = int(s.get("paid", 0)) + coins
	_save_contract(actor)


func finish(actor: String, reason: String) -> void:
	var s := contract(actor)
	if s.get("state", "") != "active":
		return
	_pay(actor, mini(int(s["escrow"]), int(float(s["elapsed"]) / Daylight.DAY_MS * int(s["rate"]))))
	var driver := world.creatures.get_creature(String(s["trader"]))
	if driver != null:
		driver.job["purse"] = int(driver.job.get("purse", 0)) + int(s["escrow"])
		(driver.job.get("player_guards", []) as Array).erase(actor)
		world.operation_creature(driver)
	elif int(s["escrow"]) > 0:
		# The employer may simply be in an unloaded chunk. Keep its refund
		# without loading or rewriting an old creature row behind the simulation.
		var key := "escort_refund|" + String(s["trader"])
		world.operation_fact(key, str(int(world.fact(key)) + int(s["escrow"])))
	s["escrow"] = 0
	s["state"] = reason
	_save_contract(actor)


func apply_refund(c: Creature) -> void:
	var key := "escort_refund|" + c.id
	var coins := int(world.fact(key))
	if coins > 0:
		c.job["purse"] = int(c.job.get("purse", 0)) + coins
		world.operation_fact(key, "0")
		world.operation_creature(c)
	for actor: String in (c.job.get("player_guards", []) as Array).duplicate():
		var current := contract(actor)
		if current.get("state", "") != "active" or current.get("trader", "") != c.id:
			(c.job["player_guards"] as Array).erase(actor)
			world.operation_creature(c)


func finish_for(c: Creature, reason: String) -> void:
	for actor: String in (c.job.get("player_guards", []) as Array).duplicate():
		if contract(actor).get("trader", "") == c.id:
			finish(actor, reason)


func betrayed(attacker: String, victim: Creature) -> void:
	if not world.present.has(attacker):
		return
	var s := contract(attacker)
	var driver_id := String(victim.job.get("guard_driver", victim.job.get("caravan_driver", victim.id)))
	if s.get("state", "") == "active" and s.get("trader", "") == driver_id:
		finish(attacker, "betrayed")


func player_attacked(actor: String, attacker: String) -> void:
	if not world.present.has(actor):
		return
	var s := contract(actor)
	if s.get("state", "") != "active":
		return
	var driver := world.creatures.get_creature(String(s["trader"]))
	var at := world.combat._position(attacker)
	if driver != null and at != Combat.NO_POS:
		attacked(driver, attacker, at)


## Sleep at a temporary roadside camp. Its fire belongs to this caravan;
## cleanup checks both the part and ownership before removing anything.
func rest(c: Creature) -> void:
	if not c.job.has("camp_spot"):
		var spot := c.cell()
		var in_village := false
		for village: String in [String(c.job.get("from", "")), String(c.job.get("toward", ""))]:
			var plan := world.generator.settlements.plan_by_id(village)
			if not plan.is_empty() and (plan["bounds"] as Rect2i).grow(6).has_point(c.cell()):
				in_village = true
		c.job["rest_in_village"] = in_village
		var heading: Array = c.job.get("caravan_heading", [0, 1])
		var direction := Vector2i(int(heading[0]), int(heading[1]))
		for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			if in_village:
				break
			var candidate := c.cell() + d * 4
			var at := candidate * Movement.UNIT + Vector2i(128, 128)
			if world.creatures._free(c.location, candidate) and world.creatures._caravan_cart_fits(c, at, direction) \
					and world.creatures._caravan_horse_fits(c, at, direction):
				spot = candidate
				break
		c.job["camp_spot"] = [spot.x, spot.y]
		world.operation_creature(c)
	var saved: Array = c.job["camp_spot"]
	var spot := Vector2i(int(saved[0]), int(saved[1]))
	if c.cell().distance_to(spot) > 1:
		world.bandits.walk_to(c, spot, "camp")
		return
	if not c.job.has("campfire") and not c.job.get("rest_in_village", false):
		var fuel := world.inventory("supplies|" + c.id)
		for d: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var at := c.cell() + d * 3
			if fuel.count("base:log") < 2 or not world.creatures._free(c.location, at) \
					or _fire_occupied(c, at) or world.part_at(c.location, at.x, at.y) != "" or world.build_rain(c.location, at.x, at.y) > .25:
				continue
			var chunk := world.chunk(c.location, at.x >> 5, at.y >> 5)
			chunk.set_cell("structure", posmod(at.x, 32), posmod(at.y, 32), "base:campfire")
			world._set_layer_props(chunk, "structure", posmod(at.x, 32), posmod(at.y, 32), {"caravan_camp": c.id})
			world._changed(ServerWorld.chunk_key(c.location, at.x >> 5, at.y >> 5))
			fuel.remove("base:log", 2)
			world.touch_inventory("supplies|" + c.id)
			c.job["campfire"] = [at.x, at.y]
			world.operation_creature(c)
			break
	world.creatures._dress(c, "", true)
	world.creatures._go(c, "camp", Creature.NO_TARGET, false)


func _fire_occupied(c: Creature, at: Vector2i) -> bool:
	for cy in range((at.y - 2) >> 5, ((at.y + 2) >> 5) + 1):
		for cx in range((at.x - 2) >> 5, ((at.x + 2) >> 5) + 1):
			for id: String in world.creatures.in_chunk(c.location, cx, cy):
				var other := world.creatures.get_creature(id)
				if other.cell().distance_to(at) < (2.2 if other.kind == "base:horse" else 1.6):
					return true
	for p: Dictionary in world.present.values():
		if p["location"] == c.location and Movement.cell_of(p["pos"]).distance_to(at) < 1.6:
			return true
	return false


func break_camp(c: Creature) -> void:
	if c.job.has("campfire"):
		var at: Array = c.job["campfire"]
		var x := int(at[0])
		var y := int(at[1])
		var chunk := world.chunk(c.location, x >> 5, y >> 5)
		if chunk.get_cell("structure", posmod(x, 32), posmod(y, 32)) == "base:campfire" \
				and world._layer_props(chunk, "structure", posmod(x, 32), posmod(y, 32)).get("caravan_camp", "") == c.id:
			chunk.set_cell("structure", posmod(x, 32), posmod(y, 32), "")
			world._set_layer_props(chunk, "structure", posmod(x, 32), posmod(y, 32), {})
			world._changed(ServerWorld.chunk_key(c.location, x >> 5, y >> 5))
	c.job.erase("campfire")
	c.job.erase("camp_spot")
	c.job.erase("rest_in_village")
	world.creatures._dress(c, "", false)
	world.operation_creature(c)
