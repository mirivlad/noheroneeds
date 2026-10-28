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
## A village's coins to start with; below POOR it is poor, above RICH rich
## (ADR-0067: told in its chronicle once, till it mends).
const START_COINS := 300
const POOR := 60
const RICH := 900
## A trader's load: so many goods, so many of each at most.
const CARGO_GOODS := 3
const CARGO_EACH := 8

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
	return _goods(id)["makes"]


func needs(id: String) -> Dictionary:
	return _goods(id)["needs"]


## How far round a village its land is looked at, and how finely (cells).
const AROUND := 48
const AROUND_STEP := 8
var _goods_of := {}

## What a village makes and needs a day: its way of life's, and what the
## land round it adds (its kind's "surroundings" by biome, as much as that
## biome is of the land round): a forest village has wood to spare, a steppe
## one lacks it. Worked out once a village.
func _goods(id: String) -> Dictionary:
	if _goods_of.has(id):
		return _goods_of[id]
	var w := way_of(id)
	var out := {"makes": (w.get("makes", {}) as Dictionary).duplicate(), "needs": (w.get("needs", {}) as Dictionary).duplicate()}
	var plan := _plan(id)
	var around: Dictionary = world.content.get_def(String(plan.get("kind", ""))).get("surroundings", {}) if not plan.is_empty() else {}
	if not around.is_empty() and world.generator:
		var seen := {}
		var total := 0
		var c: Vector2i = plan["centre"]
		for dy in range(-AROUND, AROUND + 1, AROUND_STEP):
			for dx in range(-AROUND, AROUND + 1, AROUND_STEP):
				var b := world.generator.biome_id_at(c.x + dx, c.y + dy)
				if b != "":
					seen[b] = int(seen.get(b, 0)) + 1
					total += 1
		for b: String in seen:
			if not around.has(b):
				continue
			var share := float(seen[b]) / maxf(1.0, float(total))
			for f: String in ["makes", "needs"]:
				for item: String in around[b].get(f, {}):
					var n := roundi(float(around[b][f][item]) * share)
					if n > 0:
						out[f][item] = int(out[f].get(item, 0)) + n
	_goods_of[id] = out
	return out


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
		s = {"day": world.world_time / Daylight.DAY_MS, "stock": stock, "coins": START_COINS}
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


## What a thing is worth in coins anywhere (ADR-0067): the mean of what the
## trades sell and buy it for; 2 for what none trades.
var _worth := {}
func worth(item: String) -> int:
	if _worth.is_empty():
		var sums := {}
		for id: String in world.content.defs:
			if world.content.kind_of(id) != "profession":
				continue
			var t: Dictionary = world.content.get_def(id).get("trade", {})
			for i: String in t.get("sells", {}):
				(sums.get_or_add(i, []) as Array).append(int(t["sells"][i][1]))
			for i: String in t.get("buys", {}):
				(sums.get_or_add(i, []) as Array).append(int(t["buys"][i]))
		for i: String in sums:
			var a: Array = sums[i]
			_worth[i] = maxi(1, roundi(float(a.reduce(func(x: int, y: int) -> int: return x + y, 0)) / a.size()))
	return int(_worth.get(item, 2))


## A thing's price at a village: its worth, dearer as the village lacks it.
func price(id: String, item: String) -> int:
	return maxi(1, roundi(worth(item) * factor(id, item)))


func coins(id: String) -> int:
	return int(store(id).get("coins", START_COINS))


## Coins come into a village or go out of it (never below none); a village
## grown poor or rich is told in its chronicle, once till it mends.
func earn(id: String, n: int) -> void:
	var s := store(id)
	s["coins"] = maxi(0, int(s.get("coins", START_COINS)) + n)
	var state := "poor" if int(s["coins"]) < POOR else ("rich" if int(s["coins"]) > RICH else "")
	if state != String(s.get("told", "")):
		s["told"] = state
		if state != "" and world.chronicles:
			world.chronicles.note(id, "Деревня %s беднеет: в казне почти пусто." % world.chronicles.village_name(id) if state == "poor"
				else "Деревня %s богатеет: торговля идёт хорошо." % world.chronicles.village_name(id))
	_save(id)


## A trader's load from a village toward another: what the other lacks and
## this one has to spare, else what this one makes most of; {item: count}.
func cargo_for(from: String, to: String) -> Dictionary:
	var out := {}
	var wanted: Array[String] = short(to) if to != "" else []
	for item: String in wanted:
		var n := mini(CARGO_EACH, spare(from, item))
		if n > 0:
			out[item] = n
		if out.size() >= CARGO_GOODS:
			return out
	var made: Array = makes(from).keys()
	made.sort_custom(func(a: String, b: String) -> bool: return spare(from, a) > spare(from, b))
	for item: String in made:
		if out.size() >= CARGO_GOODS:
			break
		var n := mini(CARGO_EACH, maxi(spare(from, item), have(from, item) / 4))
		if n > 0 and not out.has(item):
			out[item] = n
	return out


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
			var each := price(other, item)
			# Paid for at the seller's price, as many as the buyer can pay for (ADR-0067).
			var got := mini(mini(lacking, spare(other, item)), int(s.get("coins", START_COINS)) / maxi(1, each))
			if got <= 0:
				continue
			_o["stock"][item] = int(_o["stock"][item]) - got
			_o["coins"] = int(_o.get("coins", START_COINS)) + got * each
			s["coins"] = int(s.get("coins", START_COINS)) - got * each
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
