class_name Hospitality
extends RefCounted
## Food services and exclusive timed bed rentals. World facts and the
## ordinary request transaction keep payments/leases authoritative.
var world: ServerWorld
var _sites := {}
var _leases := {}
var services := {}

func _init(w: ServerWorld) -> void:
	world = w
	for id: String in w.content.defs:
		var d := w.content.get_def(id)
		if d.get("kind") == "hospitality" and d.get("mode") == "services":
			services = d
			break

func plan(id: String) -> Dictionary:
	return world.generator.settlements.inns.by_id(id) if world.generator else {}

func state(id: String) -> Dictionary:
	if not _sites.has(id):
		var text := world.fact("hospitality|" + id)
		var raw: Variant = JSON.parse_string(text) if text != "" else null
		_sites[id] = raw if raw is Dictionary else {}
	return _sites[id]

func arrived(location: String, chunk: Chunk) -> void:
	if location != Levels.SURFACE or not chunk.meta.has("hospitality"):
		return
	var id := String(chunk.meta["hospitality"])
	var saved := state(id)
	if not saved.is_empty():
		return
	var p := plan(id)
	if p.is_empty():
		return
	var upper := ""
	if not p["upper"].is_empty():
		upper = world.levels.level(id, 1)
		if upper == "":
			upper = world.levels.create_level(id, 1)
		for at: Vector2i in p["upper"]:
			var c := world.chunk(upper, at.x >> 5, at.y >> 5)
			var spec: Dictionary = p["upper"][at]
			for layer: String in ["ground", "cover", "structure", "roof"]:
				c.set_cell(layer, at.x & 31, at.y & 31, String(spec.get(layer, "")))
			c.set_props(at.x & 31, at.y & 31, spec["props"].duplicate(true))
			world._changed(ServerWorld.chunk_key(upper, at.x >> 5, at.y >> 5))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world.world_seed, id, "host"])
	var host := world.creatures._spawn("base:villager", Levels.SURFACE, p["host"], CreatureSim.villager_looks(rng), rng.randi())
	host.job = {"hospitality": id, "village": p["village"], "home": -1 - absi(hash(id)) % 1000000,
		"profession": "base:innkeeper", "name": world.chronicles.dweller_name(String(p["village"]), 90 + rng.randi_range(0, 8))[0], "purse": 60}
	world.operation_creature(host)
	_sites[id] = {"host": host.id, "upper": upper, "closed": false}
	world.operation_fact("hospitality|" + id, JSON.stringify(_sites[id]))

func died(c: Creature) -> void:
	var id := String(c.job.get("hospitality", ""))
	if id == "":
		return
	state(id)["closed"] = true
	world.operation_fact("hospitality|" + id, JSON.stringify(state(id)))

func think(c: Creature) -> void:
	var p := plan(String(c.job["hospitality"]))
	if p.is_empty():
		return
	var sim := world.creatures
	var attacker := sim._attacker(c, 12.0)
	if not attacker.is_empty():
		var away := sim._away_from(c, attacker[0], 16.0)
		if away != Creature.NO_TARGET:
			c.path.clear()
			sim._dress(c, "", false)
			sim._go(c, "flee", away, true)
			return
	var spot: Vector2i = p["host"]
	if c.cell() == spot:
		sim._dress(c, "", false)
		sim._look(c, Vector2i.DOWN)
		sim._go(c, "host", Creature.NO_TARGET, false)
		if sim._someone_close(c, 3) and (c.said_at < 0 or sim._tick - c.said_at > 20 * Movement.TICK_RATE):
			sim._speak(c, world.content.get_def("base:innkeeper"), "work")
	else:
		if c.path_to != spot or c.path.is_empty():
			c.path = sim._route(c, spot)
			c.path_to = spot
		while not c.path.is_empty() and c.path[0] == c.cell():
			c.path.pop_front()
		if not c.path.is_empty():
			sim._open_doors(c, c.cell(), c.path[0])
			sim._go(c, "walk", c.path[0], false)

func visitor_spot(c: Creature) -> Vector2i:
	var home := int(c.job.get("home", -1))
	if home < 0 or home % 2 != 0:
		return Creature.NO_TARGET
	var best := {}
	for id: String in _sites:
		var p := plan(id)
		if p.is_empty() or state(id).is_empty() or state(id).get("closed", false) or p["village"] != c.job.get("village", "") \
				or world.cell_distance(c.home, p["centre"]) > 100 or home / 2 >= p["seats"].size():
			continue
		var at: Vector2i = p["host"]
		if not world.has_chunk(Levels.SURFACE, at.x >> 5, at.y >> 5):
			continue
		if best.is_empty() or world.cell_distance(c.home, p["centre"]) < world.cell_distance(c.home, best["centre"]):
			best = p
	return best["seats"][home / 2] if not best.is_empty() else Creature.NO_TARGET

