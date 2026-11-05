extends TestCase

var content: ContentRegistry
var materials: Dictionary
var plans: Settlements

func before_each() -> void:
	content = ContentRegistry.load_packs(["res://content/base"])
	materials = content.get_def("base:village").duplicate(true)
	plans = Settlements.new(431, content, func(_x: int, _y: int) -> bool: return false, 8)

func test_all_six_street_patterns_have_real_rotated_accessible_houses() -> void:
	var chosen := []
	for index in 12:
		var template: Dictionary = materials["buildings"][index % materials["buildings"].size()].duplicate(true)
		template["architecture"] = SettlementArchitecture.plan(431, "test", str(index), template, "forest")
		chosen.append(template)
	for kind: String in ["road", "square", "crossroads", "bend", "shore", "terraces"]:
		var layout := SettlementLayout.make(chosen, kind, 431, Callable(), Vector2i.ZERO)
		layout.merge({"fields": [], "pen": {}, "layout": kind, "environment": {}, "scale": "village", "fire": layout["square"].position + Vector2i(1, 2)})
		var p := plans._place(layout, Vector2i(500, 500), "test", materials)
		check(p["homes"].size() >= 8, "%s has room for its residents" % kind)
		var seen := {}
		var cells: Dictionary = p["cells"]
		var start: Vector2i = p["centre"] + Vector2i(0, 1)
		var reached := {start: true}
		var queue: Array[Vector2i] = [start]
		var head := 0
		while head < queue.size():
			var at := queue[head]
			head += 1
			for offset: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				var next := at + offset
				if reached.has(next) or not cells.has(next): continue
				var part := String(cells[next].get("structure", ""))
				if part != "" and content.get_def(part).get("role") != "door" and content.get_def(part).get("solid", true): continue
				reached[next] = true
				queue.append(next)
		for home: Dictionary in p["homes"]:
			var direction := SettlementArchitecture.facing(home["architecture"])
			seen[direction] = true
			var door: Vector2i = home["door"]
			eq(cells[door]["structure"], "base:wood_door", "the actual doorway moves")
			check(reached.has(door), "%s: every entrance joins the street network" % kind)
			check(reached.has(home["bed"]), "%s: a resident can reach their bed" % kind)
			check((home["rect"] as Rect2i).has_point(home["bed"]), "bed coordinates rotated with the house")
		check(seen.size() >= 2, "%s uses both sides of streets" % kind)
		if kind in ["square", "crossroads", "bend", "terraces"]:
			check(seen.size() >= 3, "%s has more than one axis of entrances" % kind)

func test_local_capacity_and_connections_change_scale_without_erasing_variation() -> void:
	for id: String in ["a", "b", "c", "d"]:
		materials["environment"] = {"capacity": .05, "access": .05}
		var poor := plans._layout(0, 2, 32, materials, id)
		materials["environment"] = {"capacity": 1.0, "access": 1.0}
		var rich := plans._layout(0, 2, 32, materials, id)
		eq(poor["scale"], "hamlet", "scarce resources and isolation constrain the initial settlement")
		eq(rich["scale"], "trading_town", "resources and trade access support a larger settlement")
		check(rich["buildings"].size() > poor["buildings"].size(), "scale affects real buildings")

func test_cached_street_patterns_still_check_each_real_parcel() -> void:
	materials["environment"] = {"capacity": .6, "access": .6}
	materials["site_centre"] = Vector2i(500, 500)
	var first_key := plans._layout_key(materials, "cached")
	var layout := plans._layout(0, 2, 32, materials, "cached")
	materials["site_centre"] = Vector2i(700, 500)
	eq(plans._layout_key(materials, "cached"), first_key, "moving a normal pattern does not redo architecture")
	plans._land = func(x: int, _y: int) -> Dictionary: return {"what": "land" if x >= 0 else "water", "height": .08}
	check(plans._dry(plans._site(layout, Vector2i(500, 500))), "the actual dry parcel is accepted")
	check(not plans._dry(plans._site(layout, Vector2i.ZERO)), "a cached pattern cannot put houses in water")

func test_shared_initial_plans_are_private_copies_and_content_sensitive() -> void:
	var first := SurfaceGenerator.new(431, content)
	var original := first.settlements.home_plan().duplicate(true)
	var at: Vector2i = original["homes"][0]["door"]
	first.settlements.home_plan()["cells"][at]["ground"] = "base:sand"
	first.settlements.home_plan()["homes"][0]["architecture"]["furniture"].clear()
	var second := SurfaceGenerator.new(431, ContentRegistry.load_packs(["res://content/base"]))
	eq(second.settlements.home_plan(), original, "a caller's mutable plan never contaminates another world or the client")
	eq(first.settlements._shared_key, second.settlements._shared_key, "identical content and geography can reuse the expensive initial plan")
	var changed := ContentRegistry.load_packs(["res://content/base"])
	changed.defs["base:village"]["houses"] = [8, 9]
	var different := SurfaceGenerator.new(431, changed)
	check(different.settlements._shared_key != first.settlements._shared_key, "changed content cannot reuse an old world's initial plan")
	var custom := Settlements.new(431, content, func(_x: int, _y: int) -> bool: return true, 8)
	eq(custom._shared_key, "", "custom terrain callbacks never share another world's plans")
	var plan := WorldPlan.generate(431, "single_continent", "temperate", content)
	var altered := WorldPlan.from_dict(plan.to_dict())
	altered.fields[0] = int(altered.fields[0]) ^ 1
	var planned := SurfaceGenerator.new(431, content, plan)
	var edited := SurfaceGenerator.new(431, content, altered)
	check(planned.settlements._shared_key != first.settlements._shared_key, "a saved geographic plan is distinct from legacy geography with the same seed")
	check(planned.settlements._shared_key != edited.settlements._shared_key, "the full saved geography, not just its seed, identifies the cached plan")

func test_an_incomplete_layout_cannot_be_accepted_as_a_settlement() -> void:
	materials["way"] = "mining"
	materials["environment"] = {"capacity": .6, "access": .6}
	plans._land = func(_x: int, _y: int) -> Dictionary: return {"what": "water", "height": .08}
	var layout := plans._layout(0, 2, 32, materials, "no-parcels")
	check(layout["buildings"].is_empty(), "none of the requested houses fit this terrain")
	plans._land = func(_x: int, _y: int) -> Dictionary: return {"what": "land", "height": .08}
	check(not plans._dry(plans._site(layout, Vector2i(500, 500))), "even dry public ground cannot turn an incomplete blueprint into a valid settlement")
