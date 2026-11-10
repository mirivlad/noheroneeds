class_name SettlementPopulation
extends RefCounted
## Household changes share SettlementLife's operation and durable fact.
## Dead villagers stay dead; economic departures retain the person's data.

const LEAVE_DAYS := 6
const ABANDON_DAYS := 6
const RETURN_DAYS := 3
const ROOF_LOSS := 3
const REPAIR_WAGE := 10

var world: ServerWorld


func _init(w: ServerWorld) -> void:
	world = w


func state(id: String) -> Dictionary:
	var s := world.settlement_life.state(id)
	if not s.has("residents"):
		var plan := world.generator.settlements.plan_by_id(id) if world.generator else {}
		var base := (plan.get("homes", []) as Array).size()
		var raw := world.fact("chronicle|" + id)
		var chronicle: Variant = JSON.parse_string(raw) if raw != "" else null
		var dead := {}
		if chronicle is Dictionary:
			for home: Variant in chronicle.get("dead", []):
				if int(home) >= 0:
					dead[str(int(home))] = true
		s["base_homes"] = base
		s["residents"] = {}
		s["departed"] = {}
		s["leaving"] = {}
		s["dead"] = dead
		s["population"] = maxi(0, base - dead.size())
		s["people_day"] = int(s["day"])
		s["bad_days"] = 0
		s["good_days"] = 0
	return s


func _slot(c: Creature) -> int:
	return int(c.job.get("home", -1)) if c.job.has("village") and not c.job.has("hospitality") and c.route.is_empty() else -1


func register(c: Creature) -> void:
	var slot := _slot(c)
	if slot < 0:
		return
	var id := String(c.job["village"])
	var s := state(id)
	if slot >= int(s["base_homes"]) + (s["homes"] as Array).size() or (s["residents"] as Dictionary).has(str(slot)):
		return
	s["residents"][str(slot)] = c.id
	if slot >= int(s["base_homes"]):
		var home: Dictionary = s["homes"][slot - int(s["base_homes"])]
		if String(home.get("resident", "")) == "":
			home["resident"] = c.id
			s["population"] = int(s["population"]) + 1
	world.operation_creature(c)
	world.settlement_life._save(id)


func died(c: Creature) -> void:
	var slot := _slot(c)
	if slot < 0:
		return
	var id := String(c.job["village"])
	var s := state(id)
	var key := str(slot)
	if not (s["dead"] as Dictionary).has(key):
		s["dead"][key] = true
		s["population"] = maxi(0, int(s["population"]) - 1)
	s["leaving"].erase(key)
	s["departed"].erase(key)
	world.settlement_life._save(id)


func available(id: String, slot: int) -> bool:
	var s := state(id)
	var key := str(slot)
	if (s["dead"] as Dictionary).has(key) or (s["departed"] as Dictionary).has(key) or (s["leaving"] as Dictionary).has(key):
		return false
	if slot < int(s["base_homes"]):
		return slot >= 0
	var i := slot - int(s["base_homes"])
	return i < (s["homes"] as Array).size() and String(s["homes"][i].get("resident", "")) != ""


func scale(id: String, goods: Dictionary) -> Dictionary:
	var s := state(id)
	var base := int(s["base_homes"])
	var people := int(s["population"])
	if base == 0 or people == base:
		return goods
	var out := {}
	if people > 0:
		for item: String in goods:
			out[item] = maxi(1, roundi(float(goods[item]) * people / base))
	return out


