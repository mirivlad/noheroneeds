class_name CreatureSim
extends RefCounted
## Living creatures, simulated by the server alone (ADR-0018): no scene, no
## client needed. Their kinds are content ("creature"); behaviours are named
## in the data and written here.
##
## Cost is bounded, not every creature every tick:
##   * thinking (perceive, decide) happens every think_ticks of the kind, at
##     most THINKS_PER_TICK a tick; the rest wait on a schedule wheel;
##   * moving is a cheap integer step each tick, only for those walking;
##   * activity has levels: near players (their chunks are needed) a creature
##     lives fully; in a loaded chunk nobody is near it stands and does not
##     think; in an unloaded chunk it is saved and, when it comes back,
##     catches up the time away in one simple step (somewhere in its range,
##     a villager at home at night).
## Creatures are saved as entities by chunk (with their memory), on change
## and before their chunk unloads; they survive restarts.
##
## Populating: a surface chunk gets its animals once, from its biome's fauna,
## the first time it is loaded (old worlds too: a chunk without "fauna" in
## its meta gets them then); villagers come once, near the spawn point.

const THINKS_PER_TICK := 48
const FAUNA_VERSION := 1
const VILLAGERS := 3
## A creature away longer than this (real seconds) catches up on return.
const CATCH_UP_S := 20.0
## Active: its chunk was needed by a player within this many ticks.
const ACTIVE_TICKS := 2 * Movement.TICK_RATE + 1
## Saved again while it moves about, at most this often (ticks).
const SAVE_EVERY := 100
## A noise is heard for this long (real seconds).
const NOISE_S := 3.0

var world: ServerWorld
var creatures := {}
## Thinks done in the last tick (tests, stats).
var thinks_last_tick := 0
var _by_chunk := {}
## Changes for those who mirror the creatures (GameServer, each tick through
## take_changes): ids that came into memory, left it, or moved.
var _appeared := {}
var _left := {}
var _moved := {}
var _wheel := {}
var _movers := {}
var _last_saved := {}
## Ids still to look at in this round of saving.
var _save_order: Array = []
## [location, cell, world time]
var _noises: Array = []
var _tick := 0


func _init(w: ServerWorld) -> void:
	world = w


# --- what is where -----------------------------------------------------------

func in_chunk(location: String, cx: int, cy: int) -> Array:
	return (_by_chunk.get(ServerWorld.chunk_key(location, cx, cy), {}) as Dictionary).keys()


## [appeared, left, moved] ({id: true} each) since the last call.
func take_changes() -> Array:
	var out := [_appeared, _left, _moved]
	_appeared = {}
	_left = {}
	_moved = {}
	return out


func has(id: String) -> bool:
	return creatures.has(id)


func get_creature(id: String) -> Creature:
	return creatures.get(id)


## Its chunk's key (worked out again only when it moved to another chunk).
func _chunk_of(c: Creature) -> String:
	var at := Vector2i(c.pos.x >> (Movement.UNIT_SHIFT + 5), c.pos.y >> (Movement.UNIT_SHIFT + 5))  # Chunk.SIZE is 32
	if at != c.chunk_at or c.location != c.chunk_location:
		c.chunk_at = at
		c.chunk_location = c.location
		c.chunk_key = ServerWorld.chunk_key(c.location, at.x, at.y)
	return c.chunk_key


func _index(c: Creature, old_key := "") -> void:
	if old_key != "":
		(_by_chunk.get(old_key, {}) as Dictionary).erase(c.id)
	(_by_chunk.get_or_add(_chunk_of(c), {}) as Dictionary)[c.id] = true


func add(c: Creature) -> void:
	if c.health < 0:
		c.health = int(world.content.get_def(c.kind).get("health", 5))
	creatures[c.id] = c
	_appeared[c.id] = true
	_left.erase(c.id)
	_index(c)
	_schedule(c, _tick + 1 + absi(hash(c.id)) % 10)


# --- loading, saving, unloading ------------------------------------------------

## Creatures stored in a chunk that has just come into memory.
func take_rows(location: String, rows: Array) -> void:
	for row: Dictionary in rows:
		if row["kind"] != "creature" or creatures.has(row["id"]):
			continue
		add(Creature.from_data(String(row["id"]), location, Cbor.decode(row["data"]).value))


