extends TestCase
## Chunks leave memory only when nothing about them is on its way to the disk,
## so loading them back gives exactly what was there.

var w: ServerWorld


func before_each() -> void:
	w = ServerWorld.open(tmp_dir().path_join("world.db"), ContentRegistry.load_packs(["res://content/base"]), {"seed": 2})


func after_each() -> void:
	w.close()


func _req(actor: String, r: Dictionary) -> void:
	r["request_id"] = Uuid.v4()
	w.handle(actor, r)


func _arrive(name: String, cell: Vector2i) -> String:
	var c := PortableCharacter.create(name, "base:humanoid_adult")
	w.enter("key-" + name, c)
	w.move_character(c.character_id, cell * Movement.UNIT + Vector2i(128, 128))
	return c.character_id


func test_waits_for_the_disk_then_unloads_and_reloads_the_same() -> void:
	var a := _arrive("a", Vector2i(1, 1))
	w.grant(a, "base:plank", 3)
	w.grant(a, "base:stone", 2)
	_req(a, {"type": "build", "location": "surface", "x": 3, "y": 1, "part": "base:wood_wall"})
	_req(a, {"type": "drop", "item": "base:stone", "count": 2})
	w.mark_needed("surface", 0, 0)
	w.commit_async(true)  # handed to the writer; the world has not seen it committed
	w.move_character(a, Vector2i(5000, 5000) * Movement.UNIT)  # walks far away
	w.tick += 100
	w.unload_idle(10)
	check(w.has_chunk("surface", 0, 0), "kept while its batch is not known to be on disk")
	w.sync()
	w.tick += 100
	check(w.unload_idle(10) > 0, "unloaded once committed")
	check(not w.has_chunk("surface", 0, 0), "gone from memory")
	eq(w.items.size(), 0, "its things left memory with it")
	eq(w.chunk("surface", 0, 0).get_cell("structure", 3, 1), "base:wood_wall", "the wall comes back")
	eq(w.items.size(), 1, "the stones come back, once")


func test_picked_up_things_do_not_come_back() -> void:
	var a := _arrive("a", Vector2i(1, 1))
	w.grant(a, "base:stone", 1)
	_req(a, {"type": "drop", "item": "base:stone", "count": 1})
	w.sync()
	w.take_acks()
	var id: String = w.items.keys()[0]
	_req(a, {"type": "pickup", "entity": id})
	w.commit_async(true)
	w.move_character(a, Vector2i(5000, 5000) * Movement.UNIT)
	w.tick += 100
	w.sync()
	w.tick += 100
	w.unload_idle(10)
	check(not w.has_chunk("surface", 0, 0), "unloaded")
	w.chunk("surface", 0, 0)
	eq(w.items.size(), 0, "the picked-up stone does not lie there again")
	eq(w.inventory(a).count("base:stone"), 1)


func test_needed_chunks_stay() -> void:
	var a := _arrive("a", Vector2i(1, 1))
	w.chunk("surface", 0, 0)
	w.chunk("surface", 40, 40)
	w.mark_needed("surface", 0, 0)
	w.tick += 5
	w.unload_idle(100)
	check(w.has_chunk("surface", 0, 0), "recently needed")
	w.sync()
	w.tick += 200
	w.mark_needed("surface", 0, 0)
	w.unload_idle(100)
	check(w.has_chunk("surface", 0, 0), "needed again")
	check(not w.has_chunk("surface", 40, 40), "nobody needed it")
	eq(a != "", true)
