class_name AnimalLife
extends RefCounted
## Birth, food and dispersal (ADR-0057), on the creature's bounded schedule.
## Never generates terrain or replaces a dead animal. Unloaded lives catch
## up on return; a long absence cannot generate generations of offspring.

const CHECK_MS := Daylight.HOUR_MS
const FED_MS := 24 * Daylight.HOUR_MS
const HURT_MS := 6 * Daylight.HOUR_MS
const MATE_NEAR := 12.0

var world: ServerWorld
var _food := {}
var _food_hour := -1
var _changed := {}
## Loaded domestic animals' bounded searches. Not saved: food, paths and
## doors are checked again after loading, a terrain change or a new drop.
var _foraging := {}


func _init(w: ServerWorld) -> void:
	world = w


func take_changes() -> Dictionary:
	var out := _changed
	_changed = {}
	return out


func young(c: Creature, def: Dictionary, at := -1) -> bool:
	var now := world.world_time if at < 0 else at
	return c.born_at >= 0 and now - c.born_at < int(float(def.get("life", {}).get("mature_hours", 0)) * Daylight.HOUR_MS)


func hungry(c: Creature, at := -1) -> bool:
	return c.ate_at >= 0 and (world.world_time if at < 0 else at) - c.ate_at > FED_MS


func start(c: Creature) -> void:
	if c.life_at < 0:
		c.life_at = world.world_time
		c.ate_at = world.world_time
		if c.owner == "" and c.bred_at < 0:
			c.bred_at = world.world_time
		c.changed()


## True while alive. Food and aging also run in inactive loaded chunks.
func step(c: Creature, def: Dictionary) -> bool:
	if not def.has("life"):
		return true
	start(c)
	var now := world.world_time
	if now - c.life_at < CHECK_MS:
		return true
	var was_young := young(c, def, c.life_at)
	var was_hungry := hungry(c, c.life_at)
	var before := c.life_at
	c.life_at = now
	if c.owner == "":
		var slots := capacity(def, c.location, patch_of(c.cell()))
		var used := pressure(def, c.location, patch_of(c.cell()))
		# Stable allocation: a crowded patch cannot feed every animal by
		# letting each one independently see the same grass as unclaimed.
		if not (def["life"].get("forage", []) as Array).is_empty() and pressure(def, c.location, patch_of(c.cell()), c.id) <= slots:
			c.ate_at = now
		if c.migration == Creature.NO_TARGET and (used >= slots or hungry(c)):
			c.migration = _destination(c, def)
	elif not offered(c, def):
		forage(c, def, not world.creatures._active(c))
	var old_hurt := maxi(0, before - c.ate_at - FED_MS) / HURT_MS
	var new_hurt := maxi(0, now - c.ate_at - FED_MS) / HURT_MS
	if new_hurt > old_hurt:
		world.combat.hurt(c.id, new_hurt - old_hurt, "")
		if not world.creatures.has(c.id):
			return false
	if was_young != young(c, def) or was_hungry != hungry(c):
		_changed[c.id] = true
	c.changed()
	if c.owner == "" and not hungry(c) and not young(c, def):
		_breed(c, def)
	return true


func ate(c: Creature) -> void:
	c.ate_at = world.world_time
	_changed[c.id] = true
	c.changed()
	_foraging.erase(c.id)


func drop(id: String) -> void:
	_foraging.erase(id)


## An owner's visible offer takes priority over grazing or dropped feed.
func offered(c: Creature, def: Dictionary) -> bool:
	var p: Dictionary = world.present.get(c.owner, {})
	return not p.is_empty() and p["location"] == c.location and world.creatures._holds_its_food(c.owner, def) \
		and Perception.sees(world, c.location, c.cell(), def, Movement.cell_of(p["pos"]))


