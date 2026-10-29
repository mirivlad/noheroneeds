extends TestCase
## ADR-0018: living creatures on the server: populated once, saved, honest
## senses, memory, behaviour, a bounded cost, catching up after time away.

var w: ServerWorld
var _db := ""
var _content: ContentRegistry


func before_each() -> void:
	_content = ContentRegistry.load_packs(["res://content/base"])
	_db = tmp_dir().path_join("world.db")
	w = ServerWorld.open(_db, _content, {"seed": 11})


func after_each() -> void:
	w.close()


## A clear field to test in: no plants, no water, nobody else around.
func _field(cx := 5, cy := 5) -> void:
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			w.chunk("surface", cx + dx, cy + dy)  # around it loaded, as around a player
	var c := w.chunk("surface", cx, cy)
	for id: String in w.creatures.in_chunk("surface", cx, cy):
		w.creatures.creatures.erase(id)
	w.creatures._by_chunk.erase(ServerWorld.chunk_key("surface", cx, cy))
	for y in Chunk.SIZE:
		for x in Chunk.SIZE:
			c.set_cell("ground", x, y, "base:grass")
			c.set_cell("cover", x, y, "")


func _at(cell: Vector2i) -> Vector2i:
	return cell * Movement.UNIT + Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)


func _clear_caravan_border() -> void:
	for y in range(167, 174):
		for x in range(187, 198):
			var chunk := w.chunk("surface", x >> 5, y >> 5)
			chunk.set_cell("ground", x & 31, y & 31, "base:grass")
			chunk.set_cell("cover", x & 31, y & 31, "")
			chunk.set_cell("structure", x & 31, y & 31, "")


func _spawn(kind: String, cell: Vector2i) -> Creature:
	return w.creatures._spawn(kind, "surface", cell, {}, 7)


func _player(cell: Vector2i) -> String:
	var c := PortableCharacter.create("Аня", "base:human_m")
	c.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	w.enter("k-" + c.character_id, c)
	w.move_character(c.character_id, _at(cell))
	return c.character_id


## Players near: the chunks around `cell` are needed (as GameServer marks them).
func _near(cell: Vector2i) -> void:
	var cx := floori(cell.x / 32.0)
	var cy := floori(cell.y / 32.0)
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			w.mark_needed("surface", cx + dx, cy + dy)


func _ticks(n: int, keep_near := Vector2i(1 << 20, 0)) -> void:
	for i in n:
		w.tick += 1
		w.advance_time()
		if keep_near.x != 1 << 20:
			_near(keep_near)
		w.creatures.step(w.tick)


func test_chunks_get_their_animals_once_and_villagers_come() -> void:
	var animals := 0
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			w.chunk("surface", cx, cy)
	# Villages lie closer now (ADR-0038): more than the spawn's may fall in
	# the chunks made — a dweller for every home in them.
	var made := Rect2i(-3 * 32, -3 * 32, 7 * 32, 7 * 32)
	var homes := []
	for p: Dictionary in w.generator.settlements.plans_near(Vector2i.ZERO, 400):
		for h: Dictionary in p["homes"]:
			if h["bed"] != Settlements.NONE and made.has_point(h["bed"]):
				homes.append(h)
	var villagers := w.creatures.creatures.values().filter(func(c: Creature) -> bool: return c.kind == "base:villager" and not c.job.is_empty())
	eq(villagers.size(), homes.size(), "a dweller a home in the villages made")
	check(not (villagers[0] as Creature).looks.is_empty(), "with looks of their own")
	for c: Creature in w.creatures.creatures.values():
		animals += 1 if c.kind != "base:villager" and c.owner == "" else 0
	check(animals > 10, "animals across 49 chunks: %d" % animals)
	var count := w.creatures.creatures.size()
	var kinds := {}
	for c: Creature in w.creatures.creatures.values():
		kinds[c.kind + str(c.home)] = true
	w.close()
	w = ServerWorld.open(_db, _content)
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			w.chunk("surface", cx, cy)
	eq(w.creatures.creatures.size(), count, "the same creatures, no second population")
	var other := ServerWorld.open(tmp_dir().path_join("other.db"), _content, {"seed": 11})
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			other.chunk("surface", cx, cy)
	var same := true
	for c: Creature in other.creatures.creatures.values():
		same = same and kinds.has(c.kind + str(c.home))
	check(same, "the same seed, the same animals in the same places")
	other.close()


