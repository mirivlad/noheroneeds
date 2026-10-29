class_name Chronicles
extends RefCounted
## What a village remembers, and what its dwellers ask of others (ADR-0042).
## A village's chronicle starts with its past (its founding; a rock-seeker
## who went into a real cave near it, the thing he carried really lying
## there) and grows with what happens round it: predators come close, the
## seasons turn, a dweller is struck or killed, someone does what was asked.
## Stories are content ("story"): what an entry grows from, what it says,
## and maybe a request — hunt what was seen, fetch what is short, find what
## was lost. Requests are the dwellers': anyone may take one on; it is done
## once, by whoever brings it about, and that is written down too.
## The server's alone; kept in the world's meta, a village a key.

## How often villages look about.
const CHECK_MS := Daylight.HOUR_MS
## Predators within this many cells of the centre are seen by the village,
## at most once in PREDATORS_AGAIN_MS.
const PREDATORS_SEEN := 40
const PREDATORS_AGAIN_MS := 2 * Daylight.DAY_MS
## Chunks round a village searched for a cave mouth (its past).
const CAVE_SEARCH := 5
## Cells walked into the cave to where a lost thing lies, at least and most.
const LOST_FROM := 18
const LOST_TO := 40
## A struck dweller will not talk with the one who did it for this long.
const GRUDGE_MS := Daylight.DAY_MS
## Entries told when asked.
const SHOWN := 8
const NEVER := -1000000000000
const COIN := "base:coin"
const SEASONS := ["spring", "summer", "autumn", "winter"]
const DIRECTIONS := ["к востоку", "к юго-востоку", "к югу", "к юго-западу", "к западу", "к северо-западу",
	"к северу", "к северо-востоку"]

var world: ServerWorld
var _names := {}
## Story defs in id order: [{"id", "def"}].
var _stories: Array = []
## Village id -> its chronicle (as kept).
var _villages := {}
## Player -> {village id: true}: chronicles one has heard (the journal).
var _known := {}
var _last_check := NEVER


func _init(w: ServerWorld) -> void:
	world = w
	var ids: Array = []
	for id: String in w.content.defs:
		match w.content.kind_of(id):
			"story":
				ids.append(id)
			"names":
				if _names.is_empty():
					_names = w.content.get_def(id)
	ids.sort()
	for id: String in ids:
		_stories.append({"id": id, "def": w.content.get_def(id)})


# --- who's who ----------------------------------------------------------------------

## A dweller's name and whether it is a woman's: of its home, as the seed
## says (the same as its looks: CreatureSim._settle).
func dweller_name(village: String, home: int) -> Array:
	var r := RandomNumberGenerator.new()
	r.seed = hash([world.world_seed, village, home])
	var body: String = CreatureSim.VILLAGER_BODIES[r.randi() % CreatureSim.VILLAGER_BODIES.size()]
	var fem: bool = world.content.get_def(body).get("feminine", false)
	var list: Array = _names.get("female" if fem else "male", [])
	if list.is_empty():
		return ["", fem]
	var base := absi(hash([world.world_seed, village, "names"]))
	return [String(list[(base + home * 5) % list.size()]), fem]


func _player_vars(actor: String) -> Dictionary:
	var p: Dictionary = world.present.get(actor, {})
	var body := String((p.get("appearance", {}) as Dictionary).get("body_plan", ""))
	return {"player": String(p.get("name", "Путник")), "player_a": "а" if world.content.get_def(body).get("feminine", false) else ""}


func _trade_name(profession: String) -> String:
	return String(world.content.get_def(profession).get("name", "житель")).to_lower()


# --- a village's chronicle -------------------------------------------------------------

## A village's chronicle: kept, or begun now (its past).
func of(id: String) -> Dictionary:
	if _villages.has(id):
		return _villages[id]
	var raw := world.fact("chronicle|" + id)
	var v: Variant = JSON.parse_string(raw) if raw != "" else null
	if typeof(v) != TYPE_DICTIONARY:
		v = _found(id)
		_villages[id] = v
		_save(id)
	_villages[id] = v
	return v