## Domestic animals eat reachable player feed first, otherwise forage.
## Full animals wait half a day before another meal; hand feeding keeps its
## own cooldown, so grazing never prevents accepting the player's food.
func forage(c: Creature, def: Dictionary, offscreen := false) -> bool:
	if world.world_time - c.ate_at < FED_MS / 2 or offered(c, def):
		return false
	var found: Dictionary = _foraging.get(c.id, {})
	if found.is_empty() or world.world_time - int(found["at"]) >= CHECK_MS \
			or int(found["revision"]) != world.revision_epoch or int(found["items"]) != world.items_rev:
		found = _find_food(c, def)
		_foraging[c.id] = found
	var goal: Vector2i = found["goal"]
	if goal == Creature.NO_TARGET:
		return false
	if offscreen or c.cell() == goal:
		var item := String(found["item"])
		if item != "":
			var it := world.take_item(item, null)
			if int(it["count"]) > 1:
				world.place_item(c.location, Vector2i(int(it["x"]), int(it["y"])), String(it["item"]), int(it["count"]) - 1,
					String(it.get("for", "")), int(it.get("until", 0)), (it.get("states", []) as Array).slice(1))
			c.fed_at = world.world_time  # player-provided feed does not use pasture capacity
		ate(c)
		world.creatures._go(c, "eat" if item != "" else "graze", Creature.NO_TARGET, false)
		return true
	var path: Array = found["path"]
	while not path.is_empty() and world.distance(c.pos, (path[0] as Vector2i) * Movement.UNIT + Vector2i(128, 128)) < 64:
		path.pop_front()
	if path.is_empty() or world.cell_distance(c.cell(), path[0]) > 1.5:
		_foraging.erase(c.id)  # led somewhere else meanwhile; find a route from there
		return false
	world.creatures._go(c, "forage", path[0], false)
	return true


## Flood only the loaded, walkable neighbourhood of its home. Closed gates
## stay closed; a cow's full body must fit. Unlike a straight line check,
## this also finds a reachable meal around a corner.
func _find_food(c: Creature, def: Dictionary) -> Dictionary:
	var result := {"at": world.world_time, "revision": world.revision_epoch, "items": world.items_rev,
		"goal": Creature.NO_TARGET, "item": "", "path": []}
	var radius := maxi(2, int(def["home_radius"]))
	var box := Rect2i(c.home - Vector2i(radius, radius), Vector2i.ONE * (radius * 2 + 1))
	var food := {}
	for cy in range(box.position.y >> 5, ((box.end.y - 1) >> 5) + 1):
		for cx in range(box.position.x >> 5, ((box.end.x - 1) >> 5) + 1):
			for id: String in world.items_in_chunk(c.location, cx, cy):
				var it: Dictionary = world.items[id]
				if (def.get("tame", {}).get("food", []) as Array).has(it["item"]) and world.may_take(c.id, it):
					food[Movement.cell_of(Vector2i(int(it["x"]), int(it["y"])))] = id
	var came := {c.cell(): c.cell()}
	var queue: Array[Vector2i] = [c.cell()]
	var pasture: Array[Vector2i] = []
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		if food.has(at):
			result["goal"] = at
			result["item"] = food[at]
			break
		if world.has_chunk(c.location, at.x >> 5, at.y >> 5):
			var ch := world.chunk(c.location, at.x >> 5, at.y >> 5)
			var forage: Array = def.get("life", {}).get("forage", [])
			if forage.has(ch.get_cell("ground", at.x & 31, at.y & 31)) or forage.has(ch.get_cell("cover", at.x & 31, at.y & 31)):
				pasture.append(at)
		for d: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
			var next := at + d
			if not came.has(next) and box.has_point(next) and world.creatures._fits(c, next):
				came[next] = at
				queue.append(next)
	if result["item"] == "" and not pasture.is_empty():
		var cells := pasture.size()
		if world.has_daylight(c.location) and Seasons.freezing(world.world_time, world.climate_at(c.location, c.cell()).x):
			cells = maxi(1, cells / 4)
		var slots := maxi(1, cells / int(def.get("life", {}).get("food_cells", 128)))
		var used := 0.0
		var ids := []
		for cy in range(box.position.y >> 5, ((box.end.y - 1) >> 5) + 1):
			for cx in range(box.position.x >> 5, ((box.end.x - 1) >> 5) + 1):
				ids.append_array(world.creatures.in_chunk(c.location, cx, cy))
		ids.sort()
		for id: String in ids:
			var o := world.creatures.get_creature(id)
			var other: Dictionary = world.content.get_def(o.kind).get("life", {})
			if came.has(o.cell()) and not _hand_fed(o) and (def.get("life", {}).get("forage", []) as Array).any(
					func(f: Variant) -> bool: return (other.get("forage", []) as Array).has(f)):
				used += float(other.get("food_cells", 128)) / float(def.get("life", {}).get("food_cells", 128))
			if id == c.id:
				break
		if used <= slots:
			result["goal"] = pasture[0]
	var at: Vector2i = result["goal"]
	while at != Creature.NO_TARGET and at != c.cell():
		(result["path"] as Array).push_front(at)
		at = came[at]
	return result


