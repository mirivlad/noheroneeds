class_name Combat
extends RefCounted
## Fighting on the server (ADR-0019): health, blows and arrows, death.
##   health  — characters (their body plan's "health") and creatures (their
##             definition's); kept with them; comes back slowly once nobody
##             has hurt them for a while;
##   blows   — a weapon's data ("weapon": melee) or the body plan's
##             "unarmed", a creature's "attack": what is within reach, in the
##             arc toward where one aims, seen (Sight), the nearest is hit;
##   arrows  — a ranged weapon shoots its ammo as a projectile flying over the
##             plan: walls and what stands high enough stop it, the first one
##             it meets is hit; a missed arrow lies where it fell;
##   death   — a creature leaves its "drops"; a character, by the world's
##             rule, leaves what it carried where it fell (or keeps it) and
##             comes back at the spawn point.
## Characters are hit only where the server allows it (pvp, ADR-0016).

## Health comes back by one every REGEN_EVERY ticks, REGEN_AFTER ticks after
## the last hurt.
const REGEN_EVERY := 20
const REGEN_AFTER := 200
## How much nearer than a body's radius (BodySize) an arrow passes to hit
## it (units), and how far it moves per check.
const ARROW_MARGIN := 30
## The widest body (cells of radius) looked for round a point.
const MAX_BODY_CELLS := 4
const PROJECTILE_STEP := 96

var world: ServerWorld
## id -> Projectile
var projectiles := {}
## World rules (ADR-0016, ADR-0019): "off" or "free" (mutual: later);
## whether a character drops what it carried when it dies.
var pvp := "off"
var death_drops := true
## What a dead character dropped is kept for them alone this long (s), then
## anyone's (ADR-0016).
var dead_keep_s := 600
## Blows struck, for others to see the swing: id -> count * 8 + the
## direction's octant (0 east, 2 south...). Not saved.
var swings := {}
## Creatures whose health changed since the last take_health_changes().
var _health_changed := {}
var _hurt_at := {}
var _ready_at := {}
var _tick := 0


class Projectile:
	var id := ""
	var location := ""
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var left := 0.0
	var owner := ""
	var damage := 0
	var ammo := ""
	var start := Vector2i.ZERO
	var aim := Vector2i.ZERO
	## Where it was shot from and at (Sight's openings ask).
	var from_location := ""
	var aim_location := ""
	## Its height (levels, absolute) and how it changes per unit flown: flat
	## on one level; from the eyes down to the street or up to a walkway.
	var h := 0.0
	var dh := 0.0

func _init(w: ServerWorld) -> void:
	world = w


# --- health ----------------------------------------------------------------------

func max_health_of(id: String) -> int:
	if world.present.has(id):
		return int(world.content.get_def(_body_plan(world.present[id])).get("health", 20))
	var c := world.creatures.get_creature(id)
	return int(world.content.get_def(c.kind).get("health", 5)) if c else 0


func _body_plan(p: Dictionary) -> String:
	return String((p["appearance"] as Dictionary).get("body_plan", "base:human_m"))


## How big one is (BodySize): a character by its body plan, a creature by its kind.
func size_of(id: String) -> Dictionary:
	if world.present.has(id):
		return BodySize.of(world.content.get_def(_body_plan(world.present[id])))
	var c := world.creatures.get_creature(id)
	return BodySize.of(world.content.get_def(c.kind)) if c else BodySize.HUMAN


func health_of(id: String) -> int:
	if world.present.has(id):
		return int(world.present[id].get("health", max_health_of(id)))
	var c := world.creatures.get_creature(id)
	return c.health if c else 0


func _set_health(id: String, value: int) -> void:
	if world.present.has(id):
		world.present[id]["health"] = value
		world.note_character(id)
	else:
		var c := world.creatures.get_creature(id)
		if c:
			c.health = value
			c.changed()
			_health_changed[id] = true