func _save(id: String) -> void:
	world.note_fact("chronicle|" + id, JSON.stringify(_villages[id]))


func _plan(id: String) -> Dictionary:
	return world.generator.settlements.plan_by_id(id) if world.generator and world.generator.settlements else {}


## A village's past: its founding stories, from the seed and the world as it
## is round it (a story that needs a cave has one only if there is a cave).
## A village's name: of the seed and its id, the same before its chronicle
## is begun (the map names it without beginning one).
func village_name(id: String) -> String:
	if _villages.has(id):
		return String(_villages[id]["name"])
	var villages: Array = _names.get("villages", ["Деревня"])
	return String(villages[absi(hash([world.world_seed, id, "chronicle"])) % villages.size()])


func _found(id: String) -> Dictionary:
	var h := absi(hash([world.world_seed, id, "chronicle"]))
	var v := {"name": village_name(id), "entries": [], "requests": [], "season": "",
		"predators_at": NEVER, "grudges": {}, "dead": [], "next": 1}
	_villages[id] = v
	var plan := _plan(id)
	var founder := dweller_name(id, 97)  # one before them all
	var vars := {"village": v["name"], "founder": founder[0], "founder_a": "а" if founder[1] else "",
		"ago": 40 + h % 50}
	for s: Dictionary in _stories:
		var d: Dictionary = s["def"]
		if d["from"] != "founding":
			continue
		var more := vars.duplicate()
		more["ago"] = int(vars["ago"]) if not d.has("request") else 8 + h % 15
		if d.get("needs") == "cave":
			var lost := _lose_in_cave(id, plan, d)
			if lost.is_empty():
				continue
			more.merge(lost)
		_happen(id, s["id"], more, -1)
	return v


## Where a story's thing is lost in a cave near the village: {lost, item,
## item_id, dir, far, _spot} ({} if no cave mouth is near). It is put there
## whenever its chunk is loaded (things on the ground do not outlast a
## restart, ADR-0016): see lie_lost.
func _lose_in_cave(id: String, plan: Dictionary, d: Dictionary) -> Dictionary:
	if world.underground == null or plan.is_empty():
		return {}
	var centre: Vector2i = plan["centre"]
	var cc := Vector2i(floori(centre.x / float(Chunk.SIZE)), floori(centre.y / float(Chunk.SIZE)))
	var mouth := UndergroundGenerator.NONE
	for dy in range(-CAVE_SEARCH, CAVE_SEARCH + 1):
		for dx in range(-CAVE_SEARCH, CAVE_SEARCH + 1):
			var at := world.underground.entrance_at(-1, cc.x + dx, cc.y + dy)
			if at != UndergroundGenerator.NONE and (mouth == UndergroundGenerator.NONE
					or Vector2(at - centre).length() < Vector2(mouth - centre).length()):
				mouth = at
	if mouth == UndergroundGenerator.NONE:
		return {}
	var spot := _deep_in(mouth, absi(hash([world.world_seed, id, "lost"])))
	var items: Array = d["request"]["items"]
	var item := String(items[absi(hash([world.world_seed, id, "item"])) % items.size()])
	var dir := Vector2(mouth - centre)
	var lost: Array = _names.get("male", ["Аким"])
	return {"lost": String(lost[absi(hash([world.world_seed, id, "lost_one"])) % lost.size()]), "item_id": item,
		"item": String(world.content.get_def(item).get("name", item)).to_lower(),
		"dir": DIRECTIONS[posmod(roundi(dir.angle() / (PI / 4.0)), 8)], "far": maxi(10, roundi(dir.length() / 10.0) * 10),
		"_spot": [spot.x, spot.y]}


