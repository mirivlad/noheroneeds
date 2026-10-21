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
## Raised when kinds come to the fauna; a creature's "fauna_since" says from
## which: chunks populated before get those kinds only (old worlds meet the
## looters too, without a second crowd of hares).
const FAUNA_VERSION := 5  # 4: settlements' dwellers and their animals (ADR-0039); 5: bears, foxes, mushroom walkers
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
## Ids whose owner changed (tamed, born to one), for the replicas.
var _owned := {}
## [location, cell, world time]
var _noises: Array = []
var _tick := 0


func _init(w: ServerWorld) -> void:
	world = w


# --- what is where -----------------------------------------------------------

func in_chunk(location: String, cx: int, cy: int) -> Array:
	return (_by_chunk.get(ServerWorld.chunk_key(location, cx, cy), {}) as Dictionary).keys()


## {id: true} of creatures whose owner changed since the last call.
func take_owner_changes() -> Dictionary:
	var out := _owned
	_owned = {}
	return out


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
	var had := int(c.meta.get("fauna", 0))
	if not wild or had >= FAUNA_VERSION:
		return
	_populate(location, cx, cy, had)
	if location == Levels.SURFACE and had < 4:
		_settle(cx, cy)
	c.meta["fauna"] = FAUNA_VERSION
	world.mark_chunk_dirty(location, cx, cy)


## Who lives in a chunk made just now: the surface's biome's fauna, or the
## underground's (its generator's "fauna"), on cells one can stand on; a
## chunk populated before (fauna version `had`) gets only kinds new since.
func _populate(location: String, cx: int, cy: int, had := 0) -> void:
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
	var share := 1.0  # of the chunk's creatures: in an old chunk, as many as the new kinds' weight
	if had > 0:
		var all := 0.0
		for k: String in fauna:
			all += float(fauna[k])
		fauna = fauna.duplicate()
		for k: String in fauna.keys():
			if int(world.content.get_def(k).get("fauna_since", 1)) <= had:
				fauna.erase(k)
		var new := 0.0
		for k: String in fauna:
			new += float(fauna[k])
		share = new / maxf(all, 0.001)
	if fauna.is_empty():
		return
	var r := RandomNumberGenerator.new()
	r.seed = hash([world.world_seed, cx, cy, "fauna"] if location == Levels.SURFACE else [world.world_seed, location, cx, cy, "fauna"])
	var n := int(float(b["fauna_density"]) * share + r.randf())
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
			if _fits_at(location, cell, _half(kind), _walkable):
				_spawn(kind, location, cell, {}, hash([world.world_seed, location, cx, cy, i]))
				break


## How villagers may look: a body, a face, hair and colours (the editor's).
const VILLAGER_BODIES := ["base:human_m", "base:human_f"]
const VILLAGER_FACES := ["base:human_face_soft", "base:human_face_square", "base:human_face_angular"]
const VILLAGER_HAIR := ["base:human_hair_short", "base:human_hair_plain", "base:human_hair_long",
	"base:human_hair_ponytail", "base:human_hair_braid", "base:human_hair_bald"]
const VILLAGER_SKIN := ["#e4a47c", "#ea9f54", "#ae6b3f", "#7f4c31", "#76513a", "#442725"]
const VILLAGER_HAIR_COLORS := ["#1c2222", "#421603", "#7d4513", "#cc6901", "#bf9d5a", "#c0ab81", "#777777"]


## Looks of a villager, the same for the same random state.
static func villager_looks(r: RandomNumberGenerator) -> Dictionary:
	var pick := func(list: Array) -> String: return String(list[r.randi() % list.size()])
	return {"body_plan": pick.call(VILLAGER_BODIES),
		"styles": {"face": pick.call(VILLAGER_FACES), "hair": pick.call(VILLAGER_HAIR)},
		"colors": {"skin": pick.call(VILLAGER_SKIN), "hair": pick.call(VILLAGER_HAIR_COLORS)},
		"worn": WorldLibrary.STARTER_OUTFIT.duplicate()}