## What one wears against blows (ADR-0029): the "armor" of every worn
## thing of a character, a creature's own (a hide, a shell).
func armor_of(id: String) -> int:
	if world.present.has(id):
		var total := 0
		var worn := world.worn_of(id)
		for slot: String in worn:  # broken keeps nothing off (ADR-0046), enhanced more (ADR-0047)
			total += Wear.armor(world.content, String(worn[slot][0]), worn[slot][1])
		return total
	var c := world.creatures.get_creature(id)
	return int(world.content.get_def(c.kind).get("armor", 0)) if c else 0


## The health a blow of `damage` takes from `target`: less its armour, but a
## blow always tells (at least 1). Falls and hunger are not blows.
func through_armor(target: String, damage: int) -> int:
	if damage <= 0:
		return 0
	var armor := armor_of(target)
	if armor > 0 and world.present.has(target):
		world.wear_armor(target)  # the blow wears what took it (ADR-0046)
	return maxi(1, damage - armor)


## Gives back up to `amount` of health, never above the most one has.
func heal(id: String, amount: int) -> void:
	_set_health(id, mini(max_health_of(id), health_of(id) + amount))


## Takes `amount` of health from `target` (a character or a creature) for
## `attacker`; it remembers who did it; at nothing it dies.
func hurt(target: String, amount: int, attacker: String) -> void:
	world.wake(target)  # a blow wakes one (ADR-0035)
	var left := health_of(target) - amount
	_hurt_at[target] = _tick
	var c := world.creatures.get_creature(target)
	if c:
		var who := attacker
		var at := _position(attacker)
		if at != NO_POS:
			c.memory[who] = {"pos": Movement.cell_of(at), "time": world.world_time, "what": "attacker"}
			world.creatures.kin_struck(c, who, Movement.cell_of(at))
			world.creatures.caravan_attacked(c, who, at)
		world.creatures.alarm(c)
	if left > 0:
		_set_health(target, left)
		if c and not c.job.is_empty():
			world.chronicles.struck(c, attacker)  # the village remembers (ADR-0042)
	elif world.present.has(target):
		_character_dies(target)
	elif c:
		world.chronicles.died(c, attacker)
		_creature_dies(c, attacker)


## {creature id: true} whose health changed (for the replicas), since last time.
func take_health_changes() -> Dictionary:
	var out := _health_changed
	_health_changed = {}
	return out


func step(tick: int) -> void:
	_tick = tick
	_fly()
	if tick % REGEN_EVERY != 0:
		return
	for id: String in _hurt_at.keys():
		if tick - int(_hurt_at[id]) < REGEN_AFTER:
			continue
		if not world.present.has(id) and not world.creatures.has(id):
			_hurt_at.erase(id)
			continue
		if world.present.has(id) and not world.needs.may_heal(id):
			continue  # hungry: health does not come back (ADR-0032)
		var animal := world.creatures.get_creature(id)
		if animal and world.creatures.life.hungry(animal):
			continue
		var h := health_of(id) + (2 if world.sitting(id) else 1)  # sitting heals twice as fast (RO)
		_set_health(id, mini(h, max_health_of(id)))
		if h >= max_health_of(id):
			_hurt_at.erase(id)


func _character_dies(id: String) -> void:
	var p: Dictionary = world.present[id]
	if death_drops:
		var inv := world.inventory(id)
		var until := world.tick + dead_keep_s * Movement.TICK_RATE
		for item: String in inv.stacks.keys():
			world.place_item(String(p["location"]), p["pos"], item, int(inv.stacks[item]), id, until,
				inv.take(item, int(inv.stacks[item])))
		world.touch_inventory(id)
		world.drop_equipment(id, until)
	p["location"] = world.spawn_location
	p["pos"] = world.spawn_position
	p["health"] = max_health_of(id)
	p["deaths"] = int(p.get("deaths", 0)) + 1
	world.needs.set_satiety(id, maxf(world.needs.satiety_of(id), Needs.AFTER_DEATH))
	_hurt_at.erase(id)
	world.relocated[id] = true
	world.note_character(id)