## A cell of the cave below a mouth, LOST_FROM..LOST_TO cells walked from it
## (as far as the cave goes, if it is smaller).
func _deep_in(mouth: Vector2i, roll: int) -> Vector2i:
	var seen := {mouth: 0}
	var queue: Array[Vector2i] = [mouth]
	var far: Array[Vector2i] = []
	var last := mouth
	var i := 0
	while i < queue.size() and i < 6000:
		var at := queue[i]
		i += 1
		last = at
		var steps: int = seen[at]
		if steps >= LOST_FROM:
			far.append(at)
			if steps >= LOST_TO:
				continue
		for dir: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
			var next := at + dir
			if not seen.has(next) and world.underground.is_cave(next.x, next.y, -1):
				seen[next] = steps + 1
				queue.append(next)
	return far[roll % far.size()] if not far.is_empty() else last


## A story happens to a village: its entry is written (at a world time, or
## -1 for its past) and its request, if any and if someone is there to make
## it, is made.
func _happen(id: String, story: String, vars: Dictionary, at: int) -> void:
	var v: Dictionary = _villages[id]
	var d := world.content.get_def(story)
	var all := {}
	for k: String in vars:
		if not k.begins_with("_"):
			all[k] = str(vars[k])  # kept as text: whole numbers stay whole through JSON
	all["village"] = v["name"]
	(v["entries"] as Array).append({"at": at, "text": String(d["entry"]).format(all)})
	if d.has("request"):
		var r: Dictionary = d["request"]
		var asker := _asker(id, String(r["asker"]), absi(hash([world.world_seed, id, story, at])))
		if asker >= 0:
			var n := int(v["next"])
			v["next"] = n + 1
			(v["requests"] as Array).append({"n": n, "story": story, "kind": String(r["kind"]), "asker": asker,
				"vars": all, "item": String(vars.get("item_id", r.get("item", ""))), "count": int(vars.get("count", r["count"])),
				"target": String(vars.get("target", "")), "radius": int(r["radius"]), "reward": int(r["reward"]),
				"takers": {}, "state": "open", "at": at})
			if vars.has("_spot"):
				var req: Dictionary = (v["requests"] as Array).back()
				req["spot"] = vars["_spot"]
				req["picker"] = ""
				var key := _lost_key(Vector2i(int(vars["_spot"][0]), int(vars["_spot"][1])))
				world.note_fact("lost|" + key, "%s|%d" % [id, n])
				var cell := Vector2i(int(vars["_spot"][0]), int(vars["_spot"][1]))
				if world.has_chunk(Levels.depth_id(-1), floori(cell.x / float(Chunk.SIZE)), floori(cell.y / float(Chunk.SIZE))):
					_lie(id, req)
	_save(id)


## A line of the village's life written now, as it is (a delivery from a
## neighbour, ADR-0066).
func note(id: String, text: String) -> void:
	var v := of(id)
	(v["entries"] as Array).append({"at": world.world_time, "text": text})
	_save(id)


func _lost_key(cell: Vector2i) -> String:
	return ServerWorld.chunk_key(Levels.depth_id(-1), floori(cell.x / float(Chunk.SIZE)), floori(cell.y / float(Chunk.SIZE)))


## A chunk was loaded: a thing lost there lies there again, while the
## request for it is open, it does not lie there already and the last one to
## pick it up does not carry it.
func lie_lost(location: String, cx: int, cy: int) -> void:
	if not Levels.is_depth(location):
		return
	var raw := world.fact("lost|" + ServerWorld.chunk_key(location, cx, cy))
	var p := raw.split("|")
	if p.size() != 2:
		return
	var v := of(p[0])
	for r: Dictionary in v["requests"]:
		if int(r["n"]) == int(p[1]):
			_lie(p[0], r)


