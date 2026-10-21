extends TestCase
## ADR-0045: a world without the starter things — one comes with an empty
## bag and gets, by hand, fibre from grass, sticks from bushes and flint from
## loose stones near the spawn point; twists cord and makes flint tools in
## the hands; fells trees and builds a workbench; digs stone with the flint
## pick; makes the first stone axe and pick. In several worlds (seeds), with
## the server's own rules: reach, the tool in the hands, stations, wear.

var w: ServerWorld
var _content: ContentRegistry
var me := ""
## What was done, for the failure messages.
var _log: Array[String] = []
const RADIUS := 60


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())


func after_each() -> void:
	if w:
		w.close()
		w = null


func _open(seed_value: int) -> void:
	if w:
		w.close()
	w = ServerWorld.open(tmp_dir().path_join("world-%d.db" % seed_value), _content, {"seed": seed_value})
	_log.clear()
	var c := PortableCharacter.create("Ева", "base:human_f")
	c.character_id = "00000000-0000-4000-8000-%012d" % seed_value  # the dice (ADR-0047) the same every run
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	me = c.character_id


func _req(r: Dictionary) -> Dictionary:
	r["request_id"] = Uuid.v4()
	w.handle(me, r)
	w.sync()
	for ack: Array in w.take_acks():
		if ack[1] == r["request_id"]:
			return ack[2]
	return {}


func _wait(ticks := 25) -> void:
	for i in ticks:
		w.tick += 1
		w.combat.step(w.tick)


func _cover(loc: String, at: Vector2i) -> String:
	return w.chunk(loc, at.x >> 5, at.y >> 5).get_cell("cover", at.x & 31, at.y & 31)


func _structure(loc: String, at: Vector2i) -> String:
	return w.chunk(loc, at.x >> 5, at.y >> 5).get_cell("structure", at.x & 31, at.y & 31)


## Cells round the spawn point, nearest first, whose cover (or rock) is one of `kinds`.
func _find(loc: String, kinds: Array, layer := "cover", around := Vector2i.ZERO, most := RADIUS) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r in range(0, most):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var at := around + Vector2i(dx, dy)
				if (_cover(loc, at) if layer == "cover" else _structure(loc, at)) in kinds:
					out.append(at)
	return out


## Stands on a free cell beside `at` (walking there is not what is tested).
func _stand_beside(loc: String, at: Vector2i) -> bool:
	for d: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1)]:
		var c := at + d
		if not w.is_solid(loc, c.x, c.y) and _structure(loc, c) == "":
			w.present[me]["location"] = loc
			w.move_character(me, c * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2))
			return true
	return false


## Works a thing (by hand, or with what is held) until it is gone; returns what came.
func _work(loc: String, at: Vector2i, layer: String, item := "") -> Dictionary:
	if not _stand_beside(loc, at):
		return {}
	var got := {}
	for blow in 40:
		_wait()
		var r := {"type": "gather", "location": loc, "x": at.x, "y": at.y, "layer": layer}
		if item != "":
			r["item"] = item
		var res := _req(r)
		if not res.get("ok", false):
			_log.append("%s at %s: %s" % [layer, at, res])
			return got
		if res.has("drops"):
			for id: String in res["drops"]:
				got[id] = int(got.get(id, 0)) + int(res["drops"][id])
			return got
	return got


func _bag(id: String) -> int:
	return w.inventory(me).count(id)


## Gathers by hand from the nearest of `kinds` until `want` of `item` are carried.
func _gather_until(kinds: Array, item: String, want: int) -> bool:
	for at: Vector2i in _find("surface", kinds):
		if _bag(item) >= want:
			break
		_work("surface", at, "cover")
	return _bag(item) >= want