func step(id: String) -> void:
	var s := state(id)
	var today := world.world_time / Daylight.DAY_MS
	if today <= int(s["people_day"]):
		return
	var days := mini(today - int(s["people_day"]), VillageEconomy.CATCH_UP)
	if today - int(s["people_day"]) > VillageEconomy.CATCH_UP:
		s["bad_days"] = 0
		s["good_days"] = 0
	s["people_day"] = today
	for key: String in (s["leaving"] as Dictionary).keys():
		var pending: Dictionary = s["leaving"][key]
		var loaded := world.creatures.get_creature(String(pending["id"]))
		var off_screen := loaded == null or not world.needed_within(world.creatures._chunk_of(loaded), CreatureSim.ACTIVE_TICKS)
		if off_screen and today > int(pending["day"]):
			var c := _person(String(pending["id"]))
			if c != null:
				finish_departure(c)
	var condition := world.economy.development(id)
	if String(condition["state"]) == "distressed" and String(condition["trend"]) == "distressed":
		s["bad_days"] = int(s["bad_days"]) + days
		s["good_days"] = 0
		if int(s["bad_days"]) >= LEAVE_DAYS and _depart(id):
			s["bad_days"] = 0
	elif String(condition["state"]) != "distressed" and String(condition["trend"]) != "distressed":
		s["good_days"] = int(s["good_days"]) + days
		s["bad_days"] = 0
		if int(s["good_days"]) >= RETURN_DAYS and _return_one(id):
			s["good_days"] = 0
	else:
		s["bad_days"] = 0
		s["good_days"] = 0
	for key: String in s["departed"]:
		var departure: Dictionary = s["departed"][key]
		if not departure.get("abandoned", false) and today - int(departure["day"]) >= ABANDON_DAYS:
			_damage(id, int(key), departure)
	populate(id)


func _person(cid: String) -> Creature:
	if world.creatures.has(cid):
		return world.creatures.get_creature(cid)
	if world._removed_items.has(cid):
		return null
	if world._entities.has(cid):
		var row: Array = world._entities[cid]
		return Creature.from_data(cid, String(row[0]), row[4])
	var saved := world.store.entity(cid)
	return Creature.from_data(cid, String(saved["location"]), Cbor.decode(saved["data"]).value) if not saved.is_empty() else null


func _depart(id: String) -> bool:
	var s := state(id)
	# Keep one household available for trade and player-led recovery. Death
	# remains unrestricted and never turns into an economic resurrection.
	if int(s["population"]) - (s["leaving"] as Dictionary).size() <= 1:
		return false
	var keys: Array = (s["residents"] as Dictionary).keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return int(a) > int(b))
	for key: String in keys:
		if not available(id, int(key)):
			continue
		var c := _person(String(s["residents"][key]))
		if c == null:
			continue
		var plan := world.settlement_life.plan(id)
		var exit := _exit(plan, c.cell())
		if exit == Creature.NO_TARGET:
			continue
		if world.creatures.has(c.id):
			c = world.creatures.get_creature(c.id)  # the exit lookup may have loaded its chunk
		s["leaving"][key] = {"id": c.id, "day": world.world_time / Daylight.DAY_MS}
		c.job["leave_to"] = [exit.x, exit.y]
		c.changed()
		if world.creatures.has(c.id):
			world.operation_creature(c)
		else:
			# An unloaded person completes the journey off screen, without
			# making its old chunk active merely to animate the departure.
			finish_departure(c)
		world.chronicles.note(id, "%s покидает поселение: длительная нехватка вынуждает искать другое место." % String(c.job.get("name", "Житель")))
		return true
	return false


func _exit(plan: Dictionary, from: Vector2i) -> Vector2i:
	var bounds: Rect2i = plan["bounds"]
	var centre: Vector2i = plan["centre"]
	var candidates: Array[Vector2i] = [Vector2i(bounds.position.x - 2, centre.y + 1), Vector2i(bounds.end.x + 2, centre.y + 1),
		Vector2i(centre.x, bounds.position.y - 2), Vector2i(centre.x, bounds.end.y + 2)]
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return world.cell_distance(from, a) < world.cell_distance(from, b))
	for at: Vector2i in candidates:
		if not world.is_solid("surface", at.x, at.y):
			return at
	return Creature.NO_TARGET


func finish_departure(c: Creature) -> void:
	var id := String(c.job["village"])
	var s := state(id)
	var key := str(int(c.job["home"]))
	if not (s["leaving"] as Dictionary).has(key):
		return
	var data := c.to_data()
	(data["job"] as Dictionary).erase("leave_to")
	s["departed"][key] = {"id": c.id, "data": data, "day": world.world_time / Daylight.DAY_MS, "damage": []}
	s["leaving"].erase(key)
	s["population"] = maxi(0, int(s["population"]) - 1)
	if world.creatures.has(c.id):
		world.creatures.remove(c.id)
	else:
		world.remove_entity(c.id, c.location, c.cell())
	world.settlement_life._save(id)