## Creatures that died this tick ({location, x, y, kind}): heard by those near (GameServer).
var died: Array[Dictionary] = []


func _creature_dies(c: Creature, killer := "") -> void:
	world.bandits.died(c)
	died.append({"location": c.location, "x": c.pos.x, "y": c.pos.y, "kind": c.kind})
	var drops: Dictionary = world.content.get_def(c.kind).get("drops", {})
	var hunter := world.creatures.get_creature(killer)
	var eaten := hunter != null and (world.content.get_def(hunter.kind).get("life", {}).get("prey", []) as Array).has(c.kind)
	if eaten:
		world.creatures.life.ate(hunter)
	# A hunter's kill (ADR-0047): practice, and a skilled one gets more of it.
	var more := world.knowledge.effect(killer, "kill", "yield") if world.present.has(killer) else 0.0
	if world.present.has(killer) and not drops.is_empty():
		world.knowledge.practise(killer, "kill", 3)
	for item: String in drops:
		if eaten and item == "base:raw_meat":
			continue  # the hunter ate the meat; the hide is left
		world.place_item(c.location, c.pos, item, world.knowledge.with_extra(killer, [c.id, item], int(drops[item]), more))
	# A looter gives back what it had not digested yet.
	world.creatures.digest(c)
	for e: Dictionary in c.stomach:
		world.place_item(c.location, c.pos, String(e["item"]), int(e["count"]), "", 0, e.get("states", []))
	c.stomach.clear()
	if c.job.get("profession", "") == "base:trader":
		# A caravan's stock is real inventory, not a second copy in the cart.
		# Drop each stack with its states before deleting the trader.
		var stock := world.inventory("trade|" + c.id)
		for item: String in stock.stacks.keys():
			var n := stock.count(item)
			world.place_item(c.location, c.pos, item, n, "", 0, stock.take(item, n))
		world.touch_inventory("trade|" + c.id)
		var purse := int(c.job.get("purse", 0))
		if purse > 0:
			world.place_item(c.location, c.pos, "base:coin", purse)
	swings.erase(c.id)
	_hurt_at.erase(c.id)
	world.creatures.remove(c.id)


# --- blows -------------------------------------------------------------------------

const NO_POS := Vector2i(1 << 30, 1 << 30)


## A player's attack request: {"x", "y": where it aims (movement units),
## "item": what it believes it holds (checked), "unarmed": true for a blow of
## the free hand}. With the held weapon; a ranged one shoots its ammo.
func attack(actor: String, r: Dictionary) -> Dictionary:
	if not world.present.has(actor):
		return {"ok": false, "reason": "not_here"}
	var p: Dictionary = world.present[actor]
	# What is in the hands is the server's (ADR-0021): the request may name it
	# to be sure both sides agree, never choose it.
	var why := world.check_held(actor, r)
	if why != "":
		return {"ok": false, "reason": why}
	var item := world.held_of(actor)
	var w: Dictionary
	if item == "" or ServerWorld.rb(r, "unarmed", false):
		w = world.content.get_def(_body_plan(p)).get("unarmed", {})  # a fist, or the free hand
	else:
		w = world.content.get_def(item).get("weapon", {})
		if not w.is_empty():
			# A broken weapon does nothing until mended; a dull one is slower
			# and weaker (ADR-0046).
			if world.held_broken(actor):
				return {"ok": false, "reason": "broken"}
			# Skill (ADR-0047): a practised hand strikes harder and oftener.
			var practice := "weapon:" + String(w["kind"])
			w = w.duplicate()
			w["damage"] = world.held_damage(actor, int(w["damage"])) + roundi(world.knowledge.effect(actor, practice, "damage"))
			w["cooldown_ms"] = float(w["cooldown_ms"]) * world.held_pace(actor) * world.knowledge.effect(actor, practice, "pace")
	if w.is_empty():
		return {"ok": false, "reason": "not_a_weapon"}
	if _tick < int(_ready_at.get(actor, 0)):
		return {"ok": false, "reason": "not_ready"}
	_ready_at[actor] = _tick + _ticks(float(w["cooldown_ms"]))
	var aim := Vector2i(ServerWorld.ri(r, "x", 0), ServerWorld.ri(r, "y", 0))
	swung(actor, aim)
	var armed := item != "" and not ServerWorld.rb(r, "unarmed", false)
	if w["kind"] == "ranged":
		var shot := _shoot(actor, p, w, aim, ServerWorld.ri(r, "z", -1))
		if not shot.get("ok", false):
			return shot
		world.knowledge.practise(actor, "weapon:ranged")
		return shot.merged(world.wear_held(actor, 1, "weapon:ranged"))  # a shot wears the bow
	var hit := _blow(actor, String(p["location"]), p["pos"], aim, w)
	world.creatures.noise(String(p["location"]), Movement.cell_of(p["pos"]))
	# A blow that lands wears the weapon (one into the air does not) and is practice.
	if armed and hit != "":
		world.knowledge.practise(actor, "weapon:melee")
		return {"ok": true, "hit": hit}.merged(world.wear_held(actor, 1, "weapon:melee"))
	return {"ok": true, "hit": hit}


