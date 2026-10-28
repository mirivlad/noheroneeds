class_name VillageEconomy
extends RefCounted
## What villages have, make and need, and what they trade among themselves
## (ADR-0066). A village's store: its stock of goods, kept as a world fact
## ("economy|<village>"). Each day it makes what its way of life makes and
## eats what it needs ("makes", "needs" of its way); what it lacks makes the
## price at its dwellers' dear, what it has plenty of cheap; what it lacks it
## fetches from the villages of its cluster that have it to spare. Days are
## caught up when the village is asked about (trade, talk, a neighbour).

## Most days caught up at once; days of work the store holds at most; days
## a store starts with; below this many days of need a thing is short, and
## a neighbour's help fills it to so many.
const CATCH_UP := 10
const KEEP_DAYS := 8
const START_DAYS := 3
const SHORT_DAYS := 2
const FETCH_DAYS := 3
## What a village likes to hold: so many days of need and of making.
const WANT_NEED := 5
const WANT_MAKE := 3
## How far a price goes from the trade's, either way.
const DEAREST := 2.0
const CHEAPEST := 0.5
## A delivery this big is written in the chronicle.
const TOLD := 5

var world: ServerWorld
var _stores := {}


func _init(w: ServerWorld) -> void:
	world = w


func _plan(id: String) -> Dictionary:
	return world.generator.settlements.plan_by_id(id) if world.generator and world.generator.settlements else {}


## The way of life of a village's kind and place: {"makes", "needs"} ({} none).
func way_of(id: String) -> Dictionary:
	var plan := _plan(id)
	if plan.is_empty():
		return {}
	var ways: Array = world.content.get_def(String(plan.get("kind", ""))).get("ways", [])
	for w: Dictionary in ways:
		if String(w["id"]) == String(plan.get("way", "")):
			return w
	return ways[-1] if not ways.is_empty() else {}


func makes(id: String) -> Dictionary:
	return way_of(id).get("makes", {})


func needs(id: String) -> Dictionary:
	return way_of(id).get("needs", {})


## The village's store as it is today (days caught up, neighbours asked).
func store(id: String) -> Dictionary:
	var s := _store(id)
	var today := world.world_time / Daylight.DAY_MS
	if int(s["day"]) < today:
		var days := mini(int(today - int(s["day"])), CATCH_UP)
		for d in days:
			_live_a_day(id, s)
		s["day"] = today
		_fetch(id, s)
		_save(id)
	return s


func _store(id: String) -> Dictionary:
	if _stores.has(id):
		return _stores[id]
	var raw := world.fact("economy|" + id)
	var s: Variant = JSON.parse_string(raw) if raw != "" else null
	if typeof(s) != TYPE_DICTIONARY:
		var stock := {}
		for item: String in makes(id):
			stock[item] = int(makes(id)[item]) * START_DAYS
		for item: String in needs(id):
			stock[item] = int(stock.get(item, 0)) + int(needs(id)[item]) * START_DAYS
		s = {"day": world.world_time / Daylight.DAY_MS, "stock": stock}
	_stores[id] = s
	return s


func _save(id: String) -> void:
	world.note_fact("economy|" + id, JSON.stringify(_stores[id]))


func _live_a_day(id: String, s: Dictionary) -> void:
	var stock: Dictionary = s["stock"]
	for item: String in makes(id):
		var most := (int(makes(id)[item]) + int(needs(id).get(item, 0))) * KEEP_DAYS
		stock[item] = mini(int(stock.get(item, 0)) + int(makes(id)[item]), maxi(most, int(stock.get(item, 0))))
	for item: String in needs(id):
		stock[item] = maxi(0, int(stock.get(item, 0)) - int(needs(id)[item]))


## How many of a thing the village has now.
func have(id: String, item: String) -> int:
	return int((store(id)["stock"] as Dictionary).get(item, 0))


## What it likes to hold of a thing (0: not of its way).
func want(id: String, item: String) -> int:
	return int(needs(id).get(item, 0)) * WANT_NEED + int(makes(id).get(item, 0)) * WANT_MAKE


## What a thing's price is at the village, of the trade's price: dearer as it
## is short, cheaper as there is plenty; 1 for what is not of its way.
func factor(id: String, item: String) -> float:
	var w := want(id, item)
	if w <= 0:
		return 1.0
	return clampf(sqrt(float(w) / maxf(1.0, float(have(id, item)))), CHEAPEST, DEAREST)


## What the village lacks (less than SHORT_DAYS of need), most lacking first.
func short(id: String) -> Array[String]:
	var out: Array[String] = []
	for item: String in needs(id):
		if have(id, item) < int(needs(id)[item]) * SHORT_DAYS:
			out.append(item)
	out.sort_custom(func(a: String, b: String) -> bool: return factor(id, a) > factor(id, b))
	return out


## What it has to spare (over what it likes to hold).
func spare(id: String, item: String) -> int:
	return maxi(0, have(id, item) - want(id, item))


## Takes up to `n` of a thing out of the store (a dweller's stall); how many.
func take(id: String, item: String, n: int) -> int:
	var s := store(id)
	var got := mini(n, int((s["stock"] as Dictionary).get(item, 0)))
	if got > 0:
		s["stock"][item] = int(s["stock"][item]) - got
		_save(id)
	return got


## Puts things into the store (bought from a player).
func put(id: String, item: String, n: int) -> void:
	var s := store(id)
	s["stock"][item] = int((s["stock"] as Dictionary).get(item, 0)) + n
	_save(id)


## The other villages of its cluster (its neighbours, ADR-0054).
func neighbours(id: String) -> Array[String]:
	var out: Array[String] = []
	var plan := _plan(id)
	if plan.is_empty():
		return out
	var at := id.rfind("#")
	var cluster := id.substr(0, at)
	for p: Dictionary in world.generator.settlements.plans_near(plan["centre"], 400):
		var other := String(p["id"])
		if other != id and other.substr(0, other.rfind("#")) == cluster:
			out.append(other)
	return out


## What is short is fetched from neighbours with it to spare, up to
## FETCH_DAYS of need; a big delivery goes into the chronicle.
func _fetch(id: String, s: Dictionary) -> void:
	var stock: Dictionary = s["stock"]
	for item: String in needs(id):
		var need := int(needs(id)[item])
		if int(stock.get(item, 0)) >= need * SHORT_DAYS:
			continue
		for other: String in neighbours(id):
			var lacking := need * FETCH_DAYS - int(stock.get(item, 0))
			if lacking <= 0:
				break
			var _o := store_quiet(other)
			var got := mini(lacking, spare(other, item))
			if got <= 0:
				continue
			_o["stock"][item] = int(_o["stock"][item]) - got
			_save(other)
			stock[item] = int(stock.get(item, 0)) + got
			if got >= TOLD and world.chronicles:
				world.chronicles.note(id, "Из деревни %s привезли: %s (%d)." % [world.chronicles.village_name(other),
					String(world.content.get_def(item).get("name", item)).to_lower(), got])


## A neighbour's store caught up without asking its own neighbours (no round trips).
func store_quiet(id: String) -> Dictionary:
	var s := _store(id)
	var today := world.world_time / Daylight.DAY_MS
	if int(s["day"]) < today:
		for d in mini(int(today - int(s["day"])), CATCH_UP):
			_live_a_day(id, s)
		s["day"] = today
		_save(id)
	return s