## The people and animals of settlements whose homes and pens are in a
## chunk made just now (ADR-0039): a dweller a home, sleeping in its bed,
## with its home's trade; the pen's animals, the village's.
func _settle(cx: int, cy: int) -> void:
	var settlements := world.generator.settlements if world.generator else null
	if settlements == null:
		return
	var chunk := Rect2i(cx * Chunk.SIZE, cy * Chunk.SIZE, Chunk.SIZE, Chunk.SIZE)
	for plan: Dictionary in settlements.plans_touching(cx, cy):
		var homes: Array = plan["homes"]
		for i in homes.size():
			var bed: Vector2i = homes[i]["bed"]
			if bed == Settlements.NONE or not chunk.has_point(bed):
				continue
			var r := RandomNumberGenerator.new()
			r.seed = hash([world.world_seed, plan["id"], i])
			var c := _spawn("base:villager", Levels.SURFACE, bed, villager_looks(r), r.randi())
			c.job = {"village": plan["id"], "home": i, "profession": String(homes[i]["dweller"]),
				"name": String(world.chronicles.dweller_name(plan["id"], i)[0])}
			c.changed()
		var pen: Dictionary = plan["pen"]
		if pen.is_empty() or not chunk.has_point((pen["rect"] as Rect2i).get_center()):
			continue
		var inside := (pen["rect"] as Rect2i).grow(-1)
		var k := 0
		for kind: String in pen["animals"]:
			for n in int(pen["animals"][kind]):
				var cell := inside.position + Vector2i(k % inside.size.x, (k / inside.size.x) % inside.size.y)
				var a := _spawn(kind, Levels.SURFACE, cell, {}, hash([world.world_seed, plan["id"], "pen", k]))
				a.owner = String(plan["id"])
				a.home = inside.get_center()
				a.changed()
				k += 1


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
		var looks := villager_looks(r) if kind == "base:villager" else {}
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


## One of its kind was struck by `who` at `at`: those that stand up for their
## kin and see who did it take that one for their own attacker.
func kin_struck(c: Creature, who: String, at: Vector2i) -> void:
	var cx := c.cell().x >> 5
	var cy := c.cell().y >> 5
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for oid: String in in_chunk(c.location, cx + dx, cy + dy):
				var o := get_creature(oid)
				if o == null or o == c or o.kind != c.kind or o.health == 0:
					continue
				var def := world.content.get_def(o.kind)
				if not def.get("reaction", {}).get("kin", false):
					continue
				var me := o.cell()
				if absi(at.x - me.x) > def["sight"] or absi(at.y - me.y) > def["sight"]:
					continue
				if Perception.sees(world, o.location, me, def, at, o.location):
					o.memory[who] = {"pos": at, "time": world.world_time, "what": "attacker"}
					alarm(o)


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
	if _fight_back(c, def):
		pass
	elif c.owner != "" and def.has("tame"):
		_tame(c, def)
	else:
		_behave(c, def)
	if c.target != Creature.NO_TARGET:
		_movers[c.id] = true
	else:
		_movers.erase(c.id)
	var soon := c.state in ["flee", "alert", "hunt", "attack", "loot", "follow", "walk"]
	_schedule(c, tick + (maxi(2, int(def["think_ticks"]) / 2) if soon else int(def["think_ticks"])))


func _behave(c: Creature, def: Dictionary) -> void:
	match String(def["behavior"]):
		"prey":
			_prey(c, def)
		"villager":
			if not c.job.is_empty():
				_dweller(c, def)
			else:
				_villager(c, def)
		"predator":
			_predator(c, def)
		"looter":
			_looter(c, def)


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
	if not c.job.is_empty():  # a dweller is where its day has it now
		var spot := _dweller_spot(c, _phase(c))
		if spot != Creature.NO_TARGET:
			var old_chunk := _chunk_of(c)
			c.pos = spot * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
			c.path.clear()
			c.state = "arrived"
			_index(c, old_chunk)
			_moved[c.id] = true
			c.changed()
			return
	if not (String(def["behavior"]) == "villager" and night):
		var radius := TAME_RADIUS if c.owner != "" else float(def["home_radius"])
		var spot := _spot_near(c, c.home, radius, int(world.world_time / 1000))
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
	var def := world.content.get_def(c.kind)
	for k: String in c.memory:
		var m: Dictionary = c.memory[k]
		if m["what"] == "noise" and world.world_time - int(m["time"]) > _ms(noise_s):
			continue
		if m["what"] == "character" and _holds_its_food(k, def):
			continue  # one holding out what it eats is let come close (ADR-0030)
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