func _hand_fed(c: Creature) -> bool:
	return c.owner != "" and c.fed_at >= 0 and world.world_time - c.fed_at <= FED_MS


func offspring(c: Creature) -> void:
	c.born_at = world.world_time
	c.life_at = world.world_time
	c.ate_at = world.world_time
	c.bred_at = world.world_time
	_changed[c.id] = true
	c.changed()


## The wild animals of a kind in an already loaded patch, in stable order.
static func patch_of(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x >> 5, cell.y >> 5)


func residents(kind: String, location: String, patch: Vector2i) -> Array:
	var ids := []
	for id: String in world.creatures.in_chunk(location, patch.x, patch.y):
		var o := world.creatures.get_creature(id)
		if o and o.owner == "" and o.kind == kind:
			ids.append(id)
	ids.sort()
	return ids


## Kinds eating the same vegetation share its capacity. In units of this
## kind's food requirement; `through` allocates a stable prefix for grazing.
func pressure(def: Dictionary, location: String, patch: Vector2i, through := "") -> float:
	var forage: Array = def.get("life", {}).get("forage", [])
	if forage.is_empty():
		return float(residents(String(def["id"]), location, patch).size())
	var ids := world.creatures.in_chunk(location, patch.x, patch.y)
	ids.sort()
	var used := 0.0
	for id: String in ids:
		var o := world.creatures.get_creature(id)
		var other: Dictionary = world.content.get_def(o.kind).get("life", {})
		if not _hand_fed(o) and forage.any(func(f: Variant) -> bool: return (other.get("forage", []) as Array).has(f)):
			used += float(other.get("food_cells", 128)) / float(def["life"].get("food_cells", 128))
		if id == through:
			break
	return used


## Food-bearing cells / a kind's food requirement. A 4-cell sampling grid
## bounds the cost to 64 cells per kind/patch/hour (cached by terrain rev).
## Predators are supported by actual prey, rather than by grass.
func capacity(def: Dictionary, location: String, patch: Vector2i) -> int:
	if not world.has_chunk(location, patch.x, patch.y):
		return 0
	var life: Dictionary = def.get("life", {})
	var forage: Array = life.get("forage", [])
	if forage.is_empty():
		var prey := 0
		for id: String in world.creatures.in_chunk(location, patch.x, patch.y):
			var o := world.creatures.get_creature(id)
			if o and (life.get("prey", []) as Array).has(o.kind):
				prey += 1
		return prey / 2
	var hour := world.world_time / CHECK_MS
	if hour != _food_hour:
		_food.clear()
		_food_hour = hour
	var ch := world.chunk(location, patch.x, patch.y)
	var key := "%s|%s|%s" % [location, patch, def["id"]]
	var cached: Array = _food.get(key, [])
	var rev := world.chunk_revision(location, patch.x, patch.y)
	if not cached.is_empty() and int(cached[0]) == rev:
		return int(cached[1])
	var cells := 0
	for y in range(2, Chunk.SIZE, 4):
		for x in range(2, Chunk.SIZE, 4):
			if (forage.has(ch.get_cell("ground", x, y)) or forage.has(ch.get_cell("cover", x, y))) \
					and not Terrain.is_solid(ch, x, y, world.content, location != Levels.SURFACE):
				cells += 16
	var at := patch * Chunk.SIZE + Vector2i(16, 16)
	if world.has_daylight(location) and Seasons.freezing(world.world_time, world.climate_at(location, at).x):
		cells /= 4  # some dry grass remains under snow, but far less than in summer
	var slots := cells / int(life.get("food_cells", 128))
	_food[key] = [rev, slots]
	return slots