func _lie(id: String, r: Dictionary) -> void:
	if r["state"] != "open" or not r.has("spot"):
		return
	var item := String(r["item"])
	var picker := String(r.get("picker", ""))
	if picker != "" and world.inventory(picker).count(item) > 0:
		return
	var cell := Vector2i(int(r["spot"][0]), int(r["spot"][1]))
	var loc := Levels.depth_id(-1)
	for i: String in world.items_in_chunk(loc, floori(cell.x / float(Chunk.SIZE)), floori(cell.y / float(Chunk.SIZE))):
		if String(world.items[i]["item"]) == item:
			return
	world.place_item(loc, cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2), item, 1)


## Someone picked a thing up: if a lost thing, it is theirs to carry (it
## does not lie in its place again while they have it).
func picked(actor: String, item: String) -> void:
	for id: String in _villages:
		for r: Dictionary in _villages[id]["requests"]:
			if r["state"] == "open" and r.has("spot") and String(r["item"]) == item:
				r["picker"] = actor
				_save(id)


## Which home asks: "any" (by the roll), "work:<place>" (a dweller working
## there, else any), a profession's. -1 if nobody alive there. One asking
## something already is asked of last: a dweller asks one thing at a time.
func _asker(id: String, who: String, roll: int) -> int:
	var plan := _plan(id)
	if plan.is_empty():
		return -1
	var homes: Array = plan["homes"]
	var dead: Array = _villages[id].get("dead", [])
	var busy := {}
	for r: Dictionary in _villages[id].get("requests", []):
		if r["state"] == "open":
			busy[int(r["asker"])] = true
	var free: Array = []
	var asking: Array = []
	for i in homes.size():
		if not dead.has(i) and not dead.has(float(i)):
			(asking if busy.has(i) else free).append(i)
	var alive: Array = free + asking  # the free first
	if alive.is_empty():
		return -1
	if who == "any" and not free.is_empty():
		return free[roll % free.size()]
	if who.begins_with("work:"):
		for i: int in alive:
			if "work:" + String(world.content.get_def(String(homes[i]["dweller"])).get("work", "")) == who:
				return i
		who = "any"
	if who == "any":
		return alive[roll % alive.size()]
	for i: int in alive:
		if String(homes[i]["dweller"]) == who:
			return i
	return -1


# --- what happens round villages --------------------------------------------------------

## Now and then (CHECK_MS): villages with dwellers about see the season
## turn and predators come close.
func step() -> void:
	if _last_check != NEVER and world.world_time - _last_check < CHECK_MS:
		return
	_last_check = world.world_time
	var active := {}
	for c: Creature in world.creatures.creatures.values():
		if c.job.has("village"):
			active[String(c.job["village"])] = true
	for id: String in active:
		look_about(id)


func look_about(id: String) -> void:
	var v := of(id)
	var plan := _plan(id)
	if plan.is_empty():
		return
	var t := world.world_time
	var season := "%d:%d" % [int(t / Seasons.YEAR_MS), Seasons.of(t)]
	if v["season"] != season:
		v["season"] = season
		for s: Dictionary in _stories:
			if s["def"]["from"] == "season:" + SEASONS[Seasons.of(t)]:
				_happen(id, s["id"], {}, t)
		_save(id)
	if t - int(v["predators_at"]) >= PREDATORS_AGAIN_MS:
		var seen := {}
		for c: Creature in world.creatures.creatures.values():
			if c.location == Levels.SURFACE and String(world.content.get_def(c.kind).get("behavior", "")) == "predator" \
					and Vector2(Movement.cell_of(c.pos)).distance_to(Vector2(plan["centre"])) <= PREDATORS_SEEN:
				seen[c.kind] = int(seen.get(c.kind, 0)) + 1
		var kind := ""
		for k: String in seen:
			if kind == "" or int(seen[k]) > int(seen[kind]):
				kind = k
		if kind != "" and not _open_hunt(v, kind):
			v["predators_at"] = t
			var many := String(world.content.get_def(kind).get("many", String(world.content.get_def(kind).get("name", kind)).to_lower()))
			for s: Dictionary in _stories:
				if s["def"]["from"] == "predators":
					var most := int((s["def"] as Dictionary).get("request", {}).get("count", 1))
					_happen(id, s["id"], {"many": many, "Many": many.capitalize(), "target": kind,
						"count": mini(most, int(seen[kind]))}, t)


