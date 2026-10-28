extends TestCase
## Dwellers walk at their own pace to the fire and to bed (no rushing).

var w: ServerWorld
var plan: Dictionary


func before_each() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	w = ServerWorld.open(tmp_dir().path_join("world.db"), content, {"seed": 12345})
	plan = w.generator.settlements.home_plan()
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
		for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
			w.chunk("surface", cx, cy)


func after_each() -> void:
	w.close()


func test_to_bed_at_a_walk() -> void:
	w.world_time = Daylight.DAY_MS + int(20.9 * Daylight.HOUR_MS)
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	var last := {}
	var fastest := 0
	for i in 2400:
		w.tick += 1
		w.advance_time()
		for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
			for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
		for c: Creature in w.creatures.creatures.values():
			if String(c.job.get("village", "")) != String(plan["id"]):
				continue
			if last.has(c.id) and i > 200:  # (settled first: loaded, they are put where their day has them)
				var d := maxi(absi(c.pos.x - (last[c.id] as Vector2i).x), absi(c.pos.y - (last[c.id] as Vector2i).y))
				fastest = maxi(fastest, d)
			last[c.id] = c.pos
	check(fastest <= int(1.3 * Movement.WALK) + 2, "no faster than a run a tick: %d" % fastest)


func test_at_the_fire_they_look_into_it() -> void:
	w.world_time = Daylight.DAY_MS + int(19.5 * Daylight.HOUR_MS)
	var r: Rect2i = (plan["bounds"] as Rect2i).grow(80)
	for i in 900:
		w.tick += 1
		w.advance_time()
		for cy in range(floori(r.position.y / 32.0), floori(r.end.y / 32.0) + 1):
			for cx in range(floori(r.position.x / 32.0), floori(r.end.x / 32.0) + 1):
				w.mark_needed("surface", cx, cy)
		w.creatures.step(w.tick)
	var fire: Vector2i = plan["fire"]
	var by_fire := 0
	for c: Creature in w.creatures.creatures.values():
		if String(c.job.get("village", "")) != String(plan["id"]) or Vector2(c.cell()).distance_to(Vector2(fire)) > 4.0:
			continue
		by_fire += 1
		var toward := fire - c.cell()
		check(c.face == Vector2i(signi(toward.x), signi(toward.y)), "%s looks into the fire: %s, the fire %s" % [c.id.substr(0, 6), c.face, toward])
	check(by_fire > 0, "some at the fire in the evening")


## Each its own day: at bedtime some already lie down, some still sit by the
## fire; each keeps its own hours from day to day.
func test_each_its_own_day() -> void:
	var ours := w.creatures.creatures.values().filter(func(c: Creature) -> bool:
		return String(c.job.get("village", "")) == String(plan["id"]))
	check(ours.size() >= 3, "a village of dwellers")
	var seen := {}
	for minutes in range(0, 150, 10):
		w.world_time = Daylight.DAY_MS + int((20.0 + minutes / 60.0) * Daylight.HOUR_MS)
		var phases := {}
		for c: Creature in ours:
			phases[w.creatures._phase(c)] = true
		if phases.has("evening") and phases.has("night"):
			seen["both"] = true
	check(seen.has("both"), "some to bed while others stay up")
	var c: Creature = ours[0]
	w.world_time = Daylight.DAY_MS + int(21.0 * Daylight.HOUR_MS)
	var first := w.creatures._phase(c)
	w.world_time += 3 * Daylight.DAY_MS
	eq(w.creatures._phase(c), first, "the same hours every day")
	eq(w.creatures._phase(c), w.creatures._phase(c), "and the same each time asked")