## One that fights back (reaction "hurt": "fight") goes for who hurt it (or
## its kin) lately, running, and strikes within reach; badly hurt, it runs.
## A predator hunts in its own way (it attacks first too). True if it did.
func _fight_back(c: Creature, def: Dictionary) -> bool:
	if def["reaction"]["hurt"] != "fight" or String(def["behavior"]) == "predator":
		return false
	var attacker := _attacker(c, float(def["sight"]) * 1.5)
	if attacker.is_empty() or not world.present.has(attacker[2]):
		return false
	if c.health * 10 < int(def["health"]) * 3:
		var away := _away_from(c, attacker[0], 12.0)
		if away != Creature.NO_TARGET:
			_go(c, "flee", away, true)
			return true
	if world.combat.creature_attack(c, attacker[2]):
		_go(c, "attack", Creature.NO_TARGET, false)
	else:
		var p: Dictionary = world.present[attacker[2]]
		_go(c, "hunt", Movement.cell_of(p["pos"]), true)  # it sees where it is now
	return true


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


## Looters (ADR-0016): about their range they go for things lying near that
## are anyone's (what a dead one dropped is left while it is kept for them)
## and swallow them, a stack each, as many as the stomach holds; swallowed
## things are gone in digest_s, killed first it gives them back. Hurt, it
## runs; people it lets come close.
func _looter(c: Creature, def: Dictionary) -> void:
	digest(c)
	var attacker := _attacker(c, float(def["sight"]))
	if not attacker.is_empty():
		var away := _away_from(c, attacker[0], 10.0)
		if away != Creature.NO_TARGET:
			_go(c, "flee", away, true)
			return
	if c.stomach.size() < int(def["stomach"]):
		var found := _thing_near(c, float(def["sight"]))
		if found != "":
			var it: Dictionary = world.items[found]
			var at := Vector2i(int(it["x"]), int(it["y"]))
			if Movement.cell_of(at) == c.cell() or Vector2(c.pos).distance_to(Vector2(at)) <= Movement.UNIT:
				world.take_item(found, null)
				c.stomach.append({"item": String(it["item"]), "count": int(it["count"]), "at": world.world_time})
				c.changed()
				_go(c, "eat", Creature.NO_TARGET, false)
				return
			_go(c, "loot", Movement.cell_of(at), false)
			return
	if c.target != Creature.NO_TARGET and c.state == "wander":
		return
	if c.rand(int(world.world_time / 1000) + c.next_think) < 0.4:
		var spot := _spot_near(c, c.home, float(def["home_radius"]), c.next_think)
		if spot != Creature.NO_TARGET:
			_go(c, "wander", spot, false)
			return
	_go(c, "idle", Creature.NO_TARGET, false)


## Husbandry (ADR-0030): one's own animal keeps near where it was left (a
## pen), follows its owner holding out what it eats (and stays where it was
## led), runs from who hurts it, rests at night. Fed within FED_HOURS it
## gives its produce and breeds with another fed one of its kind near.
const TAME_RADIUS := 2.0
const FED_HOURS := 24.0
const BREED_NEAR := 3.0
## No young where this many of its kind are about (within 8 cells).
const HERD_CAP := 8


func _tame(c: Creature, def: Dictionary) -> void:
	var attacker := _attacker(c, float(def["sight"]))
	if not attacker.is_empty():
		var away := _away_from(c, attacker[0], 8.0)
		if away != Creature.NO_TARGET:
			_go(c, "flee", away, true)
			return
	if fed_lately(c):
		_produce(c, def)
		_breed(c, def)
	var m: Dictionary = c.memory.get(c.owner, {})
	if not m.is_empty() and int(m["time"]) == world.world_time and _holds_its_food(c.owner, def):
		var d := Vector2(c.cell()).distance_to(Vector2(m["pos"]))
		if d > 1.5:
			_go(c, "follow", m["pos"], false)
		else:
			_go(c, "look", Creature.NO_TARGET, false)
		_home_here(c)
		return
	if c.state == "follow":
		_home_here(c)  # led here: it stays here
	if Daylight.is_night(world.world_time) and world.has_daylight(c.location):
		if c.target == Creature.NO_TARGET:
			_go(c, "rest", Creature.NO_TARGET, false)
		return
	if c.target != Creature.NO_TARGET and c.state == "wander":
		return
	if c.rand(int(world.world_time / 1000) + c.next_think) < 0.3:
		var spot := _spot_near(c, c.home, TAME_RADIUS, c.next_think)
		if spot != Creature.NO_TARGET:
			_go(c, "wander", spot, false)
			return
	_go(c, "graze", Creature.NO_TARGET, false)