func _open_hunt(v: Dictionary, kind: String) -> bool:
	for r: Dictionary in v["requests"]:
		if r["state"] == "open" and r["kind"] == "hunt" and r["target"] == kind:
			return true
	return false


## A creature died (killer: who struck last): a dweller's death is written
## down; a predator a taker of a hunt killed near the village counts.
func died(c: Creature, killer: String) -> void:
	var hunter := world.creatures.get_creature(killer)
	if c.owner != "" and hunter and not _plan(c.owner).is_empty():
		of(c.owner)
		for s: Dictionary in _stories:
			if s["def"]["from"] == "livestock_killed":
				_happen(c.owner, s["id"], {"animal": String(world.content.get_def(c.kind).get("name", c.kind)).to_lower(),
					"hunter": String(world.content.get_def(hunter.kind).get("name", hunter.kind))}, world.world_time)
	if c.job.has("village"):
		var id := String(c.job["village"])
		var v := of(id)
		var home := int(c.job.get("home", -1))
		(v["dead"] as Array).append(home)
		for r: Dictionary in v["requests"]:
			if int(r["asker"]) == home and r["state"] == "open":
				r["state"] = "gone"
		var who := dweller_name(id, home)
		if world.present.has(killer):
			_trust(v, killer, KILL_TRUST)
		var by := String(world.present[killer].get("name", "")) if world.present.has(killer) else ""
		if by == "":
			var k := world.creatures.get_creature(killer)
			by = String(world.content.get_def(k.kind).get("name", "")).to_lower() if k else "неизвестно кто"
		for s: Dictionary in _stories:
			if s["def"]["from"] == "dweller_killed":
				_happen(id, s["id"], {"who": who[0], "who_a": "ла" if who[1] else "", "trade": _trade_name(String(c.job.get("profession", ""))),
					"killer": by}, world.world_time)
		return
	if not world.present.has(killer):
		return
	for id: String in _villages:
		var v: Dictionary = _villages[id]
		var plan := _plan(id)
		for r: Dictionary in v["requests"]:
			if r["state"] == "open" and r["kind"] == "hunt" and r["target"] == c.kind and (r["takers"] as Dictionary).has(killer) \
					and not plan.is_empty() and Vector2(Movement.cell_of(c.pos)).distance_to(Vector2(plan["centre"])) <= int(r["radius"]):
				r["takers"][killer] = mini(int(r["count"]), int(r["takers"][killer]) + 1)
				_save(id)


## A dweller was struck by someone (a player): written down, and it bears a
## grudge for a day.
func struck(c: Creature, by: String) -> void:
	if not c.job.has("village") or not world.present.has(by):
		return
	var id := String(c.job["village"])
	var v := of(id)
	var grudges: Dictionary = v["grudges"]
	var had := grudges.has(by) and int(grudges[by]) > world.world_time
	grudges[by] = world.world_time + GRUDGE_MS
	if had:
		_save(id)
		return
	_trust(v, by, STRIKE_TRUST)
	var who := dweller_name(id, int(c.job.get("home", -1)))
	var vars := _player_vars(by)
	vars["who"] = who[0]
	for s: Dictionary in _stories:
		if s["def"]["from"] == "dweller_hurt":
			_happen(id, s["id"], vars, world.world_time)
	_save(id)


# --- standing (ADR-0047) -------------------------------------------------------------

## How a village's trust in one moves: a request done, a dweller struck, killed.
const DONE_TRUST := 1
const STRIKE_TRUST := -1
const KILL_TRUST := -3


func _trust(v: Dictionary, actor: String, by: int) -> void:
	var standing: Dictionary = v.get_or_add("standing", {})
	standing[actor] = int(standing.get(actor, 0)) + by


