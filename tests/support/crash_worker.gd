extends SceneTree
## Endless operation load for the crash test. Prints "ACK actor request_id ok|fail"
## as soon as the world releases an acknowledgement; never stops on its own.
## Args after "--": --db=path --round=n --seed=n

const COSTS := {"base:wood_wall": {"base:plank": 3}, "base:stone_wall": {"base:stone": 2, "base:plank": 1}}
const ACTORS := ["a", "b", "c", "d", "e", "f"]


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var store := WorldStore.new()
	if not store.open(args["db"]):
		printerr(store.last_error)
		quit(2)
		return
	var w := ServerWorld.new(store)
	w.part_costs = COSTS
	if store.read_meta("crash_test_seeded") == "":
		for a: String in ACTORS:
			w.grant(a, "base:plank", 60)
			w.grant(a, "base:stone", 30)
		w.flush_operations()
		store.write_meta("crash_test_seeded", "1")
	print("READY")
	var rng := RandomNumberGenerator.new()
	rng.seed = int(args.get("seed", "1"))
	var i := 0
	while true:
		var a: String = ACTORS[rng.randi() % ACTORS.size()]
		var x := rng.randi_range(-4, 3)
		var y := rng.randi_range(-4, 3)
		var rid := "%s-%d" % [args["round"], i]
		var roll := rng.randf()
		if roll < 0.45:
			w.handle(a, {"request_id": rid, "type": "build", "location": "surface", "x": x, "y": y,
				"part": ["base:wood_wall", "base:stone_wall"][rng.randi() % 2]})
		elif roll < 0.75:
			w.handle(a, {"request_id": rid, "type": "dismantle", "location": "surface", "x": x, "y": y})
		else:
			w.handle(a, {"request_id": rid, "type": "transfer", "to": ACTORS[rng.randi() % ACTORS.size()],
				"item": ["base:plank", "base:stone"][rng.randi() % 2], "count": rng.randi_range(1, 6)})
		i += 1
		# Like a server tick: commit every few requests, but send whatever
		# acknowledgements are ready after every request.
		if i % 10 == 0 and not w.flush_operations():
			printerr(store.last_error)
			quit(3)
			return
		for ack: Array in w.take_acks():
			print("ACK %s %s %s" % [ack[0], ack[1], "ok" if ack[2]["ok"] else "fail"])
