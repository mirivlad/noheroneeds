extends TestCase

var w: ServerWorld
var trader: Creature
var actor: String
var db: String


func before_each() -> void:
	db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(db, ContentRegistry.load_packs(["res://content/base"]), {"seed": 11})
	var chunk := w.chunk("surface", 5, 5)
	for id: String in w.creatures.in_chunk("surface", 5, 5):
		w.creatures.remove(id)
	for y in 32:
		for x in 32:
			chunk.set_cell("ground", x, y, "base:grass")
			for layer: String in ["cover", "structure", "roof"]:
				chunk.set_cell(layer, x, y, "")
	var pc := PortableCharacter.create("Охранник", "base:human_ro_m")
	pc.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("key", pc)
	actor = pc.character_id
	trader = w.creatures._spawn("base:villager", "surface", Vector2i(170, 170), {}, 3)
	var home := String(w.generator.settlements.home_plan()["id"])
	trader.job = {"profession": "base:trader", "purse": 100, "name": "Гордей", "from": home, "toward": home}
	w.move_character(actor, trader.pos + Vector2i(256, 0))


func after_each() -> void:
	w.close()


func _request(r: Dictionary) -> Dictionary:
	if not r.has("request_id"):
		r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _time(hours: float) -> void:
	w.tick += Movement.TICK_RATE
	w.world_time += int(hours * Daylight.HOUR_MS)
	w.caravans.step()


func test_contract_pays_by_game_days_and_finishes_proportionally() -> void:
	var hired := _request({"type": "escort_hire", "creature": trader.id})
	check(hired.get("ok", false), str(hired))
	eq(int(trader.job["purse"]), 88, "one day reserved from real funds")
	_time(24)
	eq(w.inventory(actor).count("base:coin"), 12, "one day's escort")
	eq(int(trader.job["purse"]), 76, "next day reserved")
	_time(12)
	var ended := _request({"type": "escort_leave"})
	check(ended.get("ok", false), "leaving returns the updated journal")
	eq(w.inventory(actor).count("base:coin"), 18, "half-day settled")
	eq(int(trader.job["purse"]), 82, "unused half returned")
	eq(w.caravans.contract(actor)["state"], "left")
	eq(w.inventory(actor).count("base:coin") + int(trader.job["purse"]), 100, "coins conserved")


func test_offline_and_far_away_time_is_not_paid_and_requests_are_idempotent() -> void:
	var request := {"type": "escort_hire", "creature": trader.id, "request_id": "one-hire"}
	_request(request)
	_request(request)
	eq(int(trader.job["purse"]), 88, "duplicate hire cannot reserve twice")
	var saved: Dictionary = w.present[actor]
	w.present.erase(actor)
	w.caravans.step()
	w.world_time += Daylight.DAY_MS * 5
	w.present[actor] = saved
	w.caravans.step()
	eq(int(w.caravans.contract(actor)["elapsed"]), 0, "no five-day catch-up payment")
	w.move_character(actor, trader.pos + Vector2i(30 * 256, 0))
	_time(24)
	w.move_character(actor, trader.pos + Vector2i(256, 0))
	w.caravans.step()
	eq(w.inventory(actor).count("base:coin"), 0, "no payment for absence")
	_time(12)
	eq(int(w.caravans.contract(actor)["elapsed"]), 12 * Daylight.HOUR_MS)


func test_employer_death_settles_earned_pay_and_drops_only_remaining_purse() -> void:
	_request({"type": "escort_hire", "creature": trader.id})
	_time(12)
	w.combat.hurt(trader.id, 1000, "")
	eq(w.caravans.contract(actor)["state"], "dead")
	eq(w.inventory(actor).count("base:coin"), 6)
	var dropped := 0
	for item: Dictionary in w.items.values():
		if item["item"] == "base:coin":
			dropped += int(item["count"])
	eq(dropped, 94, "unused reserve returns before the trader drops his purse")
	w.caravans.finish(actor, "dead")
	eq(w.inventory(actor).count("base:coin"), 6, "death settled once")
	w.sync()
	w.close()
	w = ServerWorld.open(db, w.content, {"seed": 11})
	eq(w.caravans.contract(actor)["state"], "dead")
	eq(w.inventory(actor).count("base:coin"), 6, "payment survives restart")


