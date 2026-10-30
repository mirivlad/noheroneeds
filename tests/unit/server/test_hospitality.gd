extends TestCase
var w: ServerWorld
var p: Dictionary
var host: Creature
var actor: String
var pc: PortableCharacter
var db: String

func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 431})
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var plans := s.inns.of_cluster(0, district.x, district.y)
	p = plans[0]
	for candidate: Dictionary in plans:
		if candidate["site"] == "inn":
			p = candidate
	var at: Vector2i = p["host"]
	w.chunk("surface", at.x >> 5, at.y >> 5)
	host = w.creatures.get_creature(String(w.hospitality.state(String(p["id"]))["host"]))
	pc = PortableCharacter.create("Гость", "base:human_ro_m")
	w.enter("guest", pc)
	actor = pc.character_id
	w.move_character(actor, host.pos + Vector2i(0, 512))
	w.grant(actor, "base:coin", 60)

func after_each() -> void:
	w.close()

func _request(r: Dictionary, who := "") -> Dictionary:
	if not r.has("request_id"):
		r["request_id"] = Uuid.v4()
	who = actor if who == "" else who
	w.handle(who, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[0] == who and ack[1] == r["request_id"]:
			return ack[2]
	return {}

func _service(kind: String, choice: String, who := "") -> Dictionary:
	return _request({"type": "inn_service", "creature": host.id, "service": kind, "choice": choice}, who)

func test_meals_apply_existing_food_once_without_resellable_items_or_containers() -> void:
	w.needs.set_satiety(actor, 20)
	var r := {"type": "inn_service", "creature": host.id, "service": "meal", "choice": "bread", "price": 0, "request_id": "bread-once"}
	check(_request(r).get("ok", false), "food service accepted")
	_request(r)
	eq(w.inventory(actor).count("base:coin"), 57, "the content's fixed price, paid once")
	eq(w.needs.satiety_of(actor), 60.0)
	eq(w.inventory(actor).count("base:bread"), 0, "food is eaten at the host's")
	w.needs.set_satiety(actor, 20)
	check(_service("meal", "milk").get("ok", false), "drink served")
	eq(w.inventory(actor).count("base:milk_bucket"), 0)
	eq(w.inventory(actor).count("base:bucket"), 0, "no free container from a house drink")
	w.needs.set_satiety(actor, 100)
	var coins := w.inventory(actor).count("base:coin")
	eq(_service("meal", "bread").get("reason"), "not_hungry")
	eq(w.inventory(actor).count("base:coin"), coins, "a rejected meal is not charged")

func test_services_reject_missing_funds_and_invalid_choices() -> void:
	w.inventory(actor).remove("base:coin", 60)
	w.needs.set_satiety(actor, 10)
	eq(_service("meal", "stew").get("reason"), "no_money")
	eq(_service("bed", "0").get("reason"), "no_money")
	eq(_service("meal", "free-feast").get("reason"), "bad_request")
	eq(w.needs.satiety_of(actor), 10.0)

func test_rental_is_exclusive_restores_energy_and_expires_without_world_time_skip() -> void:
	var other := PortableCharacter.create("Другой гость", "base:human_ro_m")
	w.enter("other", other)
	w.move_character(other.character_id, host.pos + Vector2i(256, 512))
	w.grant(other.character_id, "base:coin", 60)
	var bed: Dictionary = p["beds"][0]
	var loc := w.hospitality.bed_location(p, bed)
	var at := Vector2i(int(bed["x"]), int(bed["y"]))
	eq(w.hospitality.sleep_reason(actor, loc, at), "rent_first")
	var now := w.world_time
	var rented := _service("bed", "0")
	check(rented.get("ok", false), str(rented))
	eq(w.world_time, now, "renting does not advance the shared clock")
	eq(_service("bed", "0", other.character_id).get("reason"), "bed_rented")
	eq(w.inventory(other.character_id).count("base:coin"), 60)
	eq(_service("bed", "0").get("reason"), "already_rented")
	w.present[actor]["location"] = loc
	w.move_character(actor, at * 256 + Vector2i(128, 128))
	w.needs.set_energy(actor, 10)
	check(_request({"type": "sleep", "location": loc, "x": at.x, "y": at.y}).get("ok", false), "the rented bed uses ordinary sleep")
	eq(w.world_time, now, "sleep does not skip time for anyone else")
	w.needs._last_time = now
	w.world_time += int(Daylight.HOUR_MS * .1)
	w.needs.step()
	check(w.needs.energy_of(actor) > 30, "a comfortable paid bed restores energy promptly")
	var until := int(w.hospitality.lease(String(p["id"]), 0)["until"])
	w.world_time = until + 1
	w.needs._last_time = w.world_time - 1
	w.needs.set_energy(actor, 10)
	w.needs.step()
	check(not w.needs.asleep(actor), "expiry wakes the guest, not the whole server")
	eq(w.hospitality.sleep_reason(actor, loc, at), "rent_first")
	check(_service("bed", "0", other.character_id).get("ok", false), "the bed can be rented by the next guest")

func test_rental_payments_host_and_upper_floor_survive_restart_without_duplicates() -> void:
	check(_service("bed", "0").get("ok", false), "rented")
	var host_id := host.id
	var saved := w.hospitality.lease(String(p["id"]), 0).duplicate()
	var upper := String(w.hospitality.state(String(p["id"])).get("upper", ""))
	w.sync()
	w.close()
	w = ServerWorld.open(db, w.content)
	var at: Vector2i = p["host"]
	w.chunk("surface", at.x >> 5, at.y >> 5)
	eq(w.hospitality.lease(String(p["id"]), 0), saved)
	eq(String(w.hospitality.state(String(p["id"]))["host"]), host_id)
	eq(String(w.hospitality.state(String(p["id"])).get("upper", "")), upper)
	var hosts := w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.job.get("hospitality", "") == p["id"])
	eq(hosts.size(), 1, "a saved owner is not spawned again")
	eq(w.inventory(actor).count("base:coin"), 54, "the payment survives restart")
	check(upper != "", "this fixture has working upstairs rooms")