## A creature strikes `target` if it is within its reach and seen: true if hit.
func creature_attack(c: Creature, target: String) -> bool:
	var w: Dictionary = world.content.get_def(c.kind).get("attack", {})
	if w.is_empty() or _tick < int(_ready_at.get(c.id, 0)):
		return false
	var at := _position(target)
	if at == NO_POS or _location(target) != c.location:
		return false
	var reach := float(w["reach"]) * Movement.UNIT + float(size_of(c.id)["radius"]) \
		- float(BodySize.HUMAN["radius"]) + float(size_of(target)["radius"])
	if Vector2(c.pos).distance_to(Vector2(at)) > reach \
			or not Sight.clear(world, c.location, c.cell(), c.location, Movement.cell_of(at),
				float(size_of(c.id)["eye"]), float(size_of(target)["body"])):
		return false
	_ready_at[c.id] = _tick + _ticks(float(w["cooldown_ms"]))
	swung(c.id, at)
	return _blow(c.id, c.location, c.pos, at, w) == target


## Someone struck (or shot, or worked with a tool) toward `toward` (movement
## units): counted, with the direction, so those who see it see the swing.
func swung(id: String, toward: Vector2i) -> void:
	world.needs.worked(id)
	var from := _position(id)
	var octant := 0
	if from != NO_POS and toward != from:
		octant = int(round(fposmod(Vector2(toward - from).angle(), TAU) / (PI / 4))) % 8
	var n := ((int(swings.get(id, 0)) >> 3) + 1) % (1 << 20)
	swings[id] = (n << 3) | octant
	if world.present.has(id):
		world.present[id]["swing"] = swings[id]
	else:
		_health_changed[id] = true  # a creature's warm part goes out again


## The nearest one within reach and arc toward `aim`, seen from `from`: hurt.
func _blow(attacker: String, location: String, from: Vector2i, aim: Vector2i, w: Dictionary) -> String:
	var dir := Vector2(aim - from)
	if dir == Vector2.ZERO:
		return ""
	dir = dir.normalized()
	# Reach is from the striker's body to the other's: big bodies are hit
	# farther from their middle, and a big striker reaches farther.
	var reach := float(w["reach"]) * Movement.UNIT + float(size_of(attacker)["radius"]) - float(BodySize.HUMAN["radius"])
	var cos_arc := cos(deg_to_rad(float(w["arc"]) / 2.0))
	var best := ""
	var best_d := INF
	for id: String in _targets_near(attacker, location, from, reach):
		var v := Vector2(_position(id) - from)
		var d := v.length()
		var body := float(size_of(id)["radius"])
		if d > reach + body or d >= best_d:
			continue
		if d > body and v.dot(dir) / d < cos_arc:
			continue
		if not Sight.clear(world, location, Movement.cell_of(from), location, Movement.cell_of(_position(id)),
				float(size_of(attacker)["eye"]), float(size_of(id)["body"])):
			continue
		best = id
		best_d = d
	if best != "":
		hurt(best, through_armor(best, int(w["damage"])), attacker)
	return best


