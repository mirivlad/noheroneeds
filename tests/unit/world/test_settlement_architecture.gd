extends TestCase

var registry: ContentRegistry
var materials: Dictionary

func before_each() -> void:
	registry = ContentRegistry.load_packs(["res://content/base"])
	materials = registry.get_def("base:village")

func test_building_seed_and_real_footprint_are_stable() -> void:
	var template: Dictionary = materials["buildings"][0]
	var first := SettlementArchitecture.plan(431, "village-a", "house-7", template, "forest")
	SettlementArchitecture.plan(431, "village-a", "house-8", template, "forest")
	var again := SettlementArchitecture.plan(431, "village-a", "house-7", template, "forest")
	eq(first, again, "another building does not change the seed or architecture")
	check(first["seed"] != SettlementArchitecture.plan(431, "village-b", "house-7", template, "forest")["seed"], "the village participates in the seed")
	var origin := Vector2i(17, -6)
	var cells := SettlementArchitecture.cells(first, origin, "village-a", materials, registry)
	var yard: Rect2i = first["yard"]
	eq(cells.size(), (first["occupied"] as Dictionary).size() + (int(first["porch_width"]) if first["porch"] else 0) + yard.get_area(), "only the real footprint, yard and entrance canopy are materialized")
	eq(cells[first["door"] + origin]["structure"], "base:wood_door", "the door belongs to the actual outline")

func test_shapes_have_connected_interiors_and_accessible_furniture() -> void:
	var seen := {}
	var template: Dictionary = materials["buildings"][1]
	for index in 48:
		var design := SettlementArchitecture.plan(17, "village", "house-%d" % index, template, "dry" if index % 2 else "forest")
		seen[design["shape"]] = true
		var cells := SettlementArchitecture.cells(design, Vector2i.ZERO, "village", materials, registry)
		var door: Vector2i = design["door"]
		var reached := {door: true}
		var queue: Array[Vector2i] = [door]
		var head := 0
		while head < queue.size():
			var at := queue[head]
			head += 1
			for direction: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				var next := at + direction
				if reached.has(next) or not cells.has(next):
					continue
				var part := String(cells[next]["structure"])
				if part != "" and registry.get_def(part).get("solid", true):
					continue
				reached[next] = true
				queue.append(next)
		for furniture: Dictionary in design["furniture"]:
			var at: Vector2i = furniture["cell"]
			check(reached.has(at + Vector2i.DOWN), "house %d: furniture has a reachable approach" % index)
		for at: Vector2i in cells:
			if cells[at].has("roof") and String(cells[at]["structure"]) == "":
				check(reached.has(at), "house %d: every empty indoor cell is reachable" % index)
	check(seen.size() >= 5, "several structural types, rather than colour variants")

func test_local_traditions_control_construction_parameters() -> void:
	var template: Dictionary = materials["buildings"][0]
	for index in 12:
		var cold := SettlementArchitecture.plan(4, "village", str(index), template, "cold")
		var dry := SettlementArchitecture.plan(4, "village", str(index), template, "dry")
		check(float(cold["pitch"]) > float(dry["pitch"]), "cold roofs have steeper slopes")
		check((cold["windows"] as Dictionary).size() <= (cold["occupied"] as Dictionary).size(), "windows belong to the footprint")
		check(cold["shape"] in ["cottage", "wing"], "cold houses remain compact")

func test_upper_floors_have_real_landings_and_a_single_opening() -> void:
	var seen := {}
	for index in 48:
		var design := SettlementArchitecture.plan(17, "village", "house-%d" % index, materials["buildings"][1], "forest")
		var origin := Vector2i(-15, 31)
		var lower := SettlementArchitecture.cells(design, origin, "village", materials, registry)
		var upper := SettlementArchitecture.upper_cells(design, origin, "village", materials, registry)
		if upper.is_empty():
			continue
		seen[design["attic"]] = true
		var stair := SettlementArchitecture._stairs(design) + origin
		var landing := stair + Vector2i.UP
		eq(lower[stair]["structure"], "base:wood_stairs")
		check(not lower[stair].has("ceiling"), "a real opening above the stairs")
		eq(upper[stair]["ground"], "")
		check(upper[stair]["props"]["stairs_down"], "a way back down")
		eq(lower[landing]["props"]["ceiling"]["building"], "village|" + design["id"])
		check(upper[landing]["ground"] != "" and upper[landing]["structure"] == "", "the landing is free")
		for at: Vector2i in upper:
			if at != stair:
				eq(lower[at].get("ceiling"), "base:wood_ceiling", "floor is supported by a real ceiling")
	check(seen.has(true) and seen.has(false), "both habitable attics and full upper floors")

func test_yard_gate_is_reachable_and_obeys_the_door_orientation_rule() -> void:
	for index in 24:
		var design := SettlementArchitecture.plan(431, "village", str(index), materials["buildings"][0], "forest")
		var yard: Rect2i = design["yard"]
		if not yard.has_area():
			continue
		var cells := SettlementArchitecture.cells(design, Vector2i.ZERO, "village", materials, registry)
		var gates := 0
		for at: Vector2i in cells:
			if cells[at].get("structure", "") != "base:wood_gate":
				continue
			gates += 1
			check(not cells.has(at + Vector2i.UP), "the rear gate opens to the clear rear approach")
			eq(cells[at + Vector2i.DOWN]["structure"], "", "the gate opens into a clear yard cell")
			for step: Vector2i in [Vector2i.UP, Vector2i.DOWN]:
				var role := String(registry.get_def(String(cells.get(at + step, {}).get("structure", ""))).get("role", ""))
				check(role not in ["wall", "window", "fence", "column", "door"], "the gate can be rebuilt under the shared door rules")
		eq(gates, 1, "one clear entrance into the fenced yard")