func test_creatures_are_kept_across_a_restart() -> void:
	_field()
	var hare := _spawn("base:hare", Vector2i(170, 170))
	hare.pos = _at(Vector2i(172, 171))
	hare.state = "graze"
	hare.memory["someone"] = {"pos": Vector2i(160, 160), "time": w.world_time, "what": "character"}
	hare.changed()
	var id := hare.id
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	var back := w.creatures.get_creature(id)
	check(back != null, "it is back")
	eq(back.pos, _at(Vector2i(172, 171)), "where it was")
	eq(back.home, Vector2i(170, 170))
	eq(back.memory["someone"]["pos"], Vector2i(160, 160), "with what it remembers")


func test_caravan_horse_and_goods_survive_restart_and_move_together() -> void:
	_field()
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.route = {"road": [0, 0, 0, 0], "i": 1, "step": 1}
	w.creatures._make_caravan(trader, "cart")
	var horse_id := String(trader.job["horse"])
	var horse := w.creatures.get_creature(horse_id)
	check(horse != null and horse.kind == "base:horse", "the trader has a real horse")
	eq(horse.job.get("caravan_driver"), trader.id, "both ends of the harness agree")
	var stock := w.inventory("trade|" + trader.id)
	stock.add("base:plank", 3)
	w.touch_inventory("trade|" + trader.id)
	w.creatures._go(trader, "travel", Vector2i(175, 170), false)
	for i in 10:
		w.creatures._move(trader)
	check(trader.pos != _at(Vector2i(170, 170)), "the trader moved")
	eq(horse.pos, trader.pos + Vector2i(roundi(CreatureSim.CARAVAN_HORSE_DISTANCE * Movement.UNIT), 0), "the horse follows ahead of the wagon")
	var trader_id := trader.id
	var pos := horse.pos
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	trader = w.creatures.get_creature(trader_id)
	horse = w.creatures.get_creature(horse_id)
	check(trader != null and horse != null, "both are restored")
	eq(trader.job.get("horse"), horse_id)
	eq(horse.job.get("caravan_driver"), trader_id)
	eq(horse.pos, pos)
	eq(int(w.inventory("trade|" + trader_id).stacks.get("base:plank", 0)), 3, "the same cargo is restored")
	w.creatures._make_caravan(trader, "cart")
	eq(trader.job.get("horse"), horse_id, "loading does not create another horse")
	w.creatures.remove(horse_id)
	eq(trader.job.get("horse"), "", "a lost horse unharnesses the trader")
	w.creatures._make_caravan(trader, "cart")
	eq(trader.job.get("horse"), "", "a lost horse is not replaced silently")


func test_pack_horse_carries_goods_behind_a_walking_trader() -> void:
	_field()
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.face = Vector2i.RIGHT
	w.creatures._make_caravan(trader, "pack")
	var horse_id := String(trader.job["horse"])
	var horse := w.creatures.get_creature(horse_id)
	eq(trader.job.get("caravan_type"), "pack")
	check(bool(horse.job.get("pack", false)), "the horse has panniers")
	w.inventory("trade|" + trader.id).add("base:plank", 4)
	w.touch_inventory("trade|" + trader.id)
	w.creatures._go(trader, "travel", Vector2i(175, 170), false)
	for i in 10:
		w.creatures._move(trader)
	eq(horse.pos, trader.pos - Vector2i(roundi(CreatureSim.PACK_HORSE_DISTANCE * Movement.UNIT), 0), "the laden horse follows behind")
	var trader_id := trader.id
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	trader = w.creatures.get_creature(trader_id)
	horse = w.creatures.get_creature(horse_id)
	eq(trader.job.get("caravan_type"), "pack", "the variant survives restart")
	check(bool(horse.job.get("pack", false)), "the same horse still has its panniers")
	eq(w.inventory("trade|" + trader_id).count("base:plank"), 4, "the same cargo survives restart")