## Where one stands with a dweller's village: the requests one did for it,
## less the harm one did there (0 — a stranger).
func standing(c: Creature, actor: String) -> int:
	if not c.job.has("village"):
		return 0
	return int((of(String(c.job["village"])).get("standing", {}) as Dictionary).get(actor, 0))


func bears_grudge(c: Creature, actor: String) -> bool:
	if not c.job.has("village"):
		return false
	return int((of(String(c.job["village"]))["grudges"] as Dictionary).get(actor, NEVER)) > world.world_time


# --- talk -------------------------------------------------------------------------------

## A dweller's word of what it asks or of its village's news (the last
## entry, if of the last NEWS_MS), now and then (`roll` 0..1); "" else.
const NEWS_MS := 2 * Daylight.DAY_MS


func gossip(c: Creature, roll: float) -> String:
	if not c.job.has("village"):
		return ""
	var pick := func(key: String) -> String:
		var list: Array = _names.get(key, [])
		return String(list[int(roll * 1000.0) % list.size()]) if not list.is_empty() else ""
	if roll < 0.4 and not request_of(c).is_empty():
		return pick.call("asks")
	var entries: Array = of(String(c.job["village"]))["entries"]
	if roll > 0.7 and not entries.is_empty() and int(entries.back()["at"]) >= 0 \
			and world.world_time - int(entries.back()["at"]) <= NEWS_MS:
		return String(pick.call("news")).format({"news": entries.back()["text"]})
	return ""


## The open request a dweller makes ({} if none).
func request_of(c: Creature) -> Dictionary:
	if not c.job.has("village"):
		return {}
	for r: Dictionary in of(String(c.job["village"]))["requests"]:
		if r["state"] == "open" and int(r["asker"]) == int(c.job.get("home", -1)):
			return r
	return {}


## Where one stands with a request: "offered", "doing", "ready".
func state_of(r: Dictionary, actor: String) -> String:
	if not (r["takers"] as Dictionary).has(actor):
		return "offered"
	match String(r["kind"]):
		"hunt":
			return "ready" if int(r["takers"][actor]) >= int(r["count"]) else "doing"
		_:
			return "ready" if world.inventory(actor).count(String(r["item"])) >= int(r["count"]) else "doing"


## What a dweller tells one who comes to talk: its name and trade, its
## village, its request and where one stands with it, the chronicle.
func talk(actor: String, c: Creature) -> Dictionary:
	var id := String(c.job["village"])
	var v := of(id)
	if not (_known.get(actor, {}) as Dictionary).has(id):
		if not _known.has(actor):
			_known[actor] = _read_known(actor)
		_known[actor][id] = true
		world.note_fact("known|" + actor, ",".join(PackedStringArray((_known[actor] as Dictionary).keys())))
	var who := dweller_name(id, int(c.job.get("home", -1)))
	var out := {"ok": true, "creature": c.id, "name": who[0], "profession": String(c.job.get("profession", "")),
		"village": v["name"], "chronicle": told(v), "standing": standing(c, actor)}
	if bears_grudge(c, actor):
		out["grudge"] = true
		return out
	var r := request_of(c)
	if not r.is_empty():
		out["request"] = shown(id, r, actor)
	return out


## A request as one is told it.
func shown(id: String, r: Dictionary, actor: String) -> Dictionary:
	var state := state_of(r, actor)
	var plan := _plan(id)
	var asker := dweller_name(id, int(r["asker"]))
	var trade := _trade_name(String(plan["homes"][int(r["asker"])]["dweller"])) if not plan.is_empty() else ""
	var vars: Dictionary = (r["vars"] as Dictionary).duplicate()
	vars.merge(_player_vars(actor), true)
	vars["count"] = int(r["count"])
	vars["progress"] = int((r["takers"] as Dictionary).get(actor, 0))
	vars["asker"] = asker[0]
	vars["asker_trade"] = trade
	var said: Dictionary = world.content.get_def(String(r["story"]))["request"]
	return {"n": int(r["n"]), "kind": String(r["kind"]), "state": state, "reward": int(r["reward"]),
		"says": String(said["ask"] if state == "offered" else said["doing"]).format(vars),
		"goal": String(said["goal"]).format(vars), "village": String(v_name(id))}


