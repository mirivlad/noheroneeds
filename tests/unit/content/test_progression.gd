extends TestCase
## ADR-0045: no dead ends in the content. From nothing (no starter things),
## by what the world itself offers — what grows and lies about, what lives
## and can be hunted, rock below — and by recipes, stations and tools made
## of that, every tool, station, recipe and mend can be had in the end.

var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	eq(_content.errors, PackedStringArray())


## What grows on the land, lies on it, lives there, and the rock below.
func _natural() -> Dictionary:
	var out := {}
	for id: String in _content.defs:
		var d := _content.get_def(id)
		match String(d.get("kind", "")):
			"biome":
				for f: String in ["ground", "cover", "fauna"]:
					for t: String in d.get(f, {}):
						out[t] = true
			"generator":
				for f: String in ["water", "shore", "floor", "rock"]:
					if d.has(f):
						out[String(d[f])] = true
				for f: String in ["shore_cover", "fauna"]:
					for t: String in d.get(f, {}):
						out[t] = true
			"deposit":
				out[String(d["rock"])] = true
	return out


## Everything one can come to have, from nothing: items, tool kinds,
## stations. `only`: the recipes one may use ({} — all).
func _reach(only := {}) -> Dictionary:
	var natural := _natural()
	var have := {}  # item -> true
	var tools := {"": true}
	var stations := {}
	var more := {"yes": true}  # a lambda changes what it shares, not a local
	while more["yes"]:
		more["yes"] = false
		var got := func(id: String) -> void:
			if not have.has(id):
				have[id] = true
				more["yes"] = true
				for t: String in _content.get_def(id).get("tools", []):
					tools[t] = true
		# Sown on tilled land, a crop grows (ADR-0027).
		for id: String in have.keys():
			var crop := String(_content.get_def(id).get("plants", ""))
			if crop != "" and tools.has("tilling") and not natural.has(crop):
				natural[crop] = true
				more["yes"] = true
		for id: String in natural:
			var d := _content.get_def(id)
			var g: Dictionary = d.get("gather", {})
			if not g.is_empty() and tools.has(String(g["tool"])):
				for item: String in g.get("drops", {}):
					got.call(item)
				for item: String in g.get("pick", {}):
					got.call(item)
			if d.get("kind") == "creature":  # hunted (a fist will do, slowly), kept
				for item: String in d.get("drops", {}):
					got.call(item)
				if d.has("produce") and _all(d.get("tame", {}).get("food", []), have):
					got.call(String(d["produce"]["item"]))
		for id: String in _content.defs:
			var d := _content.get_def(id)
			if d.get("kind") == "recipe" and (only.is_empty() or only.has(id)) \
					and (not d.has("station") or stations.has(String(d["station"]))) and _all(d["inputs"].keys(), have):
				for item: String in d["outputs"]:
					got.call(item)
			if d.get("kind") == "structure" and d.has("station") and not stations.has(String(d["station"])) \
					and _all(_content.structure_cost(id).keys(), have):
				stations[String(d["station"])] = true
				more["yes"] = true
	return {"items": have, "tools": tools, "stations": stations}


func _all(ids: Array, have: Dictionary) -> bool:
	return ids.all(func(i: Variant) -> bool: return have.has(String(i)))


func test_from_nothing_every_tool_station_and_recipe_comes_within_reach() -> void:
	var r := _reach()
	var items: Dictionary = r["items"]
	for id: String in _content.defs:
		var d := _content.get_def(id)
		match String(d.get("kind", "")):
			"recipe":
				check(_all(d["inputs"].keys(), items), "%s: its inputs can be had" % id)
			"structure":
				if d.has("cost"):
					check(_all(_content.structure_cost(id).keys(), items), "%s: its cost can be had" % id)
			"item":
				if d.has("tools") or d.has("weapon"):
					check(items.has(id), "%s: can be had" % id)
				if d.has("repair"):
					check(_all((d["repair"]["materials"] as Dictionary).keys(), items), "%s: mended with what can be had" % id)
	for station: String in ["workbench", "forge", "fire"]:
		check((r["stations"] as Dictionary).has(station), "a %s can be built" % station)


func test_the_first_tools_need_no_tools_and_no_stations_but_a_workbench() -> void:
	# By hand alone (no recipe): fibre, sticks, flint — but no wood or stone.
	var hand := _reach({"none": true})
	for id: String in ["base:fiber", "base:stick", "base:flint"]:
		check((hand["items"] as Dictionary).has(id), "%s by hand" % id)
	for id: String in ["base:log", "base:stone"]:
		check(not (hand["items"] as Dictionary).has(id), "%s not by hand" % id)
	# The flint tools are made in the hands.
	for id: String in ["base:twist_cord", "base:make_flint_axe", "base:make_flint_pick"]:
		check(not _content.get_def(id).has("station"), "%s: in the hands" % id)
	# With the primitive recipes only: logs, stone, a workbench, the stone tools.
	var first := _reach({"base:twist_cord": true, "base:make_flint_axe": true, "base:make_flint_pick": true, "base:make_workbench": true,
		"base:saw_planks": true, "base:make_axe": true, "base:make_pickaxe": true})
	for id: String in ["base:log", "base:stone", "base:plank", "base:axe", "base:pickaxe"]:
		check((first["items"] as Dictionary).has(id), "%s from nothing" % id)
	check((first["stations"] as Dictionary).has("workbench"), "a workbench from nothing")


## ADR-0047: what is not known to all is learned somewhere — a dweller's
## trade teaches it, or sells its blueprint; the way to the first tools and
## the workbench needs no teacher.
func test_every_recipe_is_known_to_all_or_taught_or_sold_as_a_blueprint() -> void:
	var taught := {}
	for id: String in _content.defs:
		var d := _content.get_def(id)
		if d.get("kind") == "profession":
			for r: String in d.get("teaches", {}):
				taught[r] = true
			for r: String in (d.get("trade", {}) as Dictionary).get("blueprints", {}):
				taught[r] = true
	for id: String in _content.defs:
		var d := _content.get_def(id)
		if d.get("kind") == "recipe":
			check(bool(d.get("innate", false)) or taught.has(id), "%s: known to all, taught or sold as a blueprint" % id)
			check(_content.kind_of(String(d.get("skill", ""))) == "skill", "%s: of a skill" % id)
	for id: String in ["base:twist_cord", "base:make_flint_axe", "base:make_flint_pick", "base:saw_planks", "base:make_axe",
			"base:make_pickaxe", "base:make_hoe", "base:make_torches", "base:cook_meat"]:
		check(bool(_content.get_def(id).get("innate", false)), "%s: known to all from the start" % id)
	# With the recipes known to all: every station and the first tools.
	var innate := {}
	for id: String in _content.defs:
		if _content.kind_of(id) == "recipe" and bool(_content.get_def(id).get("innate", false)):
			innate[id] = true
	var r := _reach(innate)
	for station: String in ["workbench", "forge", "fire"]:
		check((r["stations"] as Dictionary).has(station), "a %s, untaught" % station)
	for item: String in ["base:axe", "base:pickaxe", "base:hoe", "base:spear", "base:bucket"]:
		check((r["items"] as Dictionary).has(item), "%s, untaught" % item)