func test_caravan_waits_for_its_horse_across_a_chunk_boundary() -> void:
	_field()
	_clear_caravan_border()
	var trader := _spawn("base:villager", Vector2i(190, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.route = {"road": [], "i": 1, "step": 1}
	w.creatures._make_caravan(trader, "cart")
	var trader_id := trader.id
	var horse_id := String(trader.job["horse"])
	w.creatures._go(trader, "travel", Vector2i(196, 170), false)
	for i in 10:
		w.creatures._move(trader)
	var horse := w.creatures.get_creature(horse_id)
	eq(trader.cell().x >> 5, 5, "wagon is in the first chunk")
	eq(horse.cell().x >> 5, 6, "horse is in the next chunk")
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	trader = w.creatures.get_creature(trader_id)
	check(trader != null and w.creatures.get_creature(horse_id) == null, "only the wagon's chunk is loaded")
	var position_before := trader.pos
	w.creatures._catch_up(trader, _content.get_def(trader.kind))
	eq(trader.pos, position_before, "catching up does not teleport the wagon away from its horse")
	w.creatures._traveller(trader, _content.get_def(trader.kind))
	eq(trader.target, Creature.NO_TARGET, "the wagon waits instead of leaving its horse")
	eq(trader.job.get("horse"), horse_id, "waiting does not create a replacement")
	w.chunk("surface", 6, 5)
	horse = w.creatures.get_creature(horse_id)
	check(horse != null, "the same horse returns with its own chunk")
	eq(horse.job.get("caravan_driver"), trader_id)


func test_caravan_remembers_horse_lost_while_driver_chunk_is_unloaded() -> void:
	_field()
	_clear_caravan_border()
	var trader := _spawn("base:villager", Vector2i(190, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.route = {"road": [], "i": 1, "step": 1}
	w.creatures._make_caravan(trader, "cart")
	w.creatures._go(trader, "travel", Vector2i(196, 170), false)
	for i in 10:
		w.creatures._move(trader)
	var trader_id := trader.id
	var horse_id := String(trader.job["horse"])
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 6, 5)
	check(w.creatures.get_creature(trader_id) == null, "the driver's chunk is not loaded")
	check(w.creatures.get_creature(horse_id) != null, "the horse's chunk is loaded")
	w.creatures.remove(horse_id)
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	trader = w.creatures.get_creature(trader_id)
	w.creatures._traveller(trader, _content.get_def(trader.kind))
	eq(trader.job.get("horse"), "", "the trader learns its horse died, even after restart")


func test_horse_is_released_when_driver_dies_in_another_chunk() -> void:
	_field()
	_clear_caravan_border()
	var trader := _spawn("base:villager", Vector2i(190, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	w.creatures._make_caravan(trader, "cart")
	w.creatures._go(trader, "travel", Vector2i(196, 170), false)
	for i in 10:
		w.creatures._move(trader)
	var trader_id := trader.id
	var horse_id := String(trader.job["horse"])
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 5, 5)
	check(w.creatures.get_creature(horse_id) == null, "the horse's chunk is not loaded")
	w.creatures.remove(trader_id)
	w.close()
	w = ServerWorld.open(_db, _content)
	w.chunk("surface", 6, 5)
	var horse := w.creatures.get_creature(horse_id)
	w.creatures._think(horse, w.tick)
	check(not horse.job.has("caravan_driver"), "the horse is released after restart")


func test_caravan_guard_defends_the_horse_and_follows_the_trader() -> void:
	_field()
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	w.creatures._make_caravan(trader, "cart")
	w.creatures._make_caravan_guard(trader)
	var horse := w.creatures.get_creature(String(trader.job["horse"]))
	var guard := w.creatures.get_creature(String(trader.job["guard"]))
	check(guard != null and guard.kind == "base:caravan_guard", "the escort is a living creature")
	var player := _player(guard.cell() + Vector2i.LEFT)
	var health := w.combat.health_of(player)
	w.combat.hurt(horse.id, 1, player)
	check(guard.memory.has(player), "the escort knows who attacked the horse")
	check(w.creatures._fight_back(guard, _content.get_def(guard.kind)), "it responds to the attack")
	check(w.combat.health_of(player) < health, "the escort can actually hit the attacker")
	guard.memory.clear()
	trader.pos = _at(Vector2i(175, 170))
	w.creatures._guard_caravan(guard)
	eq(guard.state, "follow", "once safe, it follows the trader")
	var guard_id := guard.id
	w.creatures.remove(guard_id)
	eq(trader.job.get("guard"), "", "a killed escort is not retained")
	w.creatures._make_caravan_guard(trader)
	eq(trader.job.get("guard"), "", "nor silently replaced")


func test_caravan_horse_does_not_walk_through_a_tree() -> void:
	_field()
	var tree := Vector2i(175, 170)
	w.chunk("surface", tree.x >> 5, tree.y >> 5).set_cell("cover", tree.x & 31, tree.y & 31, "base:oak")
	check(w.is_solid("surface", tree.x, tree.y), "the tree blocks movement")
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.face = Vector2i.RIGHT
	w.creatures._make_caravan(trader, "cart")
	var horse := w.creatures.get_creature(String(trader.job["horse"]))
	w.creatures._go(trader, "travel", Vector2i(180, 170), false)
	var hit_tree := false
	for i in 100:
		w.creatures._move(trader)
		if tree in BodySize.cells(horse.pos, BodySize.of(_content.get_def(horse.kind))["half"]):
			hit_tree = true
			break
		if trader.target == Creature.NO_TARGET:
			break
	check(not hit_tree, "the horse's server body never enters the blocked cell")


func test_pack_caravan_finishes_a_diagonal_detour_from_off_centre() -> void:
	w.close()
	w = ServerWorld.open(tmp_dir().path_join("ccc.db"), _content, {"seed": 4061418915})
	for y in range(-1, 2):
		for x in range(-1, 2):
			w.chunk("surface", x, y)
	var trader := _spawn("base:villager", Vector2i(27, 3))
	trader.job = {"profession": "base:trader"}
	# The actual stuck return leg in the author's world ccc. Its fractional
	# position matters: cell-centre-only tests did not reproduce the corner.
	trader.pos = Vector2i(7008, 992)
	trader.face = Vector2i(-1, -1)
	w.creatures._make_caravan(trader, "pack")
	trader.route = {"road": [0, 0, 0, 0], "i": 38, "step": -1}
	var goal := Vector2i(26, 2)
	trader.path = [goal]
	w.creatures._go(trader, "detour", goal, false)
	w.world_time = 12 * Daylight.HOUR_MS
	for i in 200:
		w.creatures._move(trader)
		if trader.target == Creature.NO_TARGET:
			if trader.cell() == goal:
				break
			w.creatures._traveller(trader, _content.get_def(trader.kind))
	eq(trader.target, Creature.NO_TARGET, "a diagonal step must finish instead of seesawing across the target")
	eq(trader.cell(), goal)


func test_caravan_cart_does_not_clip_a_tree_beside_the_driver() -> void:
	_field()
	var tree := Vector2i(172, 171)
	w.chunk("surface", tree.x >> 5, tree.y >> 5).set_cell("cover", tree.x & 31, tree.y & 31, "base:oak")
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.face = Vector2i.RIGHT
	w.creatures._make_caravan(trader, "cart")
	w.creatures._go(trader, "travel", Vector2i(180, 170), false)
	var hit_tree := false
	var half := Vector2i(ceili(.95 * Movement.UNIT), ceili(.70 * Movement.UNIT))
	for i in 100:
		w.creatures._move(trader)
		if tree in BodySize.cells(trader.pos, half):
			hit_tree = true
			break
		if trader.target == Creature.NO_TARGET:
			break
	check(not hit_tree, "the wider wagon also stops before the tree")


func test_caravan_cargo_drops_when_trader_dies() -> void:
	_field()
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 7}
	w.creatures._make_caravan(trader, "cart")
	var horse_id := String(trader.job["horse"])
	var stock := w.inventory("trade|" + trader.id)
	stock.add("base:plank", 3)
	w.touch_inventory("trade|" + trader.id)
	w.combat.hurt(trader.id, 100, "")
	check(not w.creatures.has(trader.id), "the trader died")
	eq(stock.count("base:plank"), 0, "cargo is removed from the trader's inventory")
	var planks := 0
	var coins := 0
	for item: Dictionary in w.items.values():
		if item.get("item") == "base:plank":
			planks += int(item["count"])
		if item.get("item") == "base:coin":
			coins += int(item["count"])
	eq(planks, 3, "all the cargo is available on the ground")
	eq(coins, 7, "the purse is available too")
	var horse := w.creatures.get_creature(horse_id)
	check(horse != null and not horse.job.has("caravan_driver"), "the horse is released")


func test_caravan_death_commits_horse_release_and_cargo_together() -> void:
	_field()
	var trader := _spawn("base:villager", Vector2i(170, 170))
	trader.job = {"profession": "base:trader", "purse": 7}
	w.creatures._make_caravan(trader, "cart")
	var horse_id := String(trader.job["horse"])
	var stock := w.inventory("trade|" + trader.id)
	stock.add("base:plank", 3)
	w.touch_inventory("trade|" + trader.id)
	check(w.sync(), "the starting caravan is on disk")
	w.combat.hurt(trader.id, 100, "")
	w.flush_state()
	w.writer.wait_idle()
	var old_rows := w.store.entities_in_chunk("surface", 5, 5)
	check(old_rows.any(func(row: Dictionary) -> bool: return row["id"] == trader.id), "the old trader remains until the death batch commits")
	var old_horse: Dictionary = old_rows.filter(func(row: Dictionary) -> bool: return row["id"] == horse_id)[0]
	eq(Cbor.decode(old_horse["data"]).value["job"]["caravan_driver"], trader.id, "the independent flush cannot release the horse first")
	eq(w.store.read_meta("caravan_dead|" + trader.id), "", "the death marker also waits for the operation")
	var old_stock := Inventory.from_data(Cbor.decode(w.store.get_inventory("trade|" + trader.id)).value)
	eq(old_stock.count("base:plank"), 3, "the old cargo remains until the same commit")
	w.commit_async(true)
	w.writer.wait_idle()
	w.poll()
	var rows := w.store.entities_in_chunk("surface", 5, 5)
	check(not rows.any(func(row: Dictionary) -> bool: return row["id"] == trader.id), "the trader is removed")
	var saved_horse: Dictionary = rows.filter(func(row: Dictionary) -> bool: return row["id"] == horse_id)[0]
	check(not Cbor.decode(saved_horse["data"]).value["job"].has("caravan_driver"), "the horse is released in the same batch")
	eq(w.store.read_meta("caravan_dead|" + trader.id), "1", "the death marker was committed")
	var saved_stock := Inventory.from_data(Cbor.decode(w.store.get_inventory("trade|" + trader.id)).value)
	eq(saved_stock.count("base:plank"), 0, "cargo was removed from the trader")


func test_caravan_links_reach_a_network_client_and_clear_on_loss() -> void:
	var net := MemoryTransport.MemoryNetwork.new()
	var keys := ProjectSettings.globalize_path("user://test_keys/")
	var server := GameServer.new(w, net.server(), PlayerIdentity.load_or_create(keys + "server"))
	server.wait_for_disk = true
	var owner := PlayerIdentity.load_or_create(keys + "owner")
	var character := PortableCharacter.create("Аня", "base:human_m")
	character.styles = CharacterLibrary.STYLE_DEFAULTS.duplicate()
	var client := GameClient.new(net.client(), owner, CharacterFile.export_signed(character, owner, _content), _content)
	for i in 40:
		server.step()
		client.step()
	if not check(client.state == "playing", client.reject_reason):
		return
	var at := Movement.cell_of(client.position) + Vector2i(2, 0)
	var trader := _spawn("base:villager", at)
	trader.job = {"profession": "base:trader", "purse": 42}
	trader.route = {"road": [], "i": 1, "step": 1}
	w.creatures._make_caravan(trader, "cart")
	var horse_id := String(trader.job["horse"])
	for i in 40:
		server.step()
		client.step()
	var trader_seen: Dictionary = client.entities.get(trader.id, {})
	var horse_seen: Dictionary = client.entities.get(horse_id, {})
	eq(trader_seen.get("horse"), horse_id, "the client knows which horse pulls the cart")
	eq(horse_seen.get("caravan_driver"), trader.id, "the horse names the driver")
	check(not horse_seen.is_empty(), "the actual horse has its own network entity")
	w.creatures.remove(horse_id)
	for i in 40:
		server.step()
		client.step()
	eq((client.entities.get(trader.id, {}) as Dictionary).get("horse"), "", "the client is told the horse was lost")
	check(not client.entities.has(horse_id), "the removed horse disappears")
	var pack_trader := _spawn("base:villager", at)
	pack_trader.job = {"profession": "base:trader", "purse": 42}
	pack_trader.route = {"road": [], "i": 1, "step": 1}
	w.creatures._make_caravan(pack_trader, "pack")
	var pack_horse_id := String(pack_trader.job["horse"])
	for i in 40:
		server.step()
		client.step()
	check(bool((client.entities.get(pack_horse_id, {}) as Dictionary).get("pack", false)), "the network client sees the panniers")
	w.creatures.remove(pack_trader.id)
	for i in 40:
		server.step()
		client.step()
	var released: Dictionary = client.entities.get(pack_horse_id, {})
	check(not released.is_empty() and not bool(released.get("pack", true)), "the client sees the horse released and unloaded")
	eq(released.get("caravan_driver"), "", "the old driver link is cleared on the client")


func test_sight_is_honest() -> void:
	_field()
	var deer := _spawn("base:deer", Vector2i(170, 170))
	var def := _content.get_def("base:deer")
	w.world_time = 12 * Daylight.HOUR_MS
	check(Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(178, 170)), "8 cells off at noon")
	check(not Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(184, 170)), "beyond its sight")
	w.grant("b", "base:plank", 10)
	var r := {"request_id": "wall", "type": "build", "location": "surface", "x": 174, "y": 170, "part": "base:wood_wall"}
	w.handle("b", r)
	w.sync()
	check(not Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(178, 170)), "not through a wall")
	check(Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(170, 178)), "but round it")
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS
	check(not Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(170, 178)), "at night, 8 cells is too far")
	w.grant("b", "base:log", 1)
	w.handle("b", {"request_id": "torch", "type": "build", "location": "surface", "x": 171, "y": 179, "part": "base:torch"})
	w.sync()
	check(Perception.sees(w, "surface", Vector2i(170, 170), def, Vector2i(170, 178)), "by a torch it is seen again")
	deer.changed()