func _home_here(c: Creature) -> void:
	if c.home != c.cell():
		c.home = c.cell()
		c.changed()


## Whether a present character holds out a thing this kind eats.
func _holds_its_food(pid: String, def: Dictionary) -> bool:
	var food: Array = def.get("tame", {}).get("food", [])
	return not food.is_empty() and food.has(world.held_of(pid))


func fed_lately(c: Creature) -> bool:
	return c.fed_at >= 0 and world.world_time - c.fed_at <= int(FED_HOURS * Daylight.HOUR_MS)


## Its produce (an egg, wool) on the ground where it is, every so often.
func _produce(c: Creature, def: Dictionary) -> void:
	var pr: Dictionary = def.get("produce", {})
	if pr.is_empty():
		return
	if c.made_at < 0 or world.world_time - c.made_at >= int(float(pr["hours"]) * Daylight.HOUR_MS):
		if c.made_at >= 0:
			world.place_item(c.location, c.pos, String(pr["item"]), 1)
		c.made_at = world.world_time
		c.changed()


## Young of two fed ones of a kind near each other, the owner's.
func _breed(c: Creature, def: Dictionary) -> void:
	var hours := float(def["tame"].get("breed_hours", 0.0))
	if hours <= 0.0:
		return
	var every := int(hours * Daylight.HOUR_MS)
	var now := world.world_time
	if c.bred_at >= 0 and now - c.bred_at < every:
		return
	var me := c.cell()
	var herd := 0
	var mate: Creature = null
	for cy in range((me.y - 8) >> 5, ((me.y + 8) >> 5) + 1):
		for cx in range((me.x - 8) >> 5, ((me.x + 8) >> 5) + 1):
			for id: String in in_chunk(c.location, cx, cy):
				var o := get_creature(id)
				if o == null or o.kind != c.kind or Vector2(o.cell()).distance_to(Vector2(me)) > 8.0:
					continue
				herd += 1
				if o != c and mate == null and o.owner != "" and fed_lately(o) \
						and Vector2(o.cell()).distance_to(Vector2(me)) <= BREED_NEAR and (o.bred_at < 0 or now - o.bred_at >= every):
					mate = o
	if mate == null or herd >= HERD_CAP:
		return
	var young := _spawn(c.kind, c.location, me, {}, hash([c.seed, mate.seed, now]))
	young.owner = c.owner
	young.home = c.home
	young.bred_at = now
	young.changed()
	_owned[young.id] = true
	for o: Creature in [c, mate]:
		o.bred_at = now
		o.changed()


## Fed by `who` (ServerWorld checks reach and the thing): counts toward
## taming a wild one; the last feed makes it `who`'s, where it stands.
func fed_by(c: Creature, who: String) -> bool:
	var tame: Dictionary = world.content.get_def(c.kind)["tame"]
	c.fed_at = world.world_time
	var tamed := false
	if c.owner == "":
		c.fed += 1
		if c.fed >= int(tame["feeds"]):
			c.owner = who
			c.home = c.cell()
			c.made_at = world.world_time
			_owned[c.id] = true
			tamed = true
	c.changed()
	alarm(c)
	return tamed


# --- dwellers (ADR-0039) -----------------------------------------------------

## The evening (by the fire) ends at this hour; then home to bed.
const EVENING_END := 21.0
## Seconds (real) between a dweller's words to someone near.
const SAY_EVERY := 25.0
## How far a dweller looks for a way (cells round its start and goal).
const ROUTE_MARGIN := 14
const ROUTE_MOST := 140


func _profession(c: Creature) -> Dictionary:
	return world.content.get_def(String(c.job.get("profession", "")))


func _plan_of(c: Creature) -> Dictionary:
	var s := world.generator.settlements if world.generator else null
	return s.plan_by_id(String(c.job.get("village", ""))) if s else {}


## "work", "evening" or "night", by the world's hour and the trade's hours.
func _phase(c: Creature) -> String:
	var hours: Array = _profession(c).get("hours", [7, 19])
	var h := Daylight.hour_of(world.world_time)
	if h >= float(hours[0]) and h < float(hours[1]):
		return "work"
	if h >= float(hours[1]) and h < EVENING_END:
		return "evening"
	return "night"


