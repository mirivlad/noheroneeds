extends TestCase
## The harness moves like a cart and horse, not like one rigid sprite: the
## horse leads into a turn, the cart follows its own line and turns no faster
## than a cart can, the bend between them stays within what the shafts allow,
## and the horse keeps its place ahead. The server works the headings out;
## the client only eases them.

var w: ServerWorld
var trader: Creature
var horse: Creature
var _db := ""
var _content: ContentRegistry

const START := Vector2i(165, 170)


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			w.chunk("surface", 5 + dx, 5 + dy)
	var c := w.chunk("surface", 5, 5)
	for id: String in w.creatures.in_chunk("surface", 5, 5):
		w.creatures.creatures.erase(id)
	w.creatures._by_chunk.erase(ServerWorld.chunk_key("surface", 5, 5))
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass")
			for layer: String in ["cover", "structure", "roof"]:
				c.set_cell(layer, x, y, "")


func after_each() -> void:
	w.close()


func _caravan(at := START, face := Vector2i.RIGHT) -> void:
	trader = w.creatures._spawn("base:villager", "surface", at, {}, 7)
	trader.face = face
	trader.job = {"profession": "base:trader", "purse": 200}
	w.creatures._make_caravan(trader, "cart")
	horse = w.creatures.get_creature(String(trader.job["horse"]))


func _tick(n := 1) -> void:
	for i in n:
		w.creatures._move(trader)


func _heading(key: String) -> Vector2:
	var saved: Array = trader.job.get(key, [0, 1])
	return Vector2(float(saved[0]), float(saved[1])).normalized()


func _apart(a: Vector2, b: Vector2) -> float:
	return absf(wrapf(a.angle() - b.angle(), -PI, PI))


func _walk(goal: Vector2i) -> void:
	w.creatures._go(trader, "travel", goal, false)


func test_a_straight_way_keeps_the_horse_ahead_and_turns_at_a_cart_pace() -> void:
	_caravan(START, Vector2i.DOWN)  # it stands facing south, the road goes east
	_walk(START + Vector2i(14, 0))
	var last_cart := _heading("caravan_heading")
	var last_horse := _heading("horse_heading")
	var most_cart := 0.0
	var most_horse := 0.0
	var worst_bend := 0.0
	for i in 80:
		_tick()
		var cart := _heading("caravan_heading")
		var led := _heading("horse_heading")
		most_cart = maxf(most_cart, _apart(last_cart, cart))
		most_horse = maxf(most_horse, _apart(last_horse, led))
		worst_bend = maxf(worst_bend, _apart(cart, led))
		check(_apart(cart, led) <= CreatureSim.HITCH_ANGLE + 0.01, "the shafts' bend stays possible at tick %d" % i)
		check(horse.pos.distance_to(trader.pos) <= roundi(CreatureSim.CARAVAN_HORSE_DISTANCE * Movement.UNIT) + 2
			and horse.pos.distance_to(trader.pos) >= roundi(CreatureSim.CARAVAN_HORSE_DISTANCE * Movement.UNIT) - 2,
			"the horse stays in the shafts at tick %d" % i)
		last_cart = cart
		last_horse = led
	check(most_cart > 0.0, "the cart did turn from the direction it stood in")
	check(most_cart <= CreatureSim.CART_TURN + 0.01, "the cart never snaps round: %.3f rad in a tick" % most_cart)
	check(most_horse <= CreatureSim.HORSE_TURN + 0.01, "the horse turns no faster than it can: %.3f rad" % most_horse)
	check(_apart(_heading("caravan_heading"), Vector2.RIGHT) < 0.02, "on a straight road the cart heads along it")
	check(worst_bend <= CreatureSim.HITCH_ANGLE + 0.01, "the harness never bends past the shafts")