func test_memory_keeps_where_it_saw_not_where_one_is() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var hare := _spawn("base:hare", Vector2i(170, 170))
	var pid := _player(Vector2i(176, 170))
	_ticks(12, Vector2i(170, 170))
	check(hare.memory.has(pid), "it saw the player")
	w.move_character(pid, _at(Vector2i(190, 190)))  # gone far, out of sight
	_ticks(12, Vector2i(170, 170))
	check(hare.memory.has(pid), "still remembers")
	check(Vector2(hare.memory[pid]["pos"]).distance_to(Vector2(190, 190)) > 10, "where it saw, not where the player is")


func test_a_hare_runs_from_someone_coming_close() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var hare := _spawn("base:hare", Vector2i(170, 170))
	_player(Vector2i(173, 170))
	_ticks(30, Vector2i(170, 170))
	check(hare.state in ["flee", "alert"], "it ran and watches: " + hare.state)
	check(hare.cell().x < 167, "away from the player: %s" % hare.cell())


func test_noise_is_heard_as_a_place() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var deer := _spawn("base:deer", Vector2i(170, 170))
	w.grant("b", "base:plank", 10)
	w.handle("b", {"request_id": "n", "type": "build", "location": "surface", "x": 176, "y": 172, "part": "base:wood_wall"})
	w.sync()
	_ticks(12, Vector2i(170, 170))
	check(deer.memory.has("noise"), "it heard building")
	eq(deer.memory["noise"]["pos"], Vector2i(176, 172), "where, not who")


