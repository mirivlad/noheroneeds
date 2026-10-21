class_name Growth
extends RefCounted
## Plants live (ADR-0056). What is picked comes back: grass, flowers,
## mushrooms, reeds, a bush ("regrows": hours); a berry bush picked bears
## again; a felled tree leaves a stump, a sapling comes up by it, grows into
## a young tree and that into a tree of its kind ("grows": {into, hours}).
## Nothing grows while it freezes where it is (ADR-0055).
##
## Nothing is simulated cell by cell: a cell that will grow keeps when it
## began ("grow": {"since", "back" or "species"} in its cover's props), and
## when its chunk is in memory — loaded, or now and then while it stays —
## it is made what it has grown into by now. Worked out late, it comes out
## as it would have step by step.

## Seconds of play between passes over the chunks in memory that grow.
const EVERY_TICKS := Movement.TICK_RATE * 10

var world: ServerWorld
## Chunks in memory with something growing: key -> [location, cx, cy].
var _growing := {}


func _init(w: ServerWorld) -> void:
	world = w


## A plant was gathered at a cell and is now `becomes` ("" gone): it is
## marked to grow back or on.
func gathered(c: Chunk, location: String, cx: int, cy: int, lx: int, ly: int, thing: String, becomes: String) -> void:
	var grow := {}
	if becomes != "" and world.content.get_def(becomes).has("grows"):
		grow = {"since": world.world_time}
		var species := _species_of(c, lx, ly, thing)
		if species != "":
			grow["species"] = species
	elif becomes == "" and world.content.get_def(thing).has("regrows"):
		grow = {"since": world.world_time, "back": thing}
	if grow.is_empty():
		return
	world.set_cover_props(c, lx, ly, {"grow": grow})
	_growing[ServerWorld.chunk_key(location, cx, cy)] = [location, cx, cy]


## The kind of tree a cell's growth is of: kept from before, else the one
## felled.
func _species_of(c: Chunk, lx: int, ly: int, thing: String) -> String:
	var before: Dictionary = (c.get_props(lx, ly).get("cover", {}) as Dictionary).get("grow", {})
	if before.has("species"):
		return String(before["species"])
	return thing if world.content.get_def(thing).get("gather", {}).get("becomes", "") == "base:stump" else ""


## A chunk came into memory: what grew in it meanwhile is grown, and it is
## watched while it stays.
func arrived(location: String, cx: int, cy: int, c: Chunk) -> void:
	if catch_up(location, cx, cy, c):
		_growing[ServerWorld.chunk_key(location, cx, cy)] = [location, cx, cy]


## Now and then: the chunks in memory that grow catch up.
func step(tick: int) -> void:
	if tick % EVERY_TICKS != 0:
		return
	for key: String in _growing.keys():
		var at: Array = _growing[key]
		if not world.has_chunk(at[0], at[1], at[2]):
			_growing.erase(key)  # out of memory: it catches up when it comes back
			continue
		if not catch_up(at[0], at[1], at[2], world.chunk(at[0], at[1], at[2])):
			_growing.erase(key)


