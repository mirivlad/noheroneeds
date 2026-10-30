extends TestCase
## ADR-0042: a village remembers — its past (a founding; a rock-seeker lost
## in a real cave near it, what he carried really lying there), predators
## come close, the seasons, a dweller struck or killed — and its dwellers
## ask what grows out of it: hunt what was seen, fetch what is short, find
## what was lost. Done, the deed is written down too.

const AMULETS := ["base:garnet_amulet", "base:amethyst_amulet"]

var w: ServerWorld
var _db := ""
var _content: ContentRegistry
var plan: Dictionary
var id := ""


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 12345})
	plan = w.generator.settlements.home_plan()
	id = String(plan["id"])
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
		for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
			w.chunk("surface", cx, cy)


func after_each() -> void:
	w.close()


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _player(name: String, near: Creature) -> String:
	var pc := PortableCharacter.create(name, "base:human_f")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + pc.character_id, pc)
	var at: Vector2i = near.pos if near else (plan["centre"] as Vector2i) * Movement.UNIT
	w.move_character(pc.character_id, at + Vector2i(Movement.UNIT, 0))
	return pc.character_id


func _dweller(home: int) -> Creature:
	for c: Creature in w.creatures.creatures.values():
		if String(c.job.get("village", "")) == id and int(c.job.get("home", -1)) == home:
			return c
	return null


func _of_trade(profession: String) -> Creature:
	for c: Creature in w.creatures.creatures.values():
		if String(c.job.get("village", "")) == id and String(c.job.get("profession", "")) == profession:
			return c
	return null


func _texts() -> String:
	return "\n".join(PackedStringArray((w.chronicles.of(id)["entries"] as Array).map(func(e: Dictionary) -> String: return String(e["text"]))))


func test_a_village_has_a_name_a_past_and_a_thing_lost_in_a_real_cave() -> void:
	var v := w.chronicles.of(id)
	check((_content.get_def("base:folk_names")["villages"] as Array).has(v["name"]), "a village's name: %s" % v["name"])
	check(_texts().contains("Так началась деревня " + String(v["name"])), "its founding: " + _texts())
	var find: Array = (v["requests"] as Array).filter(func(r: Dictionary) -> bool: return r["kind"] == "find")
	eq(find.size(), 1, "the spawn's cave is near: a rock-seeker was lost in it")
	var spot := Vector2i(int(find[0]["spot"][0]), int(find[0]["spot"][1]))
	w.chunk(Levels.depth_id(-1), floori(spot.x / 32.0), floori(spot.y / 32.0))
	var lying := ""
	for i: String in w.items:
		if w.items[i]["item"] == find[0]["item"]:
			lying = i
	check(lying != "", "what he carried lies in the world")
	eq(w.items[lying]["location"], Levels.depth_id(-1), "below, in the cave")
	var at := Vector2i(int(w.items[lying]["x"]), int(w.items[lying]["y"])) / Movement.UNIT
	check(w.underground.is_cave(at.x, at.y, -1), "on the cave's floor, not in rock")
	for c: Creature in w.creatures.creatures.values():
		if String(c.job.get("village", "")) == id and not c.job.has("hospitality"):
			eq(String(c.job["name"]), String(w.chronicles.dweller_name(id, int(c.job["home"]))[0]), "a dweller has its name")
	w.close()
	w = ServerWorld.open(_db, _content)
	eq(String(w.chronicles.of(id)["name"]), String(v["name"]), "kept over a restart")
	eq((w.chronicles.of(id)["entries"] as Array).size(), (v["entries"] as Array).size())
	w.chunk(Levels.depth_id(-1), floori(at.x / 32.0), floori(at.y / 32.0))
	check(w.items.values().any(func(it: Dictionary) -> bool: return AMULETS.has(String(it["item"]))),
		"things lie until a restart (ADR-0016), the lost thing lies there again once its place is loaded")
	eq((w.chronicles.of(id)["requests"] as Array).filter(func(x: Dictionary) -> bool: return x["kind"] == "find").size(), 1,
		"and is not lost twice")
	# Picked up and carried: it does not lie there again, not after a restart.
	var a := _player("Аня", null)
	for i: String in w.items.keys():
		if AMULETS.has(String(w.items[i]["item"])):
			w.take_item(i, w.inventory(a))
			w.touch_inventory(a)
			w.chronicles.picked(a, String(find[0]["item"]))
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk(Levels.depth_id(-1), floori(spot.x / 32.0), floori(spot.y / 32.0))
	check(not w.items.values().any(func(it: Dictionary) -> bool: return AMULETS.has(String(it["item"]))),
		"not twice: the one who picked it up has it")