func test_villagers_go_home_at_night() -> void:
	_field()
	var v := w.creatures._spawn("base:villager", "surface", Vector2i(170, 170), {"body_plan": "base:human_m"}, 3)
	v.pos = _at(Vector2i(175, 172))
	w.world_time = 22 * Daylight.HOUR_MS
	v.last_time = w.world_time
	_ticks(200, Vector2i(170, 170))
	eq(v.cell(), Vector2i(170, 170), "home")
	eq(v.state, "home")


func test_thinking_has_a_budget_and_nobody_thinks_far_from_players() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	for i in 300:
		_spawn("base:hare", Vector2i(161 + i % 30, 161 + i / 30 % 30))
	var most := 0
	for i in 20:
		_ticks(1, Vector2i(170, 170))
		most = maxi(most, w.creatures.thinks_last_tick)
	eq(most, CreatureSim.THINKS_PER_TICK, "never more than the budget")
	var far := _spawn("base:hare", Vector2i(170, 170))
	_ticks(CreatureSim.ACTIVE_TICKS + 30)  # nobody needs these chunks any more
	var before := far.pos
	var thought := far.next_think
	_ticks(120)
	eq(far.pos, before, "nobody near: it stands")
	check(far.next_think - thought >= 60, "and thinks rarely")


func test_a_creature_away_catches_up() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	var v := w.creatures._spawn("base:villager", "surface", Vector2i(170, 170), {"body_plan": "base:human_m"}, 3)
	v.pos = _at(Vector2i(178, 175))
	v.last_time = w.world_time
	w.world_time = Daylight.DAY_MS + 23 * Daylight.HOUR_MS  # long away; night now
	_ticks(30, Vector2i(170, 170))
	eq(v.cell(), Vector2i(170, 170), "back at home at once: the night went on without anyone")