func is_seat(location: String, at: Vector2i) -> bool:
	return bool(world.content.get_def(world.part_at(location, at.x, at.y)).get("seat", false))

func camp_spot(c: Creature) -> Vector2i:
	for id: String in _sites:
		var p := plan(id)
		if p.is_empty() or state(id).is_empty() or state(id).get("closed", false) or p["road"] != c.route.get("road", []) \
				or world.cell_distance(c.cell(), p["camp_spot"]) > 36:
			continue
		return p["camp_spot"]
	return Creature.NO_TARGET

func places(at: Vector2i, radius: int) -> Array:
	var out := []
	if world.generator == null:
		return out
	for p: Dictionary in world.generator.settlements.inns.near(at, radius):
		var host: Vector2i = p["host"]
		var key := world.storage_key(Levels.SURFACE, host.x >> 5, host.y >> 5)
		var c := world._chunks.get(key) as Chunk
		if c == null:
			var where := world.storage_chunk(host.x >> 5, host.y >> 5)
			var bytes := world.store.get_chunk(Levels.SURFACE, where.x, where.y)
			if not bytes.is_empty():
				c = ChunkCodec.decode(bytes)
		if c != null and c.meta.get("hospitality", "") != p["id"]:
			continue  # an old saved chunk must not advertise a nonexistent house
		var door: Vector2i = p["door"]
		out.append({"name": "%s «%s»%s" % ["Таверна" if p["site"] == "tavern" else "Постоялый двор", p["name"],
			" (закрыто)" if state(String(p["id"])).get("closed", false) else ""], "x": door.x, "y": door.y, "kind": p["site"]})
	return out

func _lease_key(id: String, bed: int) -> String:
	return "lodging|%s|%d" % [id, bed]

func lease(id: String, bed: int) -> Dictionary:
	var key := _lease_key(id, bed)
	if not _leases.has(key):
		var text := world.fact(key)
		var raw: Variant = JSON.parse_string(text) if text != "" else null
		_leases[key] = raw if raw is Dictionary else {}
		if not _leases[key].is_empty():
			_leases[key]["until"] = int(_leases[key].get("until", 0))
	return _leases[key]

func bed_location(p: Dictionary, bed: Dictionary) -> String:
	return Levels.SURFACE if int(bed["z"]) == 0 else String(state(String(p["id"])).get("upper", ""))

func sleep_reason(actor: String, location: String, at: Vector2i) -> String:
	var props := world._props_at(location, at.x, at.y)
	if not props.has("inn_bed"):
		return ""
	var rented := lease(String(props.get("hospitality", "")), int(props["inn_bed"]))
	if int(rented.get("until", 0)) <= world.world_time:
		return "rent_first"
	return "" if rented.get("actor", "") == actor else "bed_rented"

func rest_rate(actor: String) -> float:
	var p: Dictionary = world.present[actor]
	var at := Movement.cell_of(p["pos"])
	var props := world._props_at(String(p["location"]), at.x, at.y)
	if not props.has("inn_bed") or sleep_reason(actor, String(p["location"]), at) != "":
		return 1.0
	return float(lease(String(props.get("hospitality", "")), int(props["inn_bed"])).get("rest", 1))

func terms(actor: String, c: Creature) -> Array:
	var out := []
	var p := plan(String(c.job["hospitality"]))
	if p.is_empty():
		return out
	var coins := world.inventory(actor).count("base:coin")
	for meal: Dictionary in services.get("menu", []):
		var food: Dictionary = world.content.get_def(String(meal["item"]))["food"]
		out.append({"kind": "meal", "id": meal["id"], "name": meal["name"], "price": int(meal["price"]),
			"satiety": int(food.get("satiety", 0)), "heal": int(food.get("heal", 0)), "why": "no_money" if coins < int(meal["price"]) else ""})
	for i in p["beds"].size():
		var bed: Dictionary = p["beds"][i]
		var rented := lease(String(p["id"]), i)
		for lodging: Dictionary in services.get("lodging", []):
			if lodging["id"] != bed["kind"]:
				continue
			var occupied := int(rented.get("until", 0)) > world.world_time
			var loc := bed_location(p, bed)
			var props := world._props_at(loc, int(bed["x"]), int(bed["y"])) if loc != "" else {}
			var exists: bool = props.get("hospitality", "") == p["id"] and int(props.get("inn_bed", -1)) == i \
				and world.content.get_def(world.part_at(loc, int(bed["x"]), int(bed["y"]))).get("bed", false)
			out.append({"kind": "bed", "id": str(i), "name": "%s, кровать %d" % [lodging["name"], i + 1],
				"price": int(lodging["price"]), "hours": float(lodging["hours"]), "z": int(bed["z"]),
				"why": "no_bed" if not exists else ("already_rented" if occupied and rented.get("actor", "") == actor else ("bed_rented" if occupied else ("no_money" if coins < int(lodging["price"]) else ""))),
				"until": int(rented.get("until", 0)), "mine": occupied and rented.get("actor", "") == actor})
	return out