## Grows what is due in a chunk, as of now. Whether anything still grows.
func catch_up(location: String, cx: int, cy: int, c: Chunk) -> bool:
	var still := false
	var changed := false
	for i: int in c.props.keys():
		var cover: Dictionary = (c.props[i] as Dictionary).get("cover", {})
		if not cover.has("grow"):
			continue
		var lx := i % Chunk.SIZE
		var ly := i / Chunk.SIZE
		var grow: Dictionary = (cover["grow"] as Dictionary).duplicate()
		var warmth := world.climate_at(location, Vector2i(cx * Chunk.SIZE + lx, cy * Chunk.SIZE + ly)).x
		var steps := 0
		while steps < 8:
			steps += 1
			var now := c.get_cell("cover", lx, ly)
			if c.get_cell("structure", lx, ly) != "":
				grow = {}  # built over: nothing grows there
				break
			var next := ""
			var hours := 0.0
			if now == "":
				next = String(grow.get("back", ""))
				hours = float(world.content.get_def(next).get("regrows", 0.0))
			else:
				var g: Dictionary = world.content.get_def(now).get("grows", {})
				next = String(g.get("into", ""))
				hours = float(g.get("hours", 0.0))
				if next == "@species":
					next = String(grow.get("species", ""))
			if next == "" or hours <= 0.0:
				grow = {}
				break
			var since := float(grow["since"])
			var grown := float(world.world_time) - since - Seasons.frozen_ms(since, world.world_time, warmth)
			var need := hours * Daylight.HOUR_MS
			if grown < need:
				break
			c.set_cell("cover", lx, ly, next)
			changed = true
			# On from when it was due: what is left of the time grows the next stage.
			grow["since"] = float(world.world_time) - (grown - need)
			grow.erase("back")
			if not world.content.get_def(next).has("grows"):
				grow = {}
				break
		var rest := cover.duplicate()
		if grow.is_empty():
			rest.erase("grow")
		else:
			rest["grow"] = grow
			still = true
		if rest != cover:
			world.set_cover_props(c, lx, ly, rest, true)
	if changed:
		world.note_grown(location, cx, cy)
	return still


## A sapling planted (ADR-0056): on open ground, where trees grow — it grows
## into the tree of the place (the biome's own).
func plant(actor: String, r: Dictionary) -> Dictionary:
	var item := ServerWorld.rs(r, "item")
	var into := String(world.content.get_def(item).get("seedling", ""))
	if into == "":
		return {"ok": false, "reason": "bad_request"}
	if world.inventory(actor).count(item) < 1:
		return {"ok": false, "reason": "not_carried"}
	var p: Dictionary = world.present[actor]
	var loc := String(p["location"])
	var x := ServerWorld.ri(r, "x", 0)
	var y := ServerWorld.ri(r, "y", 0)
	if Vector2(Movement.cell_of(p["pos"])).distance_to(Vector2(x, y)) > 2.5:
		return {"ok": false, "reason": "too_far"}
	var cx := floori(float(x) / Chunk.SIZE)
	var cy := floori(float(y) / Chunk.SIZE)
	var c := world.chunk(loc, cx, cy)
	var lx := x - cx * Chunk.SIZE
	var ly := y - cy * Chunk.SIZE
	var ground := c.get_cell("ground", lx, ly)
	if c.get_cell("structure", lx, ly) != "" or c.get_cell("cover", lx, ly) != "" or ground == "" \
			or world.content.get_def(ground).get("solid", false) or world.content.get_def(ground).get("wade", false) \
			or world.content.get_def(ground).get("farmland", false):
		return {"ok": false, "reason": "occupied"}
	var species := tree_of(loc, x, y)
	if species == "":
		return {"ok": false, "reason": "no_trees_here"}
	world.inventory(actor).remove(item, 1)
	world.touch_inventory(actor)
	c.set_cell("cover", lx, ly, into)
	world.set_cover_props(c, lx, ly, {"grow": {"since": world.world_time, "species": species}})
	_growing[ServerWorld.chunk_key(loc, cx, cy)] = [loc, cx, cy]
	world.note_grown(loc, cx, cy)
	return {"ok": true, "species": species}


## The tree that grows at a place: of the trees of its biome, the most common
## ("" — none grow there: the steppe, the desert, off the surface).
func tree_of(location: String, x: int, y: int) -> String:
	if location != ServerWorld.SURFACE or world.generator == null:
		return ""
	var biome := world.generator.biome_id_at(x, y)
	var best := ""
	var most := 0.0
	var cover: Dictionary = world.content.get_def(biome).get("cover", {})
	for plant: String in cover:
		if String(world.content.get_def(plant).get("gather", {}).get("becomes", "")) == "base:stump" \
				and float(cover[plant]) > most:
			most = float(cover[plant])
			best = plant
	return best