## Who may be hit near `at`: creatures, and characters where the rules
## allow, whose bodies (BodySize radius) come within `radius` of it.
func _targets_near(attacker: String, location: String, at: Vector2i, radius: float) -> Array:
	var out := []
	var attacker_is_creature := world.creatures.has(attacker)
	for id: String in world.present:
		if id == attacker or world.present[id]["location"] != location:
			continue
		if not attacker_is_creature and pvp != "free":
			continue  # PvE (ADR-0016): characters are not hit by characters
		if Vector2(world.present[id]["pos"] - at).length() <= radius + float(size_of(id)["radius"]):
			out.append(id)
	var cell := Movement.cell_of(at)
	var r := ceili(radius / Movement.UNIT) + 1 + MAX_BODY_CELLS
	for cy in range((cell.y - r) >> 5, ((cell.y + r) >> 5) + 1):
		for cx in range((cell.x - r) >> 5, ((cell.x + r) >> 5) + 1):
			for id: String in world.creatures.in_chunk(location, cx, cy):
				if id != attacker and Vector2(world.creatures.get_creature(id).pos - at).length() <= radius + float(size_of(id)["radius"]):
					out.append(id)
	return out


func _position(id: String) -> Vector2i:
	if world.present.has(id):
		return world.present[id]["pos"]
	var c := world.creatures.get_creature(id)
	return c.pos if c else NO_POS


func _location(id: String) -> String:
	if world.present.has(id):
		return String(world.present[id]["location"])
	var c := world.creatures.get_creature(id)
	return c.location if c else ""


## Whether one may strike again (its last blow's cooldown is over); if so,
## the next one waits `cooldown_ms`.
func ready(actor: String, cooldown_ms: float) -> bool:
	if _tick < int(_ready_at.get(actor, 0)):
		return false
	_ready_at[actor] = _tick + _ticks(cooldown_ms)
	return true


func _ticks(ms: float) -> int:
	return maxi(1, ceili(ms / (1000.0 / Movement.TICK_RATE)))


# --- arrows ------------------------------------------------------------------------

func _shoot(actor: String, p: Dictionary, w: Dictionary, aim: Vector2i, aim_z: int) -> Dictionary:
	var ammo := String(w["ammo"])
	if world.inventory(actor).count(ammo) <= 0:
		return {"ok": false, "reason": "no_ammo"}
	var from: Vector2i = p["pos"]
	var dir := Vector2(aim - from)
	if dir == Vector2.ZERO:
		return {"ok": false, "reason": "bad_request"}
	world.inventory(actor).remove(ammo, 1)
	world.touch_inventory(actor)
	var pr := Projectile.new()
	pr.id = Uuid.v4()
	pr.location = String(p["location"])
	pr.pos = Vector2(from)
	pr.vel = dir.normalized() * float(w["speed"]) * Movement.UNIT / Movement.TICK_RATE
	pr.left = float(w["range"]) * Movement.UNIT
	pr.owner = actor
	pr.damage = int(w["damage"])
	pr.ammo = ammo
	pr.start = Movement.cell_of(from)
	pr.aim = Movement.cell_of(aim)
	pr.from_location = pr.location
	pr.aim_location = _aim_location(pr.location, pr.aim, aim_z)
	var z0 := world.levels.z(pr.location)
	if pr.aim_location == pr.location:
		pr.h = z0 + (Sight.EYE + Sight.BODY) / 2.0  # level, at body height
	else:
		pr.h = z0 + Sight.EYE
		pr.dh = (world.levels.z(pr.aim_location) + Sight.BODY - pr.h) / maxf(dir.length(), 1.0)
	projectiles[pr.id] = pr
	world.creatures.noise(pr.location, pr.start)
	return {"ok": true, "projectile": pr.id}