## Where a dweller's day has it: its work, the fire, its bed.
func _dweller_spot(c: Creature, phase: String) -> Vector2i:
	var plan := _plan_of(c)
	if plan.is_empty():
		return Creature.NO_TARGET
	var home: Dictionary = (plan["homes"] as Array)[int(c.job.get("home", 0)) % (plan["homes"] as Array).size()]
	var i := int(c.job.get("home", 0))
	match phase:
		"night":
			return home["bed"]
		"evening":
			var round := [Vector2i(-2, 0), Vector2i(2, 0), Vector2i(-1, 1), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-3, 1), Vector2i(3, 1)]
			return (plan["fire"] as Vector2i) + round[i % round.size()]
	var work := String(_profession(c).get("work", ""))
	if work == "field" and not (plan["fields"] as Array).is_empty():
		var f: Rect2i = plan["fields"][i % (plan["fields"] as Array).size()]
		var day := int(world.world_time / Daylight.DAY_MS) * 24 + int(Daylight.hour_of(world.world_time) / 2.0)
		var roll := absi(hash([c.seed, day]))
		return f.position + Vector2i(roll % f.size.x, (roll / 7) % f.size.y)  # another row every two hours
	if work == "pen" and not (plan["pen"] as Dictionary).is_empty():
		return (plan["pen"]["gate"] as Vector2i) + Vector2i(0, -1)
	if work == "water":
		if not c.job.has("water"):
			var spot := _water_spot(plan["fire"])
			c.job["water"] = [spot.x, spot.y]
			c.changed()
		var w: Array = c.job["water"]
		if Vector2i(int(w[0]), int(w[1])) != Creature.NO_TARGET:
			return Vector2i(int(w[0]), int(w[1]))
	if work.begins_with("station:"):
		var kind := work.substr(8)
		var r: Rect2i = home["rect"]
		for y in range(r.position.y + 1, r.end.y - 1):
			for x in range(r.position.x + 1, r.end.x - 1):
				if String(world.content.get_def(world.part_at(Levels.SURFACE, x, y)).get("station", "")) == kind:
					return Vector2i(x, y + 1)
	return (plan["fire"] as Vector2i) + Vector2i(0, 1)


## A dry cell by the water nearest a place (a fisher's), or NO_TARGET.
func _water_spot(from: Vector2i) -> Vector2i:
	var gen := world.generator
	for r in range(2, 70):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var at := from + Vector2i(dx, dy)
				if not gen.is_wet(at.x, at.y):
					continue
				# back toward the village to the first dry cell one can stand on
				var dir := Vector2(from - at).normalized()
				for k in range(1, 6):
					var back := at + Vector2i(Vector2(dir * k).round())
					if not gen.is_wet(back.x, back.y):
						return back
	return Creature.NO_TARGET


## A dweller's day: to work by its trade's hours, by the fire in the
## evening, to bed at night; it walks there by a found way, opening doors;
## at work it works (its tool in its hands); it speaks to one who comes near.
func _dweller(c: Creature, def: Dictionary) -> void:
	if not c.job.has("name"):  # settled before dwellers had names (ADR-0042)
		c.job["name"] = String(world.chronicles.dweller_name(String(c.job["village"]), int(c.job.get("home", 0)))[0])
		c.changed()
	var attacker := _attacker(c, 12.0)
	if not attacker.is_empty():
		var away := _away_from(c, attacker[0], 16.0)
		if away != Creature.NO_TARGET:
			c.path.clear()
			_dress(c, "", false)
			_go(c, "flee", away, true)
			return
	var phase := _phase(c)
	var spot := _dweller_spot(c, phase)
	if spot == Creature.NO_TARGET:
		_villager(c, def)
		return
	var prof := _profession(c)
	if _someone_close(c, 3.0) and (c.said_at < 0 or _tick - c.said_at > int(SAY_EVERY * Movement.TICK_RATE)):
		_speak(c, prof, phase)
	if Vector2(c.cell()).distance_to(Vector2(spot)) <= 1.0:
		c.path.clear()
		_dress(c, String(prof.get("holds", "")) if phase == "work" else "", phase == "night")
		if phase == "work":
			_work(c, spot, prof)
		_go(c, phase, Creature.NO_TARGET, false)
		return
	_dress(c, "", false)
	if c.path_to != spot or c.path.is_empty():
		c.path = _route(c, spot)
		c.path_to = spot
	while not c.path.is_empty() and c.path[0] == c.cell():
		c.path.pop_front()
	if c.path.is_empty():
		_go(c, "lost", Creature.NO_TARGET, false)  # no way there now (a door locked, a wall built)
		return
	_open_doors(c, c.cell(), c.path[0])
	_go(c, "walk", c.path[0], false)


