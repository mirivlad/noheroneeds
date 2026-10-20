extends TestCase
## ADR-0032: satiety goes down with time and work, food brings it back,
## hungry one does not heal, starving one loses health but not the last.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 4})


func after_each() -> void:
	w.close()


func _player() -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	return c.character_id


func _req(actor: String, r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


## The world's clock on by `hours`, needs stepped as the server does each second.
func _hours(hours: float) -> void:
	var steps := int(hours * 60)
	for i in steps:
		w.world_time += Daylight.HOUR_MS / 60
		w.needs.step()


func test_satiety_goes_down_with_time_and_work() -> void:
	var a := _player()
	w.needs.step()
	eq(w.needs.satiety_of(a), Needs.FULL, "one comes full")
	_hours(18.0)
	check(absf(w.needs.satiety_of(a) - 50.0) < 1.0, "half in eighteen hours: %.1f" % w.needs.satiety_of(a))
	var before := w.needs.satiety_of(a)
	for i in 4:
		w.combat.swung(a, Vector2i.ZERO)
	check(absf(before - w.needs.satiety_of(a) - 1.0) < 0.01, "four blows: one")
	eq(w.needs.shown(a), {"satiety": int(ceilf(w.needs.satiety_of(a)))}, "the player is told a whole number")


func test_food_fills_and_full_ones_do_not_eat() -> void:
	var a := _player()
	w.grant(a, "base:bread", 3)
	eq(_req(a, {"type": "eat", "item": "base:bread"}).get("reason"), "not_hungry", "full and whole: no")
	w.needs.set_satiety(a, 30.0)
	var r := _req(a, {"type": "eat", "item": "base:bread"})
	eq(r.get("satiety"), 70, "bread: forty")
	w.needs.set_satiety(a, 90.0)
	check(_req(a, {"type": "eat", "item": "base:bread"}).get("ok", false), "not full: one may eat")
	eq(w.needs.satiety_of(a), Needs.FULL, "never above full")


func test_the_hungry_do_not_heal_and_hunger_does_not_kill() -> void:
	var a := _player()
	w.combat.hurt(a, 10, "")
	w.needs.set_satiety(a, 10.0)
	for t in range(1, 600):
		w.combat.step(t)
	eq(w.combat.health_of(a), 10, "hungry: no health back")
	w.needs.set_satiety(a, 60.0)
	for t in range(600, 900):
		w.combat.step(t)
	check(w.combat.health_of(a) > 10, "fed: it comes back")
	w.needs.set_satiety(a, 0.0)
	w.combat.hurt(a, w.combat.health_of(a) - 3, "")
	eq(w.combat.health_of(a), 3)
	_hours(1.5)
	eq(w.combat.health_of(a), 2, "starving: one an hour")
	_hours(10.0)
	eq(w.combat.health_of(a), 1, "but never the last")
	eq(int(w.present[a].get("deaths", 0)), 0, "not dead of hunger")


func test_satiety_is_kept_and_death_does_not_starve() -> void:
	var a := _player()
	w.needs.set_satiety(a, 33.0)
	w.leave(a)
	w.sync()
	w.close()
	w = ServerWorld.open(_db, _content)
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.character_id = a
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + a, c)
	eq(w.needs.satiety_of(a), 33.0, "kept across leaving and a restart")
	w.needs.set_satiety(a, 5.0)
	w.combat.hurt(a, 100, "")
	eq(w.needs.satiety_of(a), Needs.AFTER_DEATH, "after death: half full")