## The whole way from nothing to a stone axe and a stone pick.
func _from_nothing(seed_value: int) -> void:
	_open(seed_value)
	var what := "seed %d: " % seed_value
	eq(w.inventory(me).stacks, {}, what + "nothing at all to begin with")
	# Stone and trees cannot be had by hand.
	var tree := _find("surface", ["base:birch", "base:oak", "base:spruce", "base:fir", "base:maple", "base:dead_tree"])
	check(not tree.is_empty(), what + "trees near the spawn point")
	if tree.is_empty():
		return
	_stand_beside("surface", tree[0])
	_wait()
	eq(_req({"type": "gather", "location": "surface", "x": tree[0].x, "y": tree[0].y, "layer": "cover"}).get("reason"), "no_tool",
		what + "a tree is not felled by hand")
	# 1. By hand: fibre, sticks, flint — with some to spare: a novice fails
	# now and then (ADR-0047), and a failure spoils half of what it took.
	check(_gather_until(["base:tall_grass", "base:reeds", "base:cattail"], "base:fiber", 15), what + "fibre from grass and reeds: %s" % str(_log))
	check(_gather_until(["base:bush", "base:dry_bush"], "base:stick", 5), what + "sticks from bushes: %s" % str(_log))
	check(_gather_until(["base:pebbles"], "base:flint", 12), what + "flint from loose stones: %s" % str(_log))
	# 2. In the hands, known to all: cord and the flint tools.
	check(_make("base:twist_cord", "base:cord", 3), what + "cord from fibre: %s" % str(_log))
	check(_make("base:make_flint_axe", "base:flint_axe", 1) and _make("base:make_flint_pick", "base:flint_pick", 1),
		what + "flint axe and pick, no station: %s %s" % [str(_log), w.inventory(me).stacks])
	# 3. Logs with the flint axe.
	_req({"type": "hold", "item": "base:flint_axe"})
	for at: Vector2i in tree:
		if _bag("base:log") >= 7 or _bag("base:flint_axe") == 0:
			break
		_work("surface", at, "cover", "base:flint_axe")
	check(_bag("base:log") >= 7, what + "logs felled with flint: %d %s" % [_bag("base:log"), str(_log)])
	# 4. A workbench, planks.
	var spot := _free_spot()
	check(_req({"type": "build", "location": "surface", "x": spot.x, "y": spot.y, "part": "base:workbench"}).get("ok", false),
		what + "a workbench of logs")
	check(_make("base:saw_planks", "base:plank", 6), what + "planks at the workbench: %s" % str(_log))
	# 5. Stone with the flint pick: a boulder on the surface, else the rock of
	# the cave below the spawn point's way down.
	_req({"type": "hold", "item": "base:flint_pick"})
	for at: Vector2i in _find("surface", ["base:boulder"]):
		if _bag("base:stone") >= 12 or _bag("base:flint_pick") == 0:
			break
		_work("surface", at, "cover", "base:flint_pick")
	if _bag("base:stone") < 12 and _bag("base:flint_pick") > 0:
		var way := w._spawn_way()
		for at: Vector2i in _find("depth:-1", ["base:rock"], "structure", way, 20):
			if _bag("base:stone") >= 12 or _bag("base:flint_pick") == 0:
				break
			_work("depth:-1", at, "structure", "base:flint_pick")
	check(_bag("base:stone") >= 5, what + "stone dug with flint: %d %s" % [_bag("base:stone"), str(_log)])
	# 6. The first full tools, at the workbench, known to all.
	_stand_beside("surface", spot)
	check(_make("base:make_axe", "base:axe", 1) and _make("base:make_pickaxe", "base:pickaxe", 1),
		what + "a stone axe and a stone pick: %s %s" % [str(_log), w.inventory(me).stacks])
	eq([_bag("base:axe"), _bag("base:pickaxe")], [1, 1], what + "made")
	var axe := w.inventory(me).state_of("base:axe", 0)
	check(Wear.quality(axe) >= Mastery.WORST_QUALITY and Wear.quality(axe) < 1.0, what + "a novice's axe: %s" % str(axe))
	eq(String(axe.get("by", "")), "Ева", what + "with its maker's name")
	check(w.knowledge.mastery_level(me, "base:make_flint_axe") > 0, what + "practice made")


## What is got by hand, and where.
const BY_HAND := {"base:fiber": ["base:tall_grass", "base:reeds", "base:cattail"], "base:stick": ["base:bush", "base:dry_bush"],
	"base:flint": ["base:pebbles"]}


## Makes a recipe until `want` of `item` are carried — a novice fails now
## and then, and a failure spoils half its inputs: what runs short and is got
## by hand (or twisted of it) is got again, as a player would.
func _make(recipe: String, item: String, want: int) -> bool:
	var inputs: Dictionary = _content.get_def(recipe)["inputs"]
	for attempt in 20:
		if _bag(item) >= want:
			return true
		for need: String in inputs:
			var short := int(inputs[need]) - _bag(need)
			if short <= 0:
				continue
			if BY_HAND.has(need):
				_gather_until(BY_HAND[need], need, int(inputs[need]) + 2)
			elif need == "base:cord":
				_make("base:twist_cord", "base:cord", int(inputs[need]))
		var r := _req({"type": "craft", "recipe": recipe, "count": 1})
		if not r.get("ok", false):
			_log.append("craft %s: %s" % [recipe, r])
			return false
	return _bag(item) >= want


## A free cell near the spawn point to build on.
func _free_spot() -> Vector2i:
	for r in range(2, 30):
		for d: Vector2i in [Vector2i(r, 0), Vector2i(-r, 0), Vector2i(0, r), Vector2i(0, -r)]:
			if not w.is_solid("surface", d.x, d.y) and _cover("surface", d) == "" and _structure("surface", d) == "" \
					and _stand_beside("surface", d):
				return d
	return Vector2i(3, 3)


func test_from_an_empty_bag_to_stone_tools_in_several_worlds() -> void:
	for seed_value: int in [5, 21, 77, 1234]:
		_from_nothing(seed_value)


## The flint tools last the way to the stone ones (their wear is real, but
## not a chore): about 120 uses new, half that from a novice's hand.
func test_flint_tools_last_the_way_to_stone_ones() -> void:
	_from_nothing(21)
	var axe := _bag("base:flint_axe")
	var pick := _bag("base:flint_pick")
	eq([axe, pick], [1, 1], "both flint tools still there")