func test_a_chunk_unloads_with_its_creatures_and_brings_them_back() -> void:
	_field(8, 8)
	var hare := _spawn("base:hare", Vector2i(266, 266))
	var id := hare.id
	w.sync()
	var gone := 0
	for i in 3:
		w.tick += 10000
		gone += w.unload_idle(100)
		w.sync()
	check(not w.has_chunk("surface", 8, 8), "unloaded")
	check(not w.creatures.has(id), "its creature too")
	w.chunk("surface", 8, 8)
	check(w.creatures.has(id), "back with it")


## ADR-0015: a creature below sees one on a walkway on a wall, not one
## behind a wall upstairs.
func test_a_creature_sees_one_on_a_walkway_not_behind_walls_upstairs() -> void:
	_field()
	w.world_time = 12 * Daylight.HOUR_MS
	w.grant("b", "base:plank", 100)
	var level := ""
	for x in range(170, 177):
		w.handle("b", {"request_id": "w%d" % x, "type": "build", "location": "surface", "x": x, "y": 170, "part": "base:wood_wall"})
		w.handle("b", {"request_id": "c%d" % x, "type": "build", "location": "surface", "x": x, "y": 170, "part": "base:wood_ceiling"})
		w.handle("b", {"request_id": "d%d" % x, "type": "build", "location": "surface", "x": x, "y": 169, "part": "base:wood_ceiling"})
	w.sync()
	level = w.levels.level(w._ceiling_building("surface", 173, 170), 1)
	check(level != "", "a walkway up there")
	var deer := _spawn("base:deer", Vector2i(173, 177))
	var pid := _player(Vector2i(173, 160))
	w.present[pid]["location"] = level
	w.move_character(pid, _at(Vector2i(173, 170)))
	_ticks(12, Vector2i(173, 177))
	check(deer.memory.has(pid), "it saw the one on the walkway")
	deer.memory.clear()
	w.move_character(pid, _at(Vector2i(173, 169)))
	w.handle("b", {"request_id": "up", "type": "build", "location": level, "x": 173, "y": 170, "part": "base:wood_wall"})
	w.sync()
	eq(w._part_at(level, 173, 170, "structure"), "base:wood_wall", "a wall upstairs")
	_ticks(12, Vector2i(173, 177))
	check(not deer.memory.has(pid), "not behind a wall upstairs")