## What a dweller holds and whether it sleeps (seen by all): a change is told.
func _dress(c: Creature, holds: String, sleeping: bool) -> void:
	if c.held != holds or c.asleep != sleeping:
		c.held = holds
		c.asleep = sleeping
		_cold[c.id] = true


## At work: now and then a stroke of its trade; a herder feeds the pen.
func _work(c: Creature, spot: Vector2i, prof: Dictionary) -> void:
	if c.rand(_tick) < 0.5:
		var toward := spot + Vector2i(0, -1)
		match String(prof.get("work", "")):
			"water":
				toward = c.cell() + Vector2i(Vector2(_toward_water(c)).round())
			"field":
				toward = c.cell() + Vector2i(1, 0)
		world.combat.swung(c.id, toward * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2))
	if String(prof.get("work", "")) == "pen":
		var plan := _plan_of(c)
		var pen: Rect2i = plan["pen"]["rect"]
		for cy in range(floori(pen.position.y / 32.0), floori((pen.end.y - 1) / 32.0) + 1):
			for cx in range(floori(pen.position.x / 32.0), floori((pen.end.x - 1) / 32.0) + 1):
				for id: String in in_chunk(Levels.SURFACE, cx, cy):
					var a := get_creature(id)
					if a and a.owner == String(plan["id"]) and not fed_lately(a):
						a.fed_at = world.world_time
						a.changed()


func _toward_water(c: Creature) -> Vector2:
	for d: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1)]:
		if world.generator.is_wet(c.cell().x + d.x * 2, c.cell().y + d.y * 2):
			return Vector2(d)
	return Vector2(0, 1)


## A line for one near: of the trade, by rain, night, evening, work, else a greeting.
func _speak(c: Creature, prof: Dictionary, phase: String) -> void:
	var lines: Dictionary = prof.get("lines", {})
	var key := "greet"
	if phase == "night":
		key = "night"
	elif world.has_daylight(c.location) and Weather.rain(world.weather_seed, world.world_time) > 0.2 and lines.has("rain"):
		key = "rain"
	elif phase == "evening":
		key = "evening"
	elif phase == "work" and c.rand(_tick + 1) < 0.6:
		key = "work"
	var pick: Array = lines.get(key, lines.get("greet", []))
	# By day, now and then of what it asks or of the village's news (ADR-0042).
	var told := world.chronicles.gossip(c, c.rand(_tick + 3)) if phase != "night" else ""
	if told != "":
		pick = [told]
	if pick.is_empty():
		return
	c.say = String(pick[int(c.rand(_tick + 2) * pick.size()) % pick.size()])
	c.said += 1
	c.said_at = _tick
	_cold[c.id] = true


## A way from a dweller's cell to `goal`: the cells where it turns, found
## over the cells round both (doors count as open: it opens them).
func _route(c: Creature, goal: Vector2i) -> Array[Vector2i]:
	var start := c.cell()
	var box := Rect2i(start, Vector2i.ONE).merge(Rect2i(goal, Vector2i.ONE)).grow(ROUTE_MARGIN)
	if box.size.x > ROUTE_MOST or box.size.y > ROUTE_MOST:
		return []
	var came := {start: start}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		if at == goal:
			break
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := at + d
			if came.has(n) or not box.has_point(n):
				continue
			if n != goal and not _free(c.location, n) and not _door(c.location, n):
				continue
			came[n] = at
			queue.append(n)
	if not came.has(goal):
		return []
	var cells: Array[Vector2i] = []
	var at := goal
	while at != start:
		cells.push_front(at)
		at = came[at]
	# Only where it turns (and the goal): it walks straight between them.
	var out: Array[Vector2i] = []
	for k in cells.size():
		var before: Vector2i = start if k == 0 else cells[k - 1]
		var after: Vector2i = cells[k + 1] if k + 1 < cells.size() else cells[k]
		if k + 1 == cells.size() or (cells[k] - before) != (after - cells[k]) or _door(c.location, cells[k]):
			out.append(cells[k])
	return out