func test_the_horse_goes_first_into_a_ninety_degree_turn() -> void:
	_caravan()
	_walk(START + Vector2i(10, 0))
	_tick(45)
	check(_apart(_heading("caravan_heading"), Vector2.RIGHT) < 0.05, "the cart is going along the road")
	# Straight down from where it stands now, so the turn is a true right angle.
	_walk(trader.cell() + Vector2i(0, 10))
	var horse_turn := -1
	var cart_turn := -1
	var most_cart := 0.0
	var last_cart := _heading("caravan_heading")
	for i in 40:
		_tick()
		var cart := _heading("caravan_heading")
		var led := _heading("horse_heading")
		most_cart = maxf(most_cart, _apart(last_cart, cart))
		check(_apart(cart, led) <= CreatureSim.HITCH_ANGLE + 0.01, "the bend stays possible at tick %d" % i)
		if horse_turn < 0 and _apart(led, Vector2.DOWN) < 0.05:
			horse_turn = i
		if cart_turn < 0 and _apart(cart, Vector2.DOWN) < 0.05:
			cart_turn = i
		last_cart = cart
	check(horse_turn >= 0 and cart_turn >= 0, "both come round to the new road")
	check(horse_turn < cart_turn, "the horse is first into the turn: horse %d, cart %d" % [horse_turn, cart_turn])
	check(most_cart <= CreatureSim.CART_TURN + 0.01, "the cart turns at its own pace, not in a step")
	# The headings are saved with the trader, not guessed again on a restart.
	var loaded := Creature.from_data(trader.id, trader.location, trader.to_data())
	eq(loaded.job.get("caravan_heading"), trader.job.get("caravan_heading"), "the cart's heading is saved")
	eq(loaded.job.get("horse_heading"), trader.job.get("horse_heading"), "the horse's heading is saved")


func test_a_run_of_turns_is_smooth_and_the_harness_keeps_together() -> void:
	_caravan()
	_walk(START + Vector2i(10, 0))
	_tick(45)
	var most_cart := 0.0
	var worst_bend := 0.0
	for leg: Vector2i in [Vector2i(0, 8), Vector2i(8, 0), Vector2i(0, -8)]:
		_walk(trader.cell() + leg)
		var last := _heading("caravan_heading")
		for i in 55:
			_tick()
			var cart := _heading("caravan_heading")
			var led := _heading("horse_heading")
			most_cart = maxf(most_cart, _apart(last, cart))
			worst_bend = maxf(worst_bend, _apart(cart, led))
			last = cart
	check(most_cart <= CreatureSim.CART_TURN + 0.01, "no turn of the run snaps round")
	check(worst_bend <= CreatureSim.HITCH_ANGLE + 0.01, "the shafts stay whole through every turn")
	check(trader.cell().distance_to(START + Vector2i(10, 0)) <= 1, "it still gets where it was going")


func test_a_cart_goes_down_a_narrow_passage_without_touching_the_walls() -> void:
	_caravan()
	for x in range(160, 190):
		for y in [168, 172]:
			w.chunk("surface", 5, 5).set_cell("structure", x & 31, y & 31, "base:wood_wall")
	_walk(START + Vector2i(18, 0))
	var collision := false
	var worst_bend := 0.0
	for i in 200:
		_tick()
		var cart := _heading("caravan_heading")
		worst_bend = maxf(worst_bend, _apart(cart, _heading("horse_heading")))
		for c: Creature in [trader, horse]:
			for at: Vector2i in BodySize.cells(c.pos, BodySize.of(_content.get_def(c.kind))["half"]):
				collision = collision or w.is_solid("surface", at.x, at.y)
		# The cart's own rotated body, not just its centre.
		var forward := cart
		var side := Vector2(-forward.y, forward.x)
		var at := Vector2(trader.pos) / Movement.UNIT
		for a in [-1.0, 1.0]:
			for b in [-1.0, 1.0]:
				var corner: Vector2 = at + forward * (0.95 * a) + side * (0.70 * b)
				collision = collision or w.is_solid("surface", floori(corner.x), floori(corner.y))
	check(not collision, "neither the cart nor the horse touched a wall")
	check(worst_bend <= CreatureSim.HITCH_ANGLE + 0.01, "the harness stayed whole in the passage")
	check(trader.cell().distance_to(START + Vector2i(18, 0)) <= 1, "and it came out the other end")