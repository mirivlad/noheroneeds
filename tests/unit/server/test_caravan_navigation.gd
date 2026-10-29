extends TestCase
## Whole scheduled caravans, beyond the original saved-world regression:
## leave the road round a new obstruction, rejoin it and deliver with guards.
var w: ServerWorld
var road: Dictionary

func before_each() -> void:
	w = ServerWorld.open(tmp_dir().path_join("world.db"), ContentRegistry.load_packs(["res://content/base"]), {"seed": 11})
	for cy in [4, 5, 6]:
		for cx in [4, 5, 6]:
			var chunk := w.chunk("surface", cx, cy)
			for id: String in w.creatures.in_chunk("surface", cx, cy):
				w.creatures.remove(id)
			for y in 32:
				for x in 32:
					chunk.set_cell("ground", x, y, "base:grass")
					for layer: String in ["cover", "structure", "roof"]:
						chunk.set_cell(layer, x, y, "")
	var s := w.generator.settlements
	var district := s._district_of(0, s.home_plan()["centre"])
	road = (s.roads_of(0, district.x, district.y)[0] as Dictionary).duplicate()
	var path: Array = []
	for x in range(164, 185):
		path.append(Vector2i(x, 170))
	# Repeated joint/end cells occur on real generated roads.
	for y in range(170, 186):
		path.append(Vector2i(184, y))
	path.append(path.back())
	road["path"] = path
	var key: Array = road["key"]
	s._roads["%d|%d|%d|%d" % [key[0], key[1], key[2], key[3]]] = road
	w.world_time = 12 * Daylight.HOUR_MS

func after_each() -> void:
	w.close()

func _journey(variant: String, off_road: bool) -> void:
	var trader := w.creatures._spawn("base:villager", "surface", Vector2i(164, 165 if off_road else 170), {}, 7)
	trader.pos += Vector2i(61, -37)
	trader.route = {"road": road["key"], "i": 0, "step": 1}
	trader.face = Vector2i.RIGHT
	trader.job = {"profession": "base:trader", "from": road["from"], "toward": road["to"], "purse": 600}
	w.creatures._make_caravan(trader, variant)
	w.caravans.hire(trader, 40)
	var guards := w.caravans.guards(trader).duplicate()
	var horse := w.creatures.get_creature(String(trader.job["horse"]))
	w.inventory("trade|" + trader.id).add("base:iron_sword", 2)
	var before := w.economy.have(String(road["to"]), "base:iron_sword")
	var left_road := off_road
	var collision := false
	for tick in 4000:
		if tick == 20 and not off_road:
			# A long new barrier requires more than the old eight-cell detour.
			for y in range(159, 182):
				var chunk := w.chunk("surface", 174 >> 5, y >> 5)
				chunk.set_cell("structure", 174 & 31, y & 31, "base:wood_wall")
		if tick == 100:
			# One of the desired guard formation spots is occupied too.
			w.chunk("surface", 182 >> 5, 188 >> 5).set_cell("cover", 182 & 31, 188 & 31, "base:oak")
		w.tick += 1
		for cy in [4, 5, 6]:
			for cx in [4, 5, 6]:
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
		var nearest := INF
		for at: Vector2i in road["path"]:
			nearest = minf(nearest, trader.cell().distance_to(at))
		left_road = left_road or nearest > 8
		for c: Creature in [trader, horse] + guards.map(func(id: String) -> Creature: return w.creatures.get_creature(id)):
			for at: Vector2i in BodySize.cells(c.pos, BodySize.of(w.content.get_def(c.kind))["half"]):
				collision = collision or w.is_solid("surface", at.x, at.y)
		if trader.job.get("from") == road["to"]:
			break
	check(trader.job.get("from") == road["to"], "%s arrives after an off-road detour: cell %s, target %s, state %s" % [variant, trader.cell(), trader.target, trader.state])
	check(left_road, "the caravan actually left the road")
	check(not collision, "trader, horse and guards never entered the obstacle")
	eq(w.economy.have(String(road["to"]), "base:iron_sword"), before + 2, "the real cargo was delivered")
	# Let the rear rank finish catching up after the lead reaches the village.
	w.creatures._schedule(trader, w.tick + 10000)
	w.creatures._movers.erase(trader.id)
	for tick in 150:
		w.tick += 1
		for cy in [4, 5, 6]:
			for cx in [4, 5, 6]:
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
	for id: String in guards:
		var guard := w.creatures.get_creature(id)
		check(guard.cell().distance_to(trader.cell()) <= 6, "every guard returns to its caravan: " + str(guard.cell()))

func test_cart_goes_off_road_around_a_new_barrier_with_its_guards() -> void:
	_journey("cart", false)

func test_pack_caravan_goes_off_road_around_a_new_barrier_with_its_guards() -> void:
	_journey("pack", false)

func test_cart_returns_from_off_road_and_delivers() -> void:
	_journey("cart", true)

func test_pack_caravan_returns_from_off_road_and_delivers() -> void:
	_journey("pack", true)