func _door(location: String, cell: Vector2i) -> bool:
	var part := world.part_at(location, cell.x, cell.y)
	return part != "" and bool(world.content.get_def(part).get("openable", false))


## Opens the closed doors on the straight way from one cell to another.
func _open_doors(c: Creature, from: Vector2i, to: Vector2i) -> void:
	var step := Vector2i(signi(to.x - from.x), signi(to.y - from.y))
	var at := from
	for i in absi(to.x - from.x) + absi(to.y - from.y) + 1:
		if _door(c.location, at):
			world.open_door(c.location, at)
		if at == to:
			break
		at += step


## Ids whose open part (held, words, sleep) changed, for the replicas.
var _cold := {}


func take_cold_changes() -> Dictionary:
	var out := _cold
	_cold = {}
	return out


## Swallowed things whose time is up are gone (a looter's digest_s).
func digest(c: Creature) -> void:
	if c.stomach.is_empty():
		return
	var keep := _ms(float(world.content.get_def(c.kind).get("digest_s", 7200.0)))
	var left := c.stomach.filter(func(e: Dictionary) -> bool: return world.world_time - int(e["at"]) < keep)
	if left.size() != c.stomach.size():
		c.stomach = left
		c.changed()


## The nearest thing lying within `within` cells that it may take and sees: its id or "".
func _thing_near(c: Creature, within: float) -> String:
	var me := c.cell()
	var r := ceili(within)
	var best := ""
	var best_d := INF
	for cy in range(floori(float(me.y - r) / Chunk.SIZE), floori(float(me.y + r) / Chunk.SIZE) + 1):
		for cx in range(floori(float(me.x - r) / Chunk.SIZE), floori(float(me.x + r) / Chunk.SIZE) + 1):
			for id: String in world.items_in_chunk(c.location, cx, cy):
				var it: Dictionary = world.items[id]
				var d := Vector2(c.pos).distance_to(Vector2(int(it["x"]), int(it["y"]))) / Movement.UNIT
				if d <= within and d < best_d and world.may_take(c.id, it) \
						and Sight.clear(world, c.location, me, c.location, Movement.cell_of(Vector2i(int(it["x"]), int(it["y"])))):
					best = id
					best_d = d
	return best


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
	var np := Movement.step_at(c.pos, dx, dy, _solid_in(c.location), speed, _half(c.kind))
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
		var q := world.solid_in(location, true)  # never loads a chunk for a creature
		f = [q, q.solid]  # the object itself is kept: a method Callable does not keep it
		_solid_fns[location] = f
	return f[1]


## The world closes: let go of it (they hold each other).
func detach() -> void:
	world = null
	_solid_fns.clear()


## For placing creatures as chunks are made (the same seed, the same
## places, whatever order chunks come in): asks the world, loading if need be.
func _walkable(location: String, cell: Vector2i) -> bool:
	return not world.is_solid(location, cell.x, cell.y)


## For where a creature goes: only what is loaded; beyond that, nowhere.
func _free(location: String, cell: Vector2i) -> bool:
	return not (_solid_in(location).call(cell.x, cell.y) as bool)


## Half the box a kind of creature stands in (BodySize), in units.
func _half(kind: String) -> Vector2i:
	return BodySize.of(world.content.get_def(kind))["half"]


## Whether a creature fits standing in the middle of `cell` (all the cells
## its body covers are free): a big one does not go through a door.
func _fits(c: Creature, cell: Vector2i) -> bool:
	return _fits_at(c.location, cell, _half(c.kind), _free)


func _fits_at(location: String, cell: Vector2i, half: Vector2i, free: Callable) -> bool:
	var at := cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
	for covered: Vector2i in BodySize.cells(at, half):
		if not free.call(location, covered):
			return false
	return true


## A walkable cell within `radius` of `around`, or NO_TARGET.
func _spot_near(c: Creature, around: Vector2i, radius: float, salt: int) -> Vector2i:
	for attempt in 6:
		var a := c.rand(salt * 7 + attempt) * TAU
		var r := sqrt(c.rand(salt * 13 + attempt + 1)) * radius
		var cell := around + Vector2i(int(round(cos(a) * r)), int(round(sin(a) * r)))
		if _fits(c, cell):
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
		if _fits(c, cell):
			return cell
	return Creature.NO_TARGET