## A chunk came into memory: give a surface chunk its animals once.
func on_chunk_ready(location: String, cx: int, cy: int, c: Chunk) -> void:
	var wild := (location == Levels.SURFACE and world.generator != null) \
		or (Levels.is_depth(location) and world.underground != null)
	if not wild or int(c.meta.get("fauna", 0)) >= FAUNA_VERSION:
		return
	_populate(location, cx, cy)
	c.meta["fauna"] = FAUNA_VERSION
	world.mark_chunk_dirty(location, cx, cy)
	if cx == 0 and cy == 0 and world.store.read_meta("villagers") == "":
		_villagers()
		world.note_fact("villagers", "1")


## Who lives in a chunk made just now: the surface's biome's fauna, or the
## underground's (its generator's "fauna"), on cells one can stand on.
func _populate(location: String, cx: int, cy: int) -> void:
	var b: Dictionary
	if location == Levels.SURFACE:
		var centre := Vector2i(cx * Chunk.SIZE + Chunk.SIZE / 2, cy * Chunk.SIZE + Chunk.SIZE / 2)
		var biome := world.generator.biome_id_at(centre.x, centre.y)
		if biome == "":
			return
		b = world.content.get_def(biome)
	else:
		b = world.content.get_def(UndergroundGenerator.ID)
	var fauna: Dictionary = b.get("fauna", {})
	if fauna.is_empty():
		return
	var r := RandomNumberGenerator.new()
	r.seed = hash([world.world_seed, cx, cy, "fauna"] if location == Levels.SURFACE else [world.world_seed, location, cx, cy, "fauna"])
	var n := int(float(b["fauna_density"]) + r.randf())
	var kinds := fauna.keys()
	kinds.sort()
	var total := 0.0
	for k: String in kinds:
		total += float(fauna[k])
	for i in n:
		var pick := r.randf() * total
		var kind: String = kinds[-1]
		for k: String in kinds:
			pick -= float(fauna[k])
			if pick <= 0.0:
				kind = k
				break
		for attempt in 8:
			var cell := Vector2i(cx * Chunk.SIZE + r.randi_range(0, Chunk.SIZE - 1), cy * Chunk.SIZE + r.randi_range(0, Chunk.SIZE - 1))
			if _walkable(location, cell):
				_spawn(kind, location, cell, {}, hash([world.world_seed, location, cx, cy, i]))
				break


## A few villagers near the spawn point, each with its own looks and home.
func _villagers() -> void:
	var hairs := ["base:hair_short", "base:hair_long", "base:hair_braid"]
	for i in VILLAGERS:
		var r := RandomNumberGenerator.new()
		r.seed = hash([world.world_seed, "villager", i])
		for attempt in 12:
			var cell := Vector2i(r.randi_range(-12, 12), r.randi_range(-12, 12))
			if cell.length() < 5 or not _walkable(Levels.SURFACE, cell):
				continue
			var looks := {"body_plan": "base:humanoid_adult",
				"styles": {"hair": hairs[r.randi() % hairs.size()], "face": "base:face_soft", "eyes": "base:eyes_round"},
				"worn": WorldLibrary.STARTER_OUTFIT.duplicate()}
			_spawn("base:villager", Levels.SURFACE, cell, looks, hash([world.world_seed, "villager", i]))
			break


## A crowd for load tests (server option --populate=N): n creatures within
## `radius` cells of the spawn point, about one in ten a villager.
func spawn_crowd(n: int, radius: int) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = hash([world.world_seed, "crowd"])
	var made := 0
	var attempts := 0
	while made < n and attempts < n * 10:
		attempts += 1
		var cell := Vector2i(r.randi_range(-radius, radius), r.randi_range(-radius, radius))
		if not _walkable(Levels.SURFACE, cell):
			continue
		var kind := "base:villager" if made % 10 == 9 else ("base:hare" if made % 2 == 0 else "base:deer")
		var looks := {"body_plan": "base:humanoid_adult", "styles": CharacterLibrary.STYLE_DEFAULTS.duplicate(),
			"worn": WorldLibrary.STARTER_OUTFIT.duplicate()} if kind == "base:villager" else {}
		_spawn(kind, Levels.SURFACE, cell, looks, r.randi())
		made += 1