func v_name(id: String) -> String:
	return String(of(id)["name"])


## The chronicle's last entries as they are told: dated, or of old.
func told(v: Dictionary) -> Array:
	var out: Array = []
	var entries: Array = v["entries"]
	for i in range(maxi(0, entries.size() - SHOWN), entries.size()):
		var e: Dictionary = entries[i]
		var at := int(e["at"])
		out.append(String(e["text"]) if at < 0 else "%s, день %d, год %d. %s" % [Seasons.NAMES[Seasons.of(at)].capitalize(),
			Seasons.day_of(at), int(at / Seasons.YEAR_MS) + 1, e["text"]])
	return out


## One takes a dweller's request on.
func promise(actor: String, c: Creature) -> Dictionary:
	if bears_grudge(c, actor):
		return {"ok": false, "reason": "grudge"}
	var r := request_of(c)
	if r.is_empty():
		return {"ok": false, "reason": "no_request"}
	if not (r["takers"] as Dictionary).has(actor):
		r["takers"][actor] = 0
		_save(String(c.job["village"]))
	return talk(actor, c)


## One tells a dweller its request is done: what it asked for is handed
## over (the hunt is told), the reward given, the deed written down.
func report(actor: String, c: Creature) -> Dictionary:
	if bears_grudge(c, actor):
		return {"ok": false, "reason": "grudge"}
	var r := request_of(c)
	if r.is_empty():
		return {"ok": false, "reason": "no_request"}
	match state_of(r, actor):
		"offered":
			return {"ok": false, "reason": "not_taken"}
		"doing":
			return {"ok": false, "reason": "not_done"}
	var id := String(c.job["village"])
	var told_now := shown(id, r, actor)
	if r["kind"] != "hunt":
		world.inventory(actor).remove(String(r["item"]), int(r["count"]))
		world.touch_inventory(actor)
	if int(r["reward"]) > 0:
		world.give(actor, COIN, int(r["reward"]))
	r["state"] = "done"
	r["by"] = actor
	_trust(of(id), actor, DONE_TRUST)
	var vars: Dictionary = (r["vars"] as Dictionary).duplicate()
	vars.merge(_player_vars(actor), true)
	var said: Dictionary = world.content.get_def(String(r["story"]))["request"]
	var v := of(id)
	(v["entries"] as Array).append({"at": world.world_time, "text": String(said["deed"]).format(vars)})
	_save(id)
	var out := talk(actor, c)
	out["thanks"] = String(said["done"]).format(vars)
	out["reward"] = int(r["reward"])
	out["done"] = told_now["goal"]
	return out


## One's journal: the requests one took on and has not done, and the
## chronicles one has heard.
func journal(actor: String) -> Dictionary:
	if not _known.has(actor):
		_known[actor] = _read_known(actor)
	var requests: Array = []
	var chronicles: Array = []
	for id: String in _known[actor]:
		var v := of(id)
		for r: Dictionary in v["requests"]:
			if r["state"] == "open" and (r["takers"] as Dictionary).has(actor):
				requests.append(shown(id, r, actor))
		chronicles.append({"village": v["name"], "entries": told(v)})
	var contract := world.caravans.contract(actor)
	return {"ok": true, "requests": requests, "chronicles": chronicles,
		"escorts": [contract.duplicate(true)] if not contract.is_empty() else []}


func _read_known(actor: String) -> Dictionary:
	var out := {}
	var raw := world.fact("known|" + actor)
	for id: String in raw.split(",", false):
		out[id] = true
	return out