func test_owner_returns_to_its_counter_after_unloading_and_is_not_replaced_after_death() -> void:
	var at: Vector2i = p["host"]
	w.world_time = 23 * Daylight.HOUR_MS
	host.pos += Vector2i(5, 3) * Movement.UNIT
	w.creatures._catch_up(host, w.content.get_def(host.kind))
	eq(host.cell(), at, "the innkeeper never catches up at another villager's bed")
	w.creatures.remove(host.id)
	w.sync()
	w.close()
	w = ServerWorld.open(db, w.content)
	w.chunk("surface", at.x >> 5, at.y >> 5)
	check(w.hospitality.state(String(p["id"])).get("closed", false), "the owner stays dead")
	check(not w.creatures.creatures.values().any(func(c: Creature) -> bool: return c.job.get("hospitality", "") == p["id"]), "there is no replacement owner")

func test_ordinary_stairs_reach_the_rented_upstairs_bed_and_return() -> void:
	var stairs := Vector2i.MAX
	for at: Vector2i in p["cells"]:
		if p["cells"][at].get("structure", "") == "base:wood_stairs":
			stairs = at
	if not check(stairs != Vector2i.MAX, "generated inn has stairs"):
		return
	check(_service("bed", "0").get("ok", false), "rented before going upstairs")
	w.move_character(actor, (stairs + Vector2i.DOWN) * 256 + Vector2i(128, 128))
	var up := _request({"type": "climb", "location": "surface", "x": stairs.x, "y": stairs.y, "dir": "up"})
	check(up.get("ok", false), str(up))
	var upper := String(w.present[actor]["location"])
	eq(w.levels.z(upper), 1)
	var bed: Dictionary = p["beds"][0]
	w.move_character(actor, Vector2i(int(bed["x"]), int(bed["y"])) * 256 + Vector2i(128, 128))
	w.needs.set_energy(actor, 20)
	check(_request({"type": "sleep", "location": upper, "x": int(bed["x"]), "y": int(bed["y"])}).get("ok", false), "ordinary sleep upstairs")
	w.wake(actor)
	w.move_character(actor, (stairs + Vector2i.UP) * 256 + Vector2i(128, 128))
	var down := _request({"type": "climb", "location": upper, "x": stairs.x, "y": stairs.y, "dir": "down"})
	check(down.get("ok", false), str(down))
	eq(String(w.present[actor]["location"]), "surface")