func _spawn(kind: String, location: String, cell: Vector2i, looks: Dictionary, seed_value: int) -> Creature:
	var c := Creature.new()
	c.id = Uuid.v4()
	c.kind = kind
	c.location = location
	c.pos = cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
	c.home = cell
	c.looks = looks
	c.seed = seed_value
	c.last_time = world.world_time
	add(c)
	_save(c)
	return c


func _save(c: Creature) -> void:
	var cell := c.cell()
	world.set_entity(c.id, c.location, cell.x, cell.y, "creature", c.to_data())  # entities are kept by cell
	c.saved_version = c.version
	_last_saved[c.id] = [c.pos, _tick]


## Saves every creature whose state is not saved (shutdown, full syncs).
func save_all() -> void:
	for c: Creature in creatures.values():
		if c.saved_version != c.version or (_last_saved.get(c.id, [Vector2i(-1, -1)]) as Array)[0] != c.pos:
			_save(c)


## Whether a chunk's creatures are all saved (then it may unload); if not,
## saves them now, so a later try succeeds.
func ready_to_unload(key: String) -> bool:
	var ready := true
	for id: String in (_by_chunk.get(key, {}) as Dictionary):
		var c: Creature = creatures[id]
		if c.saved_version != c.version or (_last_saved.get(id, [Vector2i(-1, -1)]) as Array)[0] != c.pos:
			c.last_time = world.world_time
			_save(c)
			ready = false
	return ready


## A creature is gone for good (it died): out of memory and of the store.
func remove(id: String) -> void:
	var c: Creature = creatures.get(id)
	if c == null:
		return
	(_by_chunk.get(_chunk_of(c), {}) as Dictionary).erase(id)
	creatures.erase(id)
	_movers.erase(id)
	_last_saved.erase(id)
	_left[id] = true
	_appeared.erase(id)
	_moved.erase(id)
	world.remove_entity(id, c.location, c.cell())


## Something happened to it (it was hurt): it thinks at once.
func alarm(c: Creature) -> void:
	_schedule(c, _tick + 1)


## The chunk leaves memory: so do its creatures (they are saved).
func drop_chunk(key: String) -> void:
	for id: String in (_by_chunk.get(key, {}) as Dictionary):
		creatures.erase(id)
		_movers.erase(id)
		_last_saved.erase(id)
		_left[id] = true
		_appeared.erase(id)
		_moved.erase(id)
	_by_chunk.erase(key)


# --- noises --------------------------------------------------------------------

## Something made a noise at a cell (building, taking down): creatures within
## hearing will know where, not who.
func noise(location: String, cell: Vector2i) -> void:
	_noises.append([location, cell, world.world_time])


# --- the tick ------------------------------------------------------------------

func step(tick: int) -> void:
	_tick = tick
	var keep_noise := _ms(NOISE_S)
	while not _noises.is_empty() and world.world_time - int(_noises[0][2]) > keep_noise:
		_noises.pop_front()
	_think_due(tick)
	for id: String in _movers.keys():
		var c: Creature = creatures.get(id)
		if c == null:
			_movers.erase(id)
			continue
		_move(c)
	# Saving is spread over the ticks: each tick a share of the creatures (all
	# of them every SAVE_EVERY ticks), never all at once.
	if _save_order.is_empty():
		_save_order = creatures.keys()
	var share := ceili(float(creatures.size()) / SAVE_EVERY)
	for i in mini(share, _save_order.size()):
		var c: Creature = creatures.get(_save_order.pop_back())
		if c == null:
			continue
		var last: Array = _last_saved.get(c.id, [Vector2i(-1, -1), 0])
		if c.saved_version != c.version or last[0] != c.pos:
			_save(c)


func _schedule(c: Creature, at: int) -> void:
	c.next_think = at
	(_wheel.get_or_add(at, []) as Array).append(c.id)


func _think_due(tick: int) -> void:
	var due: Array = []
	for t: int in _wheel.keys():
		if t <= tick:
			due.append_array(_wheel[t])
			_wheel.erase(t)
	thinks_last_tick = 0
	for i in due.size():
		var c: Creature = creatures.get(due[i])
		if c == null or c.next_think > tick:
			continue  # gone, or rescheduled meanwhile
		if thinks_last_tick >= THINKS_PER_TICK:
			_schedule(c, tick + 1)  # over the budget: next tick
			continue
		thinks_last_tick += 1
		_think(c, tick)


func _active(c: Creature) -> bool:
	return world.needed_within(_chunk_of(c), ACTIVE_TICKS)