func _home(id: String, slot: int) -> Dictionary:
	var plan := world.settlement_life.plan(id)
	return plan["homes"][slot] if slot >= 0 and slot < (plan.get("homes", []) as Array).size() else {}


func _spawn_cell(home: Dictionary) -> Vector2i:
	var door: Vector2i = home["door"]
	var outward: Vector2i = ContentRegistry.FACINGS[SettlementArchitecture.facing(home.get("architecture", {}))]
	for distance in range(1, 5):
		var at := door + outward * distance
		if not world.is_solid("surface", at.x, at.y) and not world.settlement_life._occupied(at):
			return at
	return Creature.NO_TARGET


func _habitable(home: Dictionary) -> bool:
	var bed: Vector2i = home["bed"]
	return bed != Settlements.NONE and world.part_at("surface", bed.x, bed.y) == "base:bed"


func populate(id: String) -> void:
	var s := state(id)
	var condition := world.economy.development(id)
	if String(condition["state"]) == "distressed" or String(condition["trend"]) == "distressed":
		return
	for i in (s["homes"] as Array).size():
		var record: Dictionary = s["homes"][i]
		var slot := int(s["base_homes"]) + i
		if record.get("resident", "") != "" or (s["dead"] as Dictionary).has(str(slot)):
			continue
		var home := _home(id, slot)
		if not _habitable(home):
			continue
		var at := _spawn_cell(home)
		if at == Creature.NO_TARGET:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([world.world_seed, id, slot])
		var c := world.creatures._spawn("base:villager", "surface", at, CreatureSim.villager_looks(rng), rng.randi())
		c.home = home["bed"]
		c.job = {"village": id, "home": slot, "profession": home["dweller"], "name": world.chronicles.dweller_name(id, slot)[0]}
		c.changed()
		register(c)
		world.chronicles.note(id, "В новом доме теперь живёт %s; в поселении появился новый работник." % String(c.job["name"]))


func _damage(id: String, slot: int, departure: Dictionary) -> void:
	var plan := world.generator.settlements.plan_by_id(id)
	var home := _home(id, slot)
	var building := id + "|" + String(home["building_id"])
	var location := "surface"
	var rows: Array = []
	if slot >= int(state(id)["base_homes"]):
		var record: Dictionary = state(id)["homes"][slot - int(state(id)["base_homes"])]
		rows = record["upper"] if not (record["upper"] as Array).is_empty() else record["cells"]
		building = String(record["building"])
	else:
		var cells: Dictionary = plan["upper"].get(building, plan["cells"])
		for at: Vector2i in cells:
			if String((cells[at].get("props", {}) as Dictionary).get("building", "")) == building:
				rows.append([at.x, at.y, cells[at]])
	if world.levels.level(building, 1) != "":
		location = world.levels.level(building, 1)
	for row: Array in rows:
		var part := String(row[2].get("roof", ""))
		if part == "":
			continue
		var at := Vector2i(int(row[0]), int(row[1]))
		var c := world.chunk(location, at.x >> 5, at.y >> 5)
		var props := c.get_props(at.x & 31, at.y & 31).duplicate(true)
		if world.settlement_life._owned(props) or c.get_cell("roof", at.x & 31, at.y & 31) != part:
			continue
		props["settlement_damage"] = id + "|" + str(slot)
		c.set_cell("roof", at.x & 31, at.y & 31, "")
		c.set_props(at.x & 31, at.y & 31, props)
		world._changed(ServerWorld.chunk_key(location, at.x >> 5, at.y >> 5))
		(departure["damage"] as Array).append([location, at.x, at.y, part, c.get_cell("ground", at.x & 31, at.y & 31)])
		if (departure["damage"] as Array).size() >= ROOF_LOSS:
			break
	departure["abandoned"] = true
	var text := "Дом в поселении %s давно пустует."
	if not (departure["damage"] as Array).is_empty():
		text = "Опустевший дом в поселении %s приходит в запустение; повреждённая кровля требует ремонта."
	world.chronicles.note(id, text % world.chronicles.village_name(id))