## Arrows fly a tick further in small steps, over the plan and in height:
## the first one they pass near at their height is hit; what stands in their
## way (Sight's spans) stops them, and they fall there; below the ground they
## land. Between levels they are in the location whose floor is under them.
func _fly() -> void:
	for id: String in projectiles.keys():
		var pr: Projectile = projectiles[id]
		var dist := pr.vel.length()
		var steps := maxi(1, ceili(dist / PROJECTILE_STEP))
		var on_plan := Sight.same_space(world, pr.location, Levels.SURFACE)
		# The ground it flies over: the surface's on the plan; below, the
		# floor of its depth (a depth's heights are under 0: an arrow there
		# is not "in the ground" from the start).
		var floor_h := 0.0 if on_plan else float(world.levels.z(pr.location))
		for i in steps:
			var next := pr.pos + pr.vel / steps
			var h := pr.h + pr.dh * dist / steps
			var cell := Movement.cell_of(Vector2i(next))
			if h < floor_h:
				_fall(pr, pr.pos)  # into the ground
				break
			if cell != pr.start and _stops(pr, cell, minf(pr.h, h), maxf(pr.h, h)):
				_fall(pr, pr.pos)
				break
			pr.pos = next
			pr.h = h
			if on_plan:
				pr.location = location_under(cell, h)
			pr.left -= dist / steps
			var target := _hit_near(pr)
			if target != "":
				hurt(target, through_armor(target, pr.damage), pr.owner)
				projectiles.erase(id)
				break
			if pr.left <= 0.0:
				_fall(pr, pr.pos)
				break


func _stops(pr: Projectile, cell: Vector2i, lo: float, hi: float) -> bool:
	if not Sight.same_space(world, pr.location, Levels.SURFACE):
		return world.is_solid(pr.location, cell.x, cell.y)
	return Sight._blocked(world, cell, lo, hi, pr.from_location, pr.start, pr.aim_location, pr.aim)


## Who is hit: in the location it flies over, below the top of a body there.
func _hit_near(pr: Projectile) -> String:
	var above := pr.h - world.levels.z(pr.location)
	for id: String in _targets_near(pr.owner, pr.location, Vector2i(pr.pos), ARROW_MARGIN):
		if above <= maxf(1.0, float(size_of(id)["height"])):
			return id  # one storey or the body's own height: not over its head
	return ""


## The location whose floor is under height h at a cell of the plan: the
## surface, or a level of the building standing there.
func location_under(cell: Vector2i, h: float) -> String:
	var lx := cell.x & 31
	var ly := cell.y & 31
	var c := world.chunk(Levels.SURFACE, cell.x >> 5, cell.y >> 5)
	var loc := Levels.SURFACE
	if c.get_cell("ceiling", lx, ly) == "":
		return loc
	var building := String((c.get_props(lx, ly).get("ceiling", {}) as Dictionary).get("building", ""))
	var z := 1
	while z <= h:
		var l := world.levels.level(building, z)
		if l == "":
			break
		var lc := world.chunk(l, cell.x >> 5, cell.y >> 5)
		if lc.get_cell("ground", lx, ly) == "":
			break
		loc = l
		if lc.get_cell("ceiling", lx, ly) == "":
			break
		z += 1
	return loc


## What one aims at: the level `z` asked for, if there is a floor of it at
## the cell; else one's own level, if it has floor there; else the floor below
## (from a walkway: the street).
func _aim_location(own: String, cell: Vector2i, z: int) -> String:
	if not Sight.same_space(world, own, Levels.SURFACE):
		return own
	var top := float(world.levels.z(own)) + 0.5
	if z >= 0:
		var asked := location_under(cell, z + 0.5)
		if world.levels.z(asked) == z:
			return asked
	return location_under(cell, top)


func _fall(pr: Projectile, at: Vector2) -> void:
	world.place_item(pr.location, Vector2i(at), pr.ammo, 1)
	projectiles.erase(pr.id)