func test_attacking_own_caravan_ends_contract_and_alerts_escort() -> void:
	w.creatures._make_caravan_guard(trader)
	_request({"type": "escort_hire", "creature": trader.id})
	var guard := w.creatures.get_creature(trader.job["guard"])
	w.combat.hurt(guard.id, 1, actor)
	eq(w.caravans.contract(actor)["state"], "betrayed")
	check(guard.memory.has(actor), "guards defend their own member")
	eq(int(trader.job["purse"]), 100, "unearned reserve returned")


func test_leaving_while_employer_is_unloaded_keeps_his_refund() -> void:
	_request({"type": "escort_hire", "creature": trader.id})
	_time(12)
	w.creatures.creatures.erase(trader.id)
	w.caravans.finish(actor, "left")
	eq(w.inventory(actor).count("base:coin"), 6)
	eq(int(w.fact("escort_refund|" + trader.id)), 6, "unused reserve remains the employer's")
	w.creatures.creatures[trader.id] = trader
	w.caravans.apply_refund(trader)
	w.caravans.apply_refund(trader)
	eq(int(trader.job["purse"]), 94, "refund applied exactly once when he loads")


func test_old_unloaded_employer_cannot_end_a_new_contract() -> void:
	_request({"type": "escort_hire", "creature": trader.id})
	w.creatures.creatures.erase(trader.id)
	w.caravans.finish(actor, "left")
	var other := w.creatures._spawn("base:villager", "surface", Vector2i(170, 170), {}, 99)
	other.job = {"profession": "base:trader", "purse": 100, "from": trader.job["from"], "toward": trader.job["toward"]}
	check(w.caravans.hire_player(actor, other).get("ok", false), "a new employer")
	w.creatures.creatures[trader.id] = trader
	w.caravans.finish_for(trader, "arrived")
	eq(w.caravans.contract(actor)["state"], "active", "the old employer cannot settle another contract")
	w.caravans.apply_refund(trader)
	check(not (trader.job.get("player_guards", []) as Array).has(actor), "stale membership is removed on load")


func test_night_camp_uses_fuel_and_only_removes_its_own_fire() -> void:
	trader.face = Vector2i.LEFT
	w.creatures._make_caravan(trader, "cart")
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS
	w.caravans.rest(trader)
	var spot: Array = trader.job["camp_spot"]
	trader.pos = Vector2i(int(spot[0]), int(spot[1])) * 256 + Vector2i(128, 128)
	w.creatures._move_caravan_horse(trader)
	w.caravans.rest(trader)
	check(trader.asleep, "the driver rests at night")
	check(trader.job.has("campfire"), "a dry night with fuel has a fire")
	if not trader.job.has("campfire"):
		return
	eq(w.inventory("supplies|" + trader.id).count("base:log"), 2, "two real logs used")
	var fire: Array = trader.job["campfire"]
	var at := Vector2i(int(fire[0]), int(fire[1]))
	var horse := w.creatures.get_creature(String(trader.job["horse"]))
	check(horse.cell().distance_to(at) >= 2.2, "the fire must not be beneath the horse")
	eq(w.part_at("surface", at.x, at.y), "base:campfire")
	var chunk := w.chunk("surface", at.x >> 5, at.y >> 5)
	world_replace_fire(chunk, at)
	w.caravans.break_camp(trader)
	eq(w.part_at("surface", at.x, at.y), "base:chest", "a player's replacement was not removed")
	check(not trader.asleep and not trader.job.has("camp_spot"), "camp packed in the morning")


func world_replace_fire(chunk: Chunk, at: Vector2i) -> void:
	chunk.set_cell("structure", posmod(at.x, 32), posmod(at.y, 32), "base:chest")
	chunk.set_props(posmod(at.x, 32), posmod(at.y, 32), {"owner": actor, "store": "players"})