func repair_demand(id: String) -> Dictionary:
	var out := {}
	for departure: Dictionary in (state(id)["departed"] as Dictionary).values():
		for row: Array in departure["damage"]:
			var at := Vector2i(int(row[1]), int(row[2]))
			if world.has_chunk(String(row[0]), at.x >> 5, at.y >> 5):
				var c := world.chunk(String(row[0]), at.x >> 5, at.y >> 5)
				if c.get_cell("roof", at.x & 31, at.y & 31) != "" or world.settlement_life._owned(c.get_props(at.x & 31, at.y & 31)):
					continue
			for item: String in world.content.structure_cost(String(row[3])):
				out[item] = int(out.get(item, 0)) + int(world.content.structure_cost(String(row[3]))[item])
	return out


func _repair(id: String, slot: int, departure: Dictionary) -> bool:
	var repair: Array = []
	var cost := {}
	for row: Array in departure["damage"]:
		var at := Vector2i(int(row[1]), int(row[2]))
		var c := world.chunk(String(row[0]), at.x >> 5, at.y >> 5)
		if c.get_cell("roof", at.x & 31, at.y & 31) != "":
			continue  # a player's replacement is already shelter; keep it
		var props := c.get_props(at.x & 31, at.y & 31)
		if world.settlement_life._owned(props) or props.get("settlement_damage", "") != id + "|" + str(slot):
			return false
		if row.size() > 4 and c.get_cell("ground", at.x & 31, at.y & 31) != String(row[4]):
			return false  # keep a floor/opening changed by a player
		repair.append(row)
		for item: String in world.content.structure_cost(String(row[3])):
			cost[item] = int(cost.get(item, 0)) + int(world.content.structure_cost(String(row[3]))[item])
	var wages := repair.size() * REPAIR_WAGE
	var store := world.economy.store(id)
	if int(store["coins"]) < wages + VillageEconomy.POOR:
		return false
	for item: String in cost:
		if int(store["stock"].get(item, 0)) < int(cost[item]) + int(world.economy.needs(id).get(item, 0)) * VillageEconomy.SHORT_DAYS:
			return false
	for item: String in cost:
		world.economy.take(id, item, int(cost[item]))
	if wages > 0:
		world.economy.earn(id, -wages)
	for row: Array in repair:
		var at := Vector2i(int(row[1]), int(row[2]))
		var c := world.chunk(String(row[0]), at.x >> 5, at.y >> 5)
		var props := c.get_props(at.x & 31, at.y & 31).duplicate(true)
		props.erase("settlement_damage")
		c.set_cell("roof", at.x & 31, at.y & 31, String(row[3]))
		c.set_props(at.x & 31, at.y & 31, props)
		world._changed(ServerWorld.chunk_key(String(row[0]), at.x >> 5, at.y >> 5))
	departure["damage"] = []
	return true


func _return_one(id: String) -> bool:
	var s := state(id)
	var keys: Array = (s["departed"] as Dictionary).keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		var da := int(s["departed"][a]["day"])
		var db := int(s["departed"][b]["day"])
		return da < db if da != db else int(a) < int(b))
	for key: String in keys:
		if (s["dead"] as Dictionary).has(key):
			continue
		var home := _home(id, int(key))
		if not _habitable(home):
			continue
		var at := _spawn_cell(home)
		if at == Creature.NO_TARGET:
			continue
		var departure: Dictionary = s["departed"][key]
		if not _repair(id, int(key), departure):
			continue
		var c := Creature.from_data(String(departure["id"]), "surface", departure["data"])
		c.pos = at * Movement.UNIT + Vector2i(128, 128)
		c.home = home["bed"]
		c.state = "idle"
		c.target = Creature.NO_TARGET
		c.last_time = world.world_time
		# A backpressured departure and return can share one operation. The
		# person's latest live state supersedes that still-pending deletion.
		world._removed_items.erase(c.id)
		world.creatures.add(c)
		c.changed()
		world.operation_creature(c)
		s["departed"].erase(key)
		s["population"] = int(s["population"]) + 1
		world.chronicles.note(id, "В свой дом возвращается %s: хозяйство снова позволяет жить и работать в поселении." % String(c.job.get("name", "Житель")))
		return true
	return false