func test_three_host_jobs_pay_once_and_delivery_survives_reentry() -> void:
	var talk := _request({"type": "talk", "creature": host.id})
	eq(talk.get("request", {}).get("kind"), "fetch")
	for item: String in ["base:berries", "base:log"]:
		check(_request({"type": "promise", "creature": host.id}).get("ok", false), "take the host's real errand")
		w.grant(actor, item, 3 if item == "base:berries" else 2)
		var request := {"type": "report", "creature": host.id, "request_id": "report-" + item}
		var report := _request(request)
		check(report.get("ok", false), str(report))
		var coins := w.inventory(actor).count("base:coin")
		_request(request)
		eq(w.inventory(actor).count("base:coin"), coins, "no repeated errand reward")
	eq(w.inventory(actor).count("base:coin"), 74, "berries and firewood pay first coins")
	var accepted := _request({"type": "promise", "creature": host.id})
	eq(accepted.get("request", {}).get("kind"), "deliver")
	eq(w.inventory(actor).count("base:inn_letter"), 1)
	var delivery := w.chronicles.request_of(host).duplicate(true)
	var destination := String(delivery["destination"])
	check(destination != String(host.job["village"]), "a letter goes to another real village")
	w.sync()
	w.close()
	w = ServerWorld.open(db, w.content)
	w.enter("guest", pc)
	var journal := w.chronicles.journal(actor)
	check(journal.get("requests", []).any(func(r: Dictionary) -> bool: return r["kind"] == "deliver"), "journal remembers village IDs containing commas")
	var village := w.generator.settlements.plan_by_id(destination)
	var bed: Vector2i = village["homes"][0]["bed"]
	w.chunk("surface", bed.x >> 5, bed.y >> 5)
	var receiver: Creature
	var pubs := w.generator.settlements.inns.near(village["centre"], 100).filter(func(site: Dictionary) -> bool: return site["village"] == destination)
	if not pubs.is_empty():
		var counter: Vector2i = pubs[0]["host"]
		w.chunk("surface", counter.x >> 5, counter.y >> 5)
		receiver = w.creatures.get_creature(String(w.hospitality.state(String(pubs[0]["id"]))["host"]))
	for c: Creature in w.creatures.creatures.values():
		if receiver == null and c.job.get("village", "") == destination and int(c.job.get("home", -1)) == 0:
			receiver = c
	if not check(receiver != null, "actual resident can receive the letter"):
		return
	receiver.asleep = false
	w.move_character(actor, receiver.pos + Vector2i(256, 0))
	var greeting := _request({"type": "talk", "creature": receiver.id})
	eq(greeting.get("request", {}).get("state"), "ready")
	var report := {"type": "report", "creature": receiver.id, "request_id": "delivered-once"}
	check(_request(report).get("ok", false), "delivered through the normal conversation")
	_request(report)
	eq(w.inventory(actor).count("base:coin"), 86, "delivery paid once after reopening the world")
	eq(w.inventory(actor).count("base:inn_letter"), 0, "the matching parcel was handed over")

func test_host_teaches_cooking_and_neighbours_news_are_real() -> void:
	w.chronicles.note(String(host.job["village"]), "Настоящая запись проверки: волк отогнан от загона.")
	var talk := _request({"type": "talk", "creature": host.id})
	check(talk.get("chronicle", []).any(func(text: String) -> bool: return text.contains("волк отогнан")), "actual chronicle supplies news")
	for lesson: Dictionary in talk.get("teaches", []):
		check(lesson["recipe"] in ["base:bake_bread", "base:cook_stew"], "the host is not a universal smithing teacher")
	w.chronicles._trust(w.chronicles.of(String(host.job["village"])), actor, 1)
	var learned := _request({"type": "learn", "creature": host.id, "recipe": "base:cook_stew"})
	check(learned.get("ok", false), str(learned))
	check(w.knowledge.knows(actor, "base:cook_stew"), "ordinary knowledge learned")
	eq(w.inventory(actor).count("base:coin"), 50)
	eq(_request({"type": "learn", "creature": host.id, "recipe": "base:forge_iron_sword"}).get("reason"), "not_taught")

func test_existing_dwellers_visit_the_tavern_after_work_and_go_home() -> void:
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	var taverns := s.inns.of_cluster(0, district.x, district.y).filter(func(site: Dictionary) -> bool: return site["site"] == "tavern")
	if not check(not taverns.is_empty(), "a village tavern exists"):
		return
	var pub: Dictionary = taverns[0]
	var village := s.plan_by_id(String(pub["village"]))
	var area: Rect2i = (village["bounds"] as Rect2i).merge(pub["bounds"]).grow(5)
	for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
		for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
			w.chunk("surface", cx, cy)
	w.world_time = int(19.8 * Daylight.HOUR_MS)
	for tick in 1200:
		w.tick += 1
		for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
			for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
	var visitors := w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.state == "visit" and (pub["rect"] as Rect2i).has_point(c.cell()))
	check(visitors.size() >= 2, "existing villagers sit at the actual tables")
	for c: Creature in visitors:
		check(c.job.get("village", "") == pub["village"] and int(c.job.get("home", -1)) >= 0, "visitors are existing residents")
	w.world_time = 23 * Daylight.HOUR_MS
	for c: Creature in visitors:
		w.creatures._dweller(c, w.content.get_def(c.kind))
		check(c.state != "visit", "after closing time residents leave for home")