func _think(c: Creature, tick: int) -> void:
	var def := world.content.get_def(c.kind)
	if def.is_empty():
		_schedule(c, tick + 200)  # its pack is gone: it waits, unchanged
		return
	if not _active(c):
		# Nobody near: it stands; it will catch up when someone comes.
		_movers.erase(c.id)
		_schedule(c, tick + int(def["think_ticks"]) * 10)
		return
	var now := world.world_time
	if now - c.last_time > _ms(CATCH_UP_S):
		_catch_up(c, def)
	c.last_time = now
	_perceive(c, def)
	match String(def["behavior"]):
		"prey":
			_prey(c, def)
		"villager":
			_villager(c, def)
		"predator":
			_predator(c, def)
	if c.target != Creature.NO_TARGET:
		_movers[c.id] = true
	else:
		_movers.erase(c.id)
	var soon := c.state in ["flee", "alert", "hunt", "attack"]
	_schedule(c, tick + (maxi(2, int(def["think_ticks"]) / 2) if soon else int(def["think_ticks"])))


## Real seconds as world time (game ms at the world's pace).
func _ms(seconds: float) -> int:
	return int(seconds * Movement.TICK_RATE * world.time_rate)


## Back after a time away: somewhere in its range (a villager at home at
## night), its old memories forgotten.
func _catch_up(c: Creature, def: Dictionary) -> void:
	c.memory.clear()
	c.target = Creature.NO_TARGET
	c.running = false
	var night := Daylight.is_night(world.world_time)
	var cell := c.home
	if not (String(def["behavior"]) == "villager" and night):
		var spot := _spot_near(c, c.home, float(def["home_radius"]), int(world.world_time / 1000))
		if spot != Creature.NO_TARGET:
			cell = spot
	var old := _chunk_of(c)
	c.pos = cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
	c.state = "home" if String(def["behavior"]) == "villager" and night else "idle"
	_index(c, old)
	_moved[c.id] = true
	c.changed()


# --- perception and memory -----------------------------------------------------

## Fills memory with what it sees and hears now; forgets what is too old.
func _perceive(c: Creature, def: Dictionary) -> void:
	var me := c.cell()
	var now := world.world_time
	var sight := float(def["sight"])
	for pid: String in world.present:
		var p: Dictionary = world.present[pid]
		if p["location"] != c.location and not Sight.same_space(world, c.location, p["location"]):
			continue
		var at := Movement.cell_of(p["pos"])
		if absi(at.x - me.x) > sight or absi(at.y - me.y) > sight:
			continue
		if Perception.sees(world, c.location, me, def, at, p["location"]):
			var was: Dictionary = c.memory.get(pid, {})
			if was.get("what") == "attacker" and now - int(was["time"]) <= _ms(20.0):
				was["pos"] = at  # who hurt it: still that, seen where it is now
			else:
				c.memory[pid] = {"pos": at, "time": now, "what": "character"}
	for n: Array in _noises:
		if n[0] == c.location and Perception.hears(def, me, n[1]):
			c.memory["noise"] = {"pos": n[1], "time": int(n[2]), "what": "noise"}
	var keep := _ms(float(def["memory_s"]))
	for k: String in c.memory.keys():
		if now - int(c.memory[k]["time"]) > keep:
			c.memory.erase(k)


## The nearest remembered character (or a recent noise), within `within`
## cells: [cell, distance] or [] — from memory only.
func _nearest_threat(c: Creature, within: float, noise_s: float) -> Array:
	var me := c.cell()
	var best := []
	for k: String in c.memory:
		var m: Dictionary = c.memory[k]
		if m["what"] == "noise" and world.world_time - int(m["time"]) > _ms(noise_s):
			continue
		var d := Vector2(me).distance_to(Vector2(m["pos"]))
		if d <= within and (best.is_empty() or d < float(best[1])):
			best = [m["pos"], d]
	return best


## Whether it saw a character within `within` cells just now (this think).
func _someone_close(c: Creature, within: float) -> bool:
	for k: String in c.memory:
		var m: Dictionary = c.memory[k]
		if m["what"] == "character" and int(m["time"]) == world.world_time \
				and Vector2(c.cell()).distance_to(Vector2(m["pos"])) <= within:
			return true
	return false


# --- behaviours ------------------------------------------------------------------