func test_bodies_have_their_own_size() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors, PackedStringArray())
	var hare := BodySize.of(content.get_def("base:hare"))
	var deer := BodySize.of(content.get_def("base:deer"))
	eq(BodySize.of(content.get_def("base:human_m")), BodySize.HUMAN, "a man without a size is a man")
	check(hare["half"].x < BodySize.HUMAN["half"].x and deer["half"].x > BodySize.HUMAN["half"].x, "small and big boxes")
	check(float(hare["eye"]) < Sight.EYE and float(deer["height"]) > float(BodySize.HUMAN["height"]), "heights by body")
	# A body two cells wide stops a cell sooner at a wall than a man does.
	var wall := func(x: int, _y: int) -> bool: return x == 5
	var man := Vector2i(Movement.UNIT / 2, Movement.UNIT / 2)
	var big := man
	for i in 200:
		man = Movement.step_at(man, 1, 0, wall, 51)
		big = Movement.step_at(big, 1, 0, wall, 51, Vector2i(Movement.UNIT, Movement.UNIT / 2))
	eq(man.x, 5 * Movement.UNIT - Movement.HALF_X)
	eq(big.x, 4 * Movement.UNIT)
	for bad: Variant in [[1, 2], {"half": [0, 1]}, {"half": [1]}, {"height": -1}, {"eye": "high"}, {"radius": 99}]:
		var errors := PackedStringArray()
		BodySize.parse("test:x", bad, errors)
		check(not errors.is_empty(), "malformed size refused: %s" % str(bad))
	eq(BodySize.cells(Vector2i(384, 384), Vector2i(256, 128)), [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)] as Array[Vector2i],
		"the cells a body covers")