func test_a_lost_thing_taken_on_found_and_brought_back() -> void:
	var r: Dictionary = (w.chronicles.of(id)["requests"] as Array).filter(func(x: Dictionary) -> bool: return x["kind"] == "find")[0]
	var asker := _dweller(int(r["asker"]))
	check(asker != null, "who asks is about")
	var a := _player("Аня", asker)
	var t := _req(a, {"type": "talk", "creature": asker.id})
	check(t.get("ok", false), str(t))
	eq(t["name"], asker.job["name"])
	eq(t["request"]["state"], "offered")
	check(String(t["request"]["says"]).contains("пещеру"), "it tells of the cave: " + String(t["request"]["says"]))
	check(not (t["chronicle"] as Array).is_empty(), "and of the village")
	eq(_req(a, {"type": "report", "creature": asker.id}).get("reason"), "not_taken")
	t = _req(a, {"type": "promise", "creature": asker.id})
	eq(t["request"]["state"], "doing", "taken on")
	eq(_req(a, {"type": "report", "creature": asker.id}).get("reason"), "not_done", "not without the thing")
	var j := _req(a, {"type": "journal"})
	eq((j["requests"] as Array).size(), 1, "in the journal")
	check(String(j["requests"][0]["goal"]).contains(String(w.chronicles.of(id)["name"])), j["requests"][0]["goal"])
	w.grant(a, String(r["item"]), 1)  # as if found below
	t = _req(a, {"type": "report", "creature": asker.id})
	check(t.get("ok", false), str(t))
	eq(w.inventory(a).count(String(r["item"])), 0, "handed over")
	eq(w.inventory(a).count("base:coin"), int(r["reward"]), "rewarded")
	check(t.has("thanks") and not t.has("request"), "thanked; nothing more asked")
	check(_texts().contains("Аня вернула деревне"), "the deed is written down: " + _texts())
	eq((_req(a, {"type": "journal"})["requests"] as Array).size(), 0, "off the journal")