## Game animals: graze and wander about their range; run from what they have
## seen or heard come close; watch a while once safe; rest at night.
func _prey(c: Creature, def: Dictionary) -> void:
	var flee := float(def["flee_distance"])
	var threat := _nearest_threat(c, flee, NOISE_S)
	if not threat.is_empty():
		var away := _away_from(c, threat[0], flee * 2.0)
		if away != Creature.NO_TARGET:
			_go(c, "flee", away, true)
		return
	if c.state == "flee":
		_go(c, "alert", Creature.NO_TARGET, false)
		return
	if c.state == "alert" and not _nearest_threat(c, flee * 1.8, NOISE_S).is_empty():
		return  # still watching what it ran from
	if Daylight.is_night(world.world_time) and world.has_daylight(c.location):
		if c.target == Creature.NO_TARGET:
			_go(c, "rest", Creature.NO_TARGET, false)
		return
	if c.target != Creature.NO_TARGET and c.state == "wander":
		return
	if c.rand(int(world.world_time / 1000) + c.next_think) < 0.35:
		var spot := _spot_near(c, c.home, float(def["home_radius"]), c.next_think)
		if spot != Creature.NO_TARGET:
			_go(c, "wander", spot, false)
			return
	_go(c, "graze", Creature.NO_TARGET, false)


## Villagers: go about near home by day, stop to look at someone who comes
## close, go home at night.
func _villager(c: Creature, def: Dictionary) -> void:
	var attacker := _attacker(c, 12.0)
	if not attacker.is_empty():
		var away := _away_from(c, attacker[0], 16.0)
		if away != Creature.NO_TARGET:
			_go(c, "flee", away, true)  # hurt: it runs from who did it
			return
	if Daylight.is_night(world.world_time):
		if c.cell() != c.home:
			_go(c, "go_home", c.home, false)
		else:
			_go(c, "home", Creature.NO_TARGET, false)
		return
	if _someone_close(c, 3.0):
		_go(c, "look", Creature.NO_TARGET, false)  # someone close: it stops to look
		return
	if c.target != Creature.NO_TARGET and c.state == "wander":
		return
	if c.rand(int(world.world_time / 1000) + c.next_think) < 0.5:
		var spot := _spot_near(c, c.home, float(def["home_radius"]), c.next_think)
		if spot != Creature.NO_TARGET:
			_go(c, "wander", spot, false)
			return
	_go(c, "idle", Creature.NO_TARGET, false)


## Predators (a wolf): by night, or by day when one comes into its territory
## or hurts it, it goes after the nearest character it has seen, running, and
## strikes when within reach; badly hurt, it runs; it loses one it cannot find
## where it last saw it. Otherwise it keeps near its den: resting by day,
## prowling by night.
func _predator(c: Creature, def: Dictionary) -> void:
	var night := Daylight.is_night(world.world_time) or not world.has_daylight(c.location)  # below: always night
	var max_hp := int(def["health"])
	var prey := _nearest_character(c, float(def["sight"]))
	var attacker := _attacker(c, float(def["sight"]))
	if c.health * 10 < max_hp * 3 and not prey.is_empty():
		var away := _away_from(c, prey[0], 16.0)
		if away != Creature.NO_TARGET:
			_go(c, "flee", away, true)
			return
	if not prey.is_empty() and (night or not attacker.is_empty() or float(prey[1]) <= float(def["territory"])):
		var who: String = prey[2]
		if world.combat.creature_attack(c, who):
			_go(c, "attack", Creature.NO_TARGET, false)
			return
		var m: Dictionary = c.memory[who]
		if float(prey[1]) < 1.0 and int(m["time"]) < world.world_time:
			c.memory.erase(who)  # it was here, and is not: lost
			_go(c, "alert", Creature.NO_TARGET, false)
			return
		_go(c, "hunt", prey[0], true)
		return
	if c.target != Creature.NO_TARGET and c.state in ["wander", "prowl"]:
		return
	if c.rand(int(world.world_time / 1000) + c.next_think) < (0.5 if night else 0.15):
		var spot := _spot_near(c, c.home, float(def["home_radius"]), c.next_think)
		if spot != Creature.NO_TARGET:
			_go(c, "prowl" if night else "wander", spot, false)
			return
	_go(c, "rest" if not night else "idle", Creature.NO_TARGET, false)