func buy(actor: String, r: Dictionary) -> Dictionary:
	var found := world._dweller(actor, r)
	if found[0] == null:
		return {"ok": false, "reason": found[1]}
	var c: Creature = found[0]
	if not c.job.has("hospitality") or world.chronicles.bears_grudge(c, actor):
		return {"ok": false, "reason": "not_now"}
	var choice := {}
	for t: Dictionary in terms(actor, c):
		if t["kind"] == r.get("service", "") and t["id"] == r.get("choice", ""):
			choice = t
			break
	if choice.is_empty():
		return {"ok": false, "reason": "bad_request"}
	if choice["why"] != "":
		return {"ok": false, "reason": choice["why"]}
	var notice := ""
	if choice["kind"] == "meal":
		for meal: Dictionary in services["menu"]:
			if meal["id"] == choice["id"]:
				var result := world.eat_food(actor, String(meal["item"]), false)
				if not result.get("ok", false):
					return result
				notice = "Вы поели. Сытость: %d из 100." % int(result["satiety"])
	else:
		var id := String(c.job["hospitality"])
		var n := int(choice["id"])
		for lodging: Dictionary in services["lodging"]:
			if lodging["id"] != plan(id)["beds"][n]["kind"]:
				continue
			var until := world.world_time + int(float(lodging["hours"]) * Daylight.HOUR_MS)
			var key := _lease_key(id, n)
			_leases[key] = {"actor": actor, "until": until, "rest": lodging.get("rest", 1)}
			world.operation_fact(key, JSON.stringify(_leases[key]))
			notice = "Ваша кровать — №%d, %s. Аренда на %.0f ч., до дня %d, %02d:%02d. Можно лечь и быстро восстановить силы." % [
					n + 1, "наверху" if int(choice["z"]) > 0 else "на первом этаже", float(choice["hours"]),
					until / Daylight.DAY_MS + 1, int(Daylight.hour_of(until)), int(Daylight.hour_of(until) * 60) % 60]
	world.inventory(actor).remove("base:coin", int(choice["price"]))
	world.touch_inventory(actor)
	c.job["purse"] = int(c.job.get("purse", 0)) + int(choice["price"])
	world.operation_creature(c)
	var out := world._talk(actor, {"creature": c.id}, "talk")
	out["notice"] = notice
	return out

func ensure_work(c: Creature) -> void:
	if not world.chronicles.request_of(c).is_empty():
		return
	var id := String(c.job["hospitality"])
	var village := String(c.job["village"])
	var v := world.chronicles.of(village)
	for story: String in services.get("work", []):
		if v["requests"].any(func(r: Dictionary) -> bool: return r.get("asker_id", "") == c.id and r["story"] == story):
			continue
		var extra := {"inn": plan(id).get("name", "Постоялый двор")}
		var destination := ""
		if world.content.get_def(story)["request"]["kind"] == "deliver":
			var neighbours := world.economy.neighbours(village)
			if neighbours.is_empty():
				continue
			destination = neighbours[0]
			extra["destination"] = world.chronicles.village_name(destination)
		world.chronicles.offer_from(c, story, extra, destination)
		return

func decorate(out: Dictionary, actor: String, c: Creature) -> void:
	var p := plan(String(c.job["hospitality"]))
	if p.is_empty():
		return
	out["name"] = c.job.get("name", "Тавернщик")
	out["establishment"] = p["name"]
	if out.get("grudge", false):
		return
	ensure_work(c)
	var request := world.chronicles.request_of(c)
	if not request.is_empty() and world.chronicles.delivery_for(c, actor).is_empty():
		out["request"] = world.chronicles.shown(String(c.job["village"]), request, actor, String(c.job["village"]))
	out["services"] = terms(actor, c)
	if not out.has("thanks"):
		out["says"] = "Добро пожаловать в «%s». Горячая еда, ночлег и новости с дорог. " % p["name"] \
			+ String(out.get("request", {}).get("says", "Если нужна помощь — подходи."))
	out["chronicle"] = news(c, out.get("chronicle", []))

## News adapter: only chronicles, real shortages and existing road links.
## Future event sources can add their accounts here without changing dialogue.
func news(c: Creature, local: Array) -> Array:
	var out := local.duplicate()
	for village: String in world.economy.neighbours(String(c.job["village"])):
		out.append("Местная дорога ведёт в деревню %s." % world.chronicles.village_name(village))
		var lacking := world.economy.short(village)
		if not lacking.is_empty():
			out.append("В деревне %s не хватает: %s." % [world.chronicles.village_name(village), ", ".join(lacking.map(func(item: String) -> String: return String(world.content.get_def(item).get("name", item)).to_lower()))])
		var entries: Array = world.chronicles.told(world.chronicles.of(village))
		if not entries.is_empty():
			out.append("Из деревни %s: %s" % [world.chronicles.village_name(village), entries.back()])
	return out