func test_road_caravan_uses_the_inn_yard_without_pitching_a_campfire() -> void:
	var at: Vector2i = p["camp_spot"]
	for cy in range((at.y - 12) >> 5, ((at.y + 12) >> 5) + 1):
		for cx in range((at.x - 12) >> 5, ((at.x + 12) >> 5) + 1):
			w.chunk("surface", cx, cy)
	var trader := w.creatures._spawn("base:villager", "surface", at, {}, 17)
	trader.job = {"profession": "base:trader", "purse": 80}
	trader.route = {"road": p["road"], "step": 1, "i": 0}
	trader.face = Vector2i.DOWN
	w.creatures._make_caravan(trader, "cart")
	w.caravans.rest(trader)
	eq(trader.job.get("camp_spot"), [at.x, at.y], "the existing rest interface chooses the inn's yard")
	check(trader.job.get("rest_in_village", false) and trader.asleep, "the caravan rests at a public house")
	check(not trader.job.has("campfire"), "no redundant temporary fire in the inn yard")
	eq(w.inventory("supplies|" + trader.id).count("base:log"), 4)
	var horse := w.creatures.get_creature(String(trader.job["horse"]))
	for cell: Vector2i in BodySize.cells(horse.pos, BodySize.of(w.content.get_def(horse.kind))["half"]):
		check(not w.is_solid("surface", cell.x, cell.y), "the yard fits the actual horse and harness")

func _visit_yard(variant: String) -> void:
	var key: Array = p["road"]
	var road := w.generator.settlements.road_of(int(key[0]), int(key[1]), int(key[2]), int(key[3]))
	var path: Array = road["path"]
	var at: Vector2i = p["camp_spot"]
	var index := 0
	for i in path.size():
		if at.distance_to(path[i]) < at.distance_to(path[index]):
			index = i
	var start: Vector2i = path[index]
	var area := Rect2i(start, Vector2i.ONE).merge(p["bounds"]).grow(16)
	for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
		for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
			w.chunk("surface", cx, cy)
	var trader := w.creatures._spawn("base:villager", "surface", start, {}, 17)
	trader.route = {"road": p["road"], "step": 1, "i": index}
	trader.face = path[mini(index + 1, path.size() - 1)] - start
	trader.job = {"profession": "base:trader", "from": road["from"], "toward": road["to"], "purse": 300}
	w.creatures._make_caravan(trader, variant)
	w.caravans.hire(trader, 40)
	w.world_time = 23 * Daylight.HOUR_MS
	for tick in 1600:
		w.tick += 1
		for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
			for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
		if trader.asleep:
			break
	check(trader.asleep and trader.cell().distance_to(at) <= 1, "%s reaches the actual inn yard from its road: %s" % [variant, trader.cell()])
	check(not trader.job.has("campfire"), "a successful inn arrival uses the house's rest stop")
	w.world_time = 12 * Daylight.HOUR_MS
	for tick in 1000:
		w.tick += 1
		for cy in range(area.position.y >> 5, (area.end.y >> 5) + 1):
			for cx in range(area.position.x >> 5, (area.end.x >> 5) + 1):
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
		if trader.cell().distance_to(at) > 12:
			break
	check(not trader.asleep and not trader.job.has("camp_spot"), "morning ends the overnight stop")
	check(trader.cell().distance_to(at) > 12, "%s leaves the yard and continues along its road" % variant)
	for id: String in w.caravans.guards(trader):
		check(w.creatures.get_creature(id).cell().distance_to(trader.cell()) < 12, "guards leave with the trader")

func test_cart_visits_the_real_inn_yard_and_resumes_with_guards() -> void:
	_visit_yard("cart")

func test_pack_caravan_visits_the_real_inn_yard_and_resumes_with_guards() -> void:
	_visit_yard("pack")