## The nearest character it remembers (seen or hurt by), within `within`
## cells: [cell, distance, id] or [].
func _nearest_character(c: Creature, within: float) -> Array:
	var me := c.cell()
	var best := []
	for k: String in c.memory:
		var m: Dictionary = c.memory[k]
		if m["what"] == "noise" or not world.present.has(k):
			continue
		var d := Vector2(me).distance_to(Vector2(m["pos"]))
		if d <= within and (best.is_empty() or d < float(best[1])):
			best = [m["pos"], d, k]
	return best


## Who hurt it lately (it remembers where): [cell, distance, id] or [].
func _attacker(c: Creature, within: float) -> Array:
	var me := c.cell()
	for k: String in c.memory:
		var m: Dictionary = c.memory[k]
		if m["what"] == "attacker" and world.world_time - int(m["time"]) <= _ms(20.0):
			var d := Vector2(me).distance_to(Vector2(m["pos"]))
			if d <= within:
				return [m["pos"], d, k]
	return []


func _go(c: Creature, state: String, target_cell: Vector2i, run: bool) -> void:
	var target := target_cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2) \
		if target_cell != Creature.NO_TARGET else Creature.NO_TARGET
	if c.state != state or c.target != target or c.running != run:
		c.state = state
		c.target = target
		c.running = run
		c.stuck = 0
		c.changed()


# --- moving --------------------------------------------------------------------

func _move(c: Creature) -> void:
	if c.target == Creature.NO_TARGET:
		_movers.erase(c.id)
		return
	var d := c.target - c.pos
	if absi(d.x) < 48 and absi(d.y) < 48:
		c.target = Creature.NO_TARGET
		c.running = false
		_movers.erase(c.id)
		c.changed()
		_schedule(c, _tick + 2)  # arrived: think again soon
		return
	var def := world.content.get_def(c.kind)
	var speed := int(float(def["run_speed"] if c.running else def["speed"]) * Movement.WALK)
	var dx := signi(d.x) if absi(d.x) > 24 else 0
	var dy := signi(d.y) if absi(d.y) > 24 else 0
	var old_key := _chunk_of(c)
	var np := Movement.step_at(c.pos, dx, dy, _solid_in(c.location), speed)
	if np == c.pos:
		c.stuck += 1
		if c.stuck > 4:  # something in the way: give up, think again
			c.target = Creature.NO_TARGET
			c.running = false
			_movers.erase(c.id)
			c.changed()
			_schedule(c, _tick + 1)
		return
	c.stuck = 0
	c.pos = np
	_moved[c.id] = true
	var key := _chunk_of(c)
	if key != old_key:
		_index(c, old_key)
		c.changed()  # it now belongs to another chunk's rows


## world.is_solid for one location, made once per location.
var _solid_fns := {}


func _solid_in(location: String) -> Callable:
	var f: Array = _solid_fns.get(location, [])
	if f.is_empty():
		var q := world.solid_in(location)
		f = [q, q.solid]  # the object itself is kept: a method Callable does not keep it
		_solid_fns[location] = f
	return f[1]


## The world closes: let go of it (they hold each other).
func detach() -> void:
	world = null
	_solid_fns.clear()


func _walkable(location: String, cell: Vector2i) -> bool:
	return not world.is_solid(location, cell.x, cell.y)


## A walkable cell within `radius` of `around`, or NO_TARGET.
func _spot_near(c: Creature, around: Vector2i, radius: float, salt: int) -> Vector2i:
	for attempt in 6:
		var a := c.rand(salt * 7 + attempt) * TAU
		var r := sqrt(c.rand(salt * 13 + attempt + 1)) * radius
		var cell := around + Vector2i(int(round(cos(a) * r)), int(round(sin(a) * r)))
		if _walkable(c.location, cell):
			return cell
	return Creature.NO_TARGET


## A walkable cell about `far` cells away from `threat`, turning a little if
## straight away is blocked.
func _away_from(c: Creature, threat: Vector2i, far: float) -> Vector2i:
	var me := c.cell()
	var dir := Vector2(me - threat)
	if dir.length() < 0.01:
		dir = Vector2.RIGHT.rotated(c.rand(c.next_think) * TAU)
	dir = dir.normalized()
	for turn: float in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5]:
		var v := dir.rotated(turn) * far
		var cell := me + Vector2i(int(round(v.x)), int(round(v.y)))
		if _walkable(c.location, cell):
			return cell
	return Creature.NO_TARGET