func test_wolves_near_the_village_bring_a_hunt() -> void:
	var centre: Vector2i = plan["centre"]
	var wolves: Array[Creature] = []
	for i in 2:
		wolves.append(w.creatures._spawn("base:wolf", Levels.SURFACE, centre + Vector2i(6 + i, 12), {}, 7 + i))
	w.chronicles.look_about(id)
	check(_texts().contains("рыщут волки"), "seen and written down: " + _texts())
	var hunt: Array = (w.chronicles.of(id)["requests"] as Array).filter(func(x: Dictionary) -> bool: return x["kind"] == "hunt")
	eq(hunt.size(), 1, "a hunt asked")
	check(int(hunt[0]["count"]) >= 2, "as many as were seen, at most three")
	var herder := _dweller(int(hunt[0]["asker"]))
	eq(String(herder.job["profession"]), "base:herder", "by who keeps the pen")
	eq((w.chronicles.of(id)["requests"] as Array).filter(func(x: Dictionary) -> bool:
		return x["state"] == "open" and int(x["asker"]) == int(hunt[0]["asker"])).size(), 1, "who asks one thing at a time")
	check(w.chronicles.gossip(herder, 0.1) in (_content.get_def("base:folk_names")["asks"] as Array), "it calls one over")
	check(w.chronicles.gossip(herder, 0.9).contains("рыщут волки"), "and passes the news on: " + w.chronicles.gossip(herder, 0.9))
	eq(w.chronicles.gossip(herder, 0.5), "", "not every time")
	w.chronicles.look_about(id)
	eq((w.chronicles.of(id)["requests"] as Array).filter(func(x: Dictionary) -> bool: return x["kind"] == "hunt").size(), 1,
		"not asked again while it is open")
	var a := _player("Аня", herder)
	_req(a, {"type": "promise", "creature": herder.id})
	var count := int(hunt[0]["count"])
	for i in count:
		var wolf: Creature = wolves[i] if i < wolves.size() else w.creatures._spawn("base:wolf", Levels.SURFACE, centre + Vector2i(4, 14), {}, 30 + i)
		w.combat.hurt(wolf.id, 999, a)
	var t := _req(a, {"type": "talk", "creature": herder.id})
	eq(t["request"]["state"], "ready", "every wolf counted")
	t = _req(a, {"type": "report", "creature": herder.id})
	check(t.get("ok", false), str(t))
	eq(w.inventory(a).count("base:coin"), int(hunt[0]["reward"]))
	check(_texts().contains("Аня отвадила от деревни: волки"), _texts())


func test_autumn_asks_for_wood_and_a_struck_dweller_bears_a_grudge() -> void:
	w.world_time = 2 * Seasons.SEASON_MS + Daylight.DAY_MS
	w.chronicles.look_about(id)
	check(_texts().contains("Пришла осень"), _texts())
	var farmer := _of_trade("base:farmer")
	var a := _player("Аня", farmer)
	var t := _req(a, {"type": "talk", "creature": farmer.id})
	check(String(t["request"]["says"]).contains("брёвен"), "the farmer asks for wood: " + str(t))
	_req(a, {"type": "promise", "creature": farmer.id})
	w.grant(a, "base:log", 10)
	t = _req(a, {"type": "talk", "creature": farmer.id})
	eq(t["request"]["state"], "ready", "ten logs carried")
	_req(a, {"type": "report", "creature": farmer.id})
	eq(w.inventory(a).count("base:log"), 0, "the wood given")
	w.chronicles.look_about(id)
	check(_texts().count("Пришла осень") == 1, "a season is written once")
	# Struck: written down, and no talk nor trade with the one who did it today.
	w.combat.hurt(farmer.id, 1, a)
	check(_texts().contains("Аня напала на жителя по имени " + String(farmer.job["name"])), _texts())
	eq(_req(a, {"type": "talk", "creature": farmer.id}).get("grudge"), true, "it will not talk")
	eq(_req(a, {"type": "trade_look", "creature": farmer.id}).get("reason"), "grudge", "nor trade")
	w.world_time += Daylight.DAY_MS + 1
	check(not _req(a, {"type": "talk", "creature": farmer.id}).has("grudge"), "a day later it has let it go")
	# Killed: written down, its requests gone.
	w.combat.hurt(farmer.id, 999, a)
	check(_texts().contains("Погиб"), "a death written down: " + _texts())
	check(_texts().contains("Убийца — Аня"), _texts())


## The map names the settlements near: the same names the chronicles use,
## asked without beginning a chronicle.
func test_places_near_are_named_for_the_map() -> void:
	var a := _player("Аня", null)
	var r := _req(a, {"type": "places"})
	check(r.get("ok", false), str(r))
	var names := (r["places"] as Array).map(func(p: Dictionary) -> String: return String(p["name"]))
	var home := w.chronicles.village_name(String(plan["id"]))
	check(names.has(home), "the village by the spawn: %s in %s" % [home, names])
	eq(w.chronicles.of(String(plan["id"]))["name"], home, "the chronicle calls it so too")