func ready(c: Creature, def: Dictionary) -> bool:
	var every := int(float(def.get("life", {}).get("breed_hours", 0)) * Daylight.HOUR_MS)
	return every > 0 and not young(c, def) and not hungry(c) \
		and world.world_time - (c.bred_at if c.bred_at >= 0 else c.ate_at) >= every


func _breed(c: Creature, def: Dictionary) -> void:
	if not ready(c, def) or c.migration != Creature.NO_TARGET:
		return
	var patch := patch_of(c.cell())
	if pressure(def, c.location, patch) + 1.0 > capacity(def, c.location, patch):
		return
	for id: String in c.memory:
		var o := world.creatures.get_creature(id)
		if o == null or o.kind != c.kind or o.owner != "" or not ready(o, def) \
				or o.location != c.location or world.cell_distance(c.cell(), o.cell()) > MATE_NEAR:
			continue
		if not Perception.sees(world, c.location, c.cell(), def, o.cell()) or not clear_route(c, o.cell()):
			continue
		var at := world.creatures._spot_near(c, c.cell(), 2.0, int(world.world_time / CHECK_MS))
		if at == Creature.NO_TARGET or patch_of(at) != patch:
			return
		var child := world.creatures._spawn(c.kind, c.location, at, {}, hash([c.seed, o.seed, world.world_time]))
		offspring(child)
		for parent: Creature in [c, o]:
			parent.bred_at = world.world_time
			parent.changed()
		return


## Only already loaded neighbouring land, with a clear walkable route.
## Relocation moves the original creature; it does not create a replacement.
func _destination(c: Creature, def: Dictionary) -> Vector2i:
	var here := patch_of(c.cell())
	var best := Creature.NO_TARGET
	var distance := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var patch := here + Vector2i(dx, dy)
			if patch == here:
				continue
			var spare := capacity(def, c.location, patch) - pressure(def, c.location, patch)
			if spare < 1.0:
				continue
			var origin := patch * Chunk.SIZE
			var at := origin + Vector2i(clampi(c.cell().x - origin.x, 3, 28), clampi(c.cell().y - origin.y, 3, 28))
			if world.cell_distance(c.cell(), at) >= distance or not clear_route(c, at):
				continue
			best = at
			distance = world.cell_distance(c.cell(), at)
	return best


func clear_route(c: Creature, at: Vector2i) -> bool:
	var from := c.cell()
	var steps := maxi(absi(at.x - from.x), absi(at.y - from.y))
	for i in range(1, steps + 1):
		var cell := Vector2i(Vector2(from).lerp(Vector2(at), float(i) / steps).round())
		if not world.creatures._fits(c, cell):
			return false
	return true


## Continues a real migration, or approaches a visible mate. Threats take
## priority in CreatureSim; domesticated animals stay where led.
func wander(c: Creature, def: Dictionary) -> bool:
	if c.owner != "" or not def.has("life"):
		return false
	if c.migration != Creature.NO_TARGET:
		if world.cell_distance(c.cell(), c.migration) <= 1.0:
			c.home = c.cell()
			c.migration = Creature.NO_TARGET
			c.changed()
		else:
			world.creatures._go(c, "migrate", c.migration, false)
			return true
	if ready(c, def):
		for id: String in c.memory:
			var o := world.creatures.get_creature(id)
			var m: Dictionary = c.memory[id]
			if o and o.owner == "" and o.kind == c.kind and ready(o, def) \
					and int(m["time"]) == world.world_time and world.cell_distance(c.cell(), m["pos"]) > 2.0:
				world.creatures._go(c, "mate", m["pos"], false)
				return true
	return false
