extends TestCase
## The game as a player plays it (ADR-0021): a local world, the mouse and the
## keys going through the viewport (panels catch what is meant for them),
## the server judging every request. Drag and drop between panels cannot be
## pushed through the viewport here: the drop itself is called.

var app: App
var g: GameScreen
var w: ServerWorld


func before_each() -> void:
	app = App.new()
	app.configure({"profile_dir": tmp_dir(), "world": "play", "time": "12"})
	(Engine.get_main_loop() as SceneTree).root.add_child(app)
	g = app.game
	w = g.game.world
	_frames(120, true)
	# A clear field round the player, things to build with and to use.
	var me := _me()
	for y in range(me.y - 12, me.y + 13):
		for x in range(me.x - 12, me.x + 13):
			var c := w.chunk("surface", floori(x / 32.0), floori(y / 32.0))
			c.set_cell("ground", posmod(x, 32), posmod(y, 32), "base:grass")
			c.set_cell("cover", posmod(x, 32), posmod(y, 32), "")
			c.set_cell("structure", posmod(x, 32), posmod(y, 32), "")
			w._changed(ServerWorld.chunk_key("surface", floori(x / 32.0), floori(y / 32.0)))
	for id: String in w.creatures.creatures.keys():
		w.creatures.remove(id)
	for item: String in {"base:plank": 300, "base:log": 40, "base:stone": 40}:
		w.grant(g.client.character_id, item, {"base:plank": 300, "base:log": 40, "base:stone": 40}[item])
	_frames(30)


func after_each() -> void:
	app.quit()
	app.free()
	for i in 2:
		await (Engine.get_main_loop() as SceneTree).process_frame


func _frames(n: int, until_playing := false) -> void:
	for i in n:
		g._process(0.05)
		g.view.update_view(0.0, 0.05)
		if until_playing and g.client.state == "playing" and g.client.has_position:
			return
		OS.delay_msec(1)


## Steps frames until `done` is true (at most `seconds` of real time): what
## waits on the store writer's thread (a build committed, then answered)
## takes as long as the disk does, which a busy machine makes seconds.
func _frames_until(done: Callable, seconds := 120.0) -> void:
	var start := Time.get_ticks_msec()
	while not done.call() and Time.get_ticks_msec() - start < seconds * 1000.0:
		_frames(1)


func _me() -> Vector2i:
	return Movement.cell_of(g.client.position)


## The viewport position of a cell's middle (or a little up, for tall parts).
func _screen(cell: Vector2i, lift := 0.0) -> Vector2:
	var world := Vector2((cell.x + 0.5) * WorldView.CELL, (cell.y + 0.5) * WorldView.CELL - lift)
	return g.get_viewport().get_canvas_transform() * world


func _move_mouse(at: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	g.get_viewport().push_input(m, true)
	g.mouse_at = g.get_viewport().get_canvas_transform().affine_inverse() * at


func _button(at: Vector2, index: MouseButton, pressed: bool) -> void:
	_move_mouse(at)
	var b := InputEventMouseButton.new()
	b.position = at
	b.global_position = at
	b.button_index = index
	b.pressed = pressed
	g.get_viewport().push_input(b, true)
	_frames(1)


func _click(at: Vector2, index := MOUSE_BUTTON_LEFT) -> void:
	_button(at, index, true)
	_button(at, index, false)


func _key(k: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = true
	g.get_viewport().push_input(e, true)
	_frames(1)


func _part(cell: Vector2i, layer := "structure", loc := "surface") -> String:
	return w._part_at(loc, cell.x, cell.y, layer)


## Chooses a blueprint from the catalogue (B, then the list).
func _blueprint(part: String) -> void:
	_key(KEY_B)
	g.catalog.chosen.emit(part)
	_frames(1)


func _drag(a: Vector2i, b: Vector2i, lift := 0.0) -> void:
	_button(_screen(a, lift), MOUSE_BUTTON_LEFT, true)
	_move_mouse(_screen(b, lift))
	_frames(2)
	_button(_screen(b, lift), MOUSE_BUTTON_LEFT, false)
	_frames(10)


func test_a_house_by_mouse_and_a_chosen_layer_taken_apart() -> void:
	var me := _me()
	var o := me + Vector2i(0, -3)  # the house's north-west corner
	_blueprint("base:wood_wall")
	_move_mouse(_screen(o))
	_button(_screen(o), MOUSE_BUTTON_LEFT, true)
	_move_mouse(_screen(o + Vector2i(4, 0)))
	_frames(2)
	eq(g._plan.size(), 5, "the whole row is shown before the button is let go")
	check(g._plan.all(func(p: Array) -> bool: return p[1] == ""), "all of it allowed: %s" % [g._plan])
	var shown := g._ghosts.filter(func(s: Sprite2D) -> bool: return s.visible).size()
	eq(shown, 5, "a picture on every cell")
	_button(_screen(o + Vector2i(4, 0)), MOUSE_BUTTON_LEFT, false)
	_frames(10)
	for x in 5:
		eq(_part(o + Vector2i(x, 0)), "base:wood_wall", "wall %d" % x)
	# A ceiling over an area; a cell where someone stands is refused, not built.
	_blueprint("base:wood_ceiling")
	_drag(o + Vector2i(0, 1), o + Vector2i(4, 2), float(WorldView.COVER_LIFT))
	var ceilings := 0
	for y in [1, 2]:
		for x in 5:
			ceilings += 1 if _part(o + Vector2i(x, y), "ceiling") != "" else 0
	eq(ceilings, 10, "an area of ceilings")
	_blueprint("base:thatch_roof")
	_drag(o, o + Vector2i(1, 0), float(WorldView.COVER_LIFT))
	eq(_part(o, "roof"), "base:thatch_roof", "a roof over the wall")
	_blueprint("base:wood_door")
	_click(_screen(o + Vector2i(2, 3)))
	_frames(10)
	eq(_part(o + Vector2i(2, 3)), "base:wood_door", "a door")
	# Taking apart: the roof chosen, the wall under it stays; the door, its
	# neighbours stay.
	_blueprint(BuildCatalog.DEMOLISH)
	_click(_screen(o, float(WorldView.COVER_LIFT)))  # on the roof's picture, not the wall's
	_frames(10)
	eq(_part(o, "roof"), "", "the roof taken apart")
	eq(_part(o), "base:wood_wall", "the wall under it stays")
	eq(_part(o + Vector2i(1, 0), "roof"), "base:thatch_roof", "the next roof stays")


func test_blueprints_show_what_cannot_be_built_and_panels_catch_clicks() -> void:
	var me := _me()
	_blueprint("base:stone_wall")
	_button(_screen(me + Vector2i(-2, 0)), MOUSE_BUTTON_LEFT, true)
	_move_mouse(_screen(me + Vector2i(9, 0)))
	_frames(2)
	var why := {}
	for p: Array in g._plan:
		why[p[1]] = int(why.get(p[1], 0)) + 1
	check(why.has("someone_there"), "the player's own cell: %s" % why)
	check(why.has("too_far"), "beyond reach: %s" % why)
	check(why.has(""), "the rest allowed")
	_button(_screen(me + Vector2i(9, 0)), MOUSE_BUTTON_LEFT, false)
	_frames(10)
	eq(_part(me), "", "nothing built where it was refused")
	check(_part(me + Vector2i(1, 0)) == "base:stone_wall", "built where allowed")
	# A click on an open panel does not build behind it.
	_key(KEY_I)
	var panel_at := g.inventory_panel.get_global_rect().get_center()
	var cell := Vector2i((g.get_viewport().get_canvas_transform().affine_inverse() * panel_at / WorldView.CELL).floor())
	var before := _part(cell)
	_click(panel_at)
	_frames(10)
	eq(_part(cell), before, "the click went to the panel, not to the world behind it")


func test_q_against_a_wolf_and_things_in_and_out_of_a_chest() -> void:
	# Nothing of the world's to hunt the player meanwhile (a slow machine
	# takes seconds; a wolf or a spider may come and kill).
	for cid: String in w.creatures.creatures.keys():
		w.creatures.remove(cid)
	var me := _me()
	var id := g.client.character_id
	w.grant(id, "base:pickaxe", 1)
	w.grant(id, "base:spear", 1)
	w.grant(id, "base:arrow", 20)
	_frames(5)
	g.hotbar.put(0, "base:pickaxe", -1)
	g.hotbar.put(1, "base:spear", -1)
	_key(KEY_1)
	_frames(5)
	eq(w.held_of(id), "base:pickaxe", "the pick in the hands (the server says)")
	var wolf := w.creatures._spawn("base:wolf", "surface", me + Vector2i(1, 0), {}, 1)
	wolf.next_think = 1 << 40
	_frames(5)
	_key(KEY_Q)
	_frames(3)
	eq(w.held_of(id), "base:spear", "Q: the spear, at once")
	_move_mouse(_screen(Movement.cell_of(wolf.pos), 8.0))
	_frames(2)
	eq(Actions.primary(g.actions).get("id"), "strike", "aiming at the wolf: strike")
	_click(_screen(Movement.cell_of(wolf.pos), 8.0))
	_frames(5)
	eq(wolf.health, 14 - 5, "struck with the spear")
	w.creatures.remove(wolf.id)  # struck, it wakes and bites back: gone
	_key(KEY_Q)
	_frames(3)
	eq(w.held_of(id), "base:pickaxe", "Q again: the pick back")
	# A chest: one, half, all, by the panel's signal (as its clicks send).
	_blueprint("base:chest")
	_click(_screen(me + Vector2i(0, 1)))
	_frames(10)
	_key(KEY_ESCAPE)
	eq(_part(me + Vector2i(0, 1)), "base:chest")
	g.target = {"kind": "part", "layer": "structure", "id": "base:chest", "cell": me + Vector2i(0, 1), "location": "surface"}
	g.actions = Actions.of(g.content, g.client, g.view, "", g.target, Vector2i.ZERO)
	g._do(Actions.quick(g.actions))
	_frames_until(func() -> bool: return g.chest_panel.visible)
	check(g.chest_panel.visible, "the chest opens: %s / %s" % [g._note, Actions.quick(g.actions)])
	var total := int(g.client.inventory().get("base:arrow", 0))
	g.chest_panel.move.emit("base:arrow", 1, true)
	_frames_until(func() -> bool: return not g.chest_panel.contents.is_empty())
	eq(g.chest_panel.contents, {"base:arrow": 1}, "one")
	var half := (total - 1) / 2
	g.chest_panel.move.emit("base:arrow", half, true)
	_frames_until(func() -> bool: return int(g.chest_panel.contents.get("base:arrow", 0)) == 1 + half)
	eq(g.chest_panel.contents, {"base:arrow": 1 + half}, "half of what was left")
	g.chest_panel.move.emit("base:arrow", total - 1 - half, true)
	_frames_until(func() -> bool: return int(g.chest_panel.contents.get("base:arrow", 0)) == total)
	eq(g.chest_panel.contents, {"base:arrow": total}, "all")
	eq(int(g.client.inventory().get("base:arrow", 0)), 0)
	g.chest_panel.move.emit("base:arrow", total, false)
	_frames_until(func() -> bool: return int(g.client.inventory().get("base:arrow", 0)) == total)
	eq(int(g.client.inventory().get("base:arrow", 0)), total, "and back")


func test_the_client_judges_blueprints_as_the_server_does() -> void:
	var me := _me()
	w.grant("x", "base:plank", 10)
	w.handle("x", {"request_id": "c1", "type": "build", "location": "surface", "x": me.x + 2, "y": me.y, "part": "base:wood_ceiling"})
	w.handle("x", {"request_id": "c2", "type": "build", "location": "surface", "x": me.x + 3, "y": me.y, "part": "base:wood_wall"})
	w.sync()
	var c := w.chunk("surface", floori((me.x - 2) / 32.0), floori(me.y / 32.0))
	c.set_cell("ground", posmod(me.x - 2, 32), posmod(me.y, 32), "base:water")
	w._changed(ServerWorld.chunk_key("surface", floori((me.x - 2) / 32.0), floori(me.y / 32.0)))
	_frames(20)
	var mine := ClientBuildView.new(g.client)
	var differ := []
	for part: String in ["base:wood_wall", "base:wood_ceiling", "base:thatch_roof", "base:wood_stairs", "base:torch",
			"base:mine_shaft", "base:headframe"]:
		for dx in range(-3, 5):
			for dy in [-1, 0]:
				var at := me + Vector2i(dx, dy)
				var a := BuildRules.check(w, w.content, part, "surface", at.x, at.y, "n")
				var b := BuildRules.check(mine, g.content, part, "surface", at.x, at.y, "n")
				if a != b:
					differ.append([part, dx, dy, a, b])
	eq(differ, [], "the same verdicts on every cell")


func test_things_dragged_into_slots_and_a_wall_struck_and_mended_from_the_menu() -> void:
	var me := _me()
	var id := g.client.character_id
	w.grant(id, "base:axe", 1)
	_frames(5)
	# Drag: the list gives the thing, the slot takes it (what Godot's drag does
	# between them; the gesture itself is not pushed here).
	_key(KEY_I)
	var list: InventoryPanel.DragList = g.inventory_panel._list
	var row := list.ids.find("base:axe")
	check(row >= 0, "the axe is in the list")
	list.select(row)
	var data: Variant = list._get_drag_data(list.get_item_rect(row).get_center())
	eq(data, {"item": "base:axe"})
	var slot: Hotbar.Slot = g.hotbar._slots[4]
	check(slot._can_drop_data(Vector2.ZERO, data), "a slot takes it")
	slot._drop_data(Vector2.ZERO, data)
	eq(g.hotbar.items[4], "base:axe", "in the fifth slot")
	var saved: Dictionary = g.settings.get_value("hotbars")
	eq((saved[id] as Array)[4], "base:axe", "kept for the character")
	slot._drop_data(Vector2.ZERO, slot._get_drag_data(Vector2.ZERO))  # onto itself: nothing changes
	eq(g.hotbar.items[4], "base:axe")
	(g.hotbar._slots[6] as Hotbar.Slot)._drop_data(Vector2.ZERO, {"item": "base:axe", "from_slot": 4})
	eq(g.hotbar.items[6], "base:axe", "slot to slot")
	eq(g.hotbar.items[4], "", "the old slot left")
	# A click on the list no longer puts a thing into a slot: only a drag does;
	# a slot dragged back onto the list is emptied.
	list.item_clicked.emit(row, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	eq(g.hotbar.items.count("base:axe"), 1, "a click: no slot changed")
	var back: Variant = (g.hotbar._slots[6] as Hotbar.Slot)._get_drag_data(Vector2.ZERO)
	check(list._can_drop_data(Vector2.ZERO, back), "the list takes a slot's thing back")
	check(not list._can_drop_data(Vector2.ZERO, data), "not its own row")
	list._drop_data(Vector2.ZERO, back)
	eq(g.hotbar.items[6], "", "the slot emptied")
	check(int(g.client.inventory().get("base:axe", 0)) > 0, "the axe still carried")
	g.hotbar.put(6, "base:axe", -1)
	_key(KEY_I)
	_key(KEY_7)
	_frames(3)
	# A wall of one's own, struck from the menu with the axe, then mended.
	_blueprint("base:wood_wall")
	_click(_screen(me + Vector2i(1, 0)))
	_frames(10)
	_key(KEY_ESCAPE)
	var wall := me + Vector2i(1, 0)
	eq(_part(wall), "base:wood_wall")
	_move_mouse(_screen(wall, 8.0))
	_frames(2)
	var strike: Array = g.actions.filter(func(a: Dictionary) -> bool: return a["id"] == "strike_part")
	check(not strike.is_empty(), "the menu offers a blow at the wall")
	g._do(strike[0])
	_frames(10)
	var props := w.chunk("surface", floori(wall.x / 32.0), floori(wall.y / 32.0)).get_props(posmod(wall.x, 32), posmod(wall.y, 32))
	eq(int(props.get("damage", 0)), 4, "worn by the axe")
	_frames(2)
	var mend: Array = g.actions.filter(func(a: Dictionary) -> bool: return a["id"] == "repair")
	check(not mend.is_empty(), "and now offers to mend it")
	g._do(mend[0])
	_frames(10)
	props = w.chunk("surface", floori(wall.x / 32.0), floori(wall.y / 32.0)).get_props(posmod(wall.x, 32), posmod(wall.y, 32))
	eq(int(props.get("damage", 0)), 0, "mended")


func test_character_window_catches_clicks_and_changes_equipment() -> void:
	_key(KEY_C)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var panel := g.character_panel
	check(panel.visible, "C opens the character window")
	check(g.get_viewport_rect().encloses(panel.get_global_rect()),
		"the whole equipment window fits the native viewport")
	var hat: CharacterPanel.EquipmentSlot = panel._slots["headwear"]
	hat._drop_data(Vector2.ZERO, {"item":"base:felt_hat"})
	_frames(15)
	eq(g.client.own["appearance"]["worn"].get("headwear"), "base:felt_hat")
	_click(hat.get_global_rect().get_center())
	_frames(15)
	check(not g.client.own["appearance"]["worn"].has("headwear"), "mouse click unequips")
	eq(g.client.inventory().get("base:felt_hat"), 1, "the hat is back in the bag")
	var list := panel.bag._list
	check(not panel.bag._ids.is_empty() and panel.bag._ids.all(panel.bag._can_wear),
		"beside the doll only what is worn or held: %s" % str(panel.bag._ids))
	check(g.client.inventory().has("base:plank") and not panel.bag._ids.has("base:plank"), "planks stay in the things (I)")
	check(panel.size.y >= 430, "a tall window: %d" % panel.size.y)
	var index := panel.bag._ids.find("base:felt_hat")
	list.select(index)
	list.item_selected.emit(index)
	var at := panel.bag._wear.get_global_rect().get_center()
	_click(at)
	_frames(15)
	eq(g.client.own["appearance"]["worn"].get("headwear"), "base:felt_hat", "bag's wear button equips")
	if panel.get_global_rect().intersects(g.minimap.get_global_rect()):
		_move_mouse(g.minimap.get_global_rect().get_center())
		var hovered := g.get_viewport().gui_get_hovered_control()
		check(hovered != null and panel.is_ancestor_of(hovered), "equipment catches input above the minimap")
	_key(KEY_ESCAPE)
	check(not panel.visible and app.menu == null, "Esc closes equipment before the game menu")


func test_crafts_at_a_workbench_and_food_in_the_hands() -> void:
	var id := g.client.character_id
	var me := _me()
	w.grant(id, "base:log", 6)
	g.client.request({"type": "build", "location": "surface", "x": me.x + 1, "y": me.y, "part": "base:workbench"})
	_frames_until(func() -> bool: return _part(me + Vector2i(1, 0)) == "base:workbench")
	_frames_until(func() -> bool: return g.crafts.station_near("workbench"))  # the client sees it too
	_key(KEY_K)
	check(g.crafts.visible, "K opens the crafts")
	check(g.crafts._can[g.crafts._ids[0]], "what can be made here comes first")
	check(not g.crafts._can["base:smelt_iron"], "no forge: no iron")
	check(g.crafts._can["base:saw_planks"], "logs at the workbench: planks")
	var before := int(g.client.inventory().get("base:plank", 0))
	g.crafts.craft.emit("base:saw_planks", 2)
	_frames_until(func() -> bool: return g._note.begins_with("сделано"))
	eq(int(g.client.inventory().get("base:plank", 0)), before + 8, "two logs sawn")
	check(g._note.begins_with("сделано"), "the note says what was made: " + g._note)
	_key(KEY_K)
	check(not g.crafts.visible, "K closes them")
	# Food in the hands: the left button eats it, when one is hurt or hungry.
	w.grant(id, "base:cooked_meat", 1)
	w.combat.hurt(id, 5, "")
	w.needs.set_satiety(id, 40.0)
	_frames(5)
	g.hotbar.put(0, "base:cooked_meat", -1)
	_key(KEY_1)
	_frames(5)
	var acts := Actions.of(g.content, g.client, g.view, "base:cooked_meat", {}, Vector2i.ZERO)
	eq(Actions.primary(acts).get("id"), "eat", "the left button eats")
	g._do(Actions.primary(acts))
	_frames_until(func() -> bool: return int(w.present[id]["health"]) > 15)
	eq(int(w.present[id]["health"]), 20, "eaten: health back")
	_frames_until(func() -> bool: return int(g.client.own.get("needs", {}).get("satiety", 0)) >= 75)
	check(g.hud.text.contains("Сытость 75"), "the screen shows one's own satiety: " + g.hud.text)


func test_a_field_grows_on_the_screen_and_a_hoe_ploughs() -> void:
	var me := _me()
	var cell := me + Vector2i(2, 0)
	var acts := Actions.of(g.content, g.client, g.view, "base:hoe", {"kind": "ground", "id": "base:grass", "cell": cell,
		"location": "surface"}, Vector2i.ZERO)
	eq(Actions.primary(acts).get("id"), "till", "a hoe on grass ploughs")
	acts = Actions.of(g.content, g.client, g.view, "base:wheat_seeds", {"kind": "ground", "id": "base:farmland", "cell": cell,
		"location": "surface"}, Vector2i.ZERO)
	eq(Actions.primary(acts).get("id"), "sow", "a seed on a field is sown")
	var c := w.chunk("surface", floori(cell.x / 32.0), floori(cell.y / 32.0))
	c.set_cell("ground", posmod(cell.x, 32), posmod(cell.y, 32), "base:farmland")
	c.set_cell("cover", posmod(cell.x, 32), posmod(cell.y, 32), "base:wheat_crop")
	w._set_layer_props(c, "cover", posmod(cell.x, 32), posmod(cell.y, 32), {"planted": w.world_time})
	w._changed(ServerWorld.chunk_key("surface", floori(cell.x / 32.0), floori(cell.y / 32.0)))
	_frames_until(func() -> bool: return g.view._crops.has(cell))
	var v := g.content.visual_of("base:wheat_crop")
	var s: Sprite2D = g.view._crops[cell][0]
	eq(s.region_rect, Rect2(v["states"]["stage_0"][0], v["states"]["stage_0"][1], 32, 64), "just sown: a sprout")
	w.world_time += 48 * Daylight.HOUR_MS  # the clock goes on; the client hears it
	_frames_until(func() -> bool: return s.region_rect.position.x == float(v["states"]["stage_3"][0]))
	eq(s.region_rect.position.x, float(v["states"]["stage_3"][0]), "ripe on the screen with nothing sent but the time")


func test_a_bed_is_slept_in_seen_lying_and_left_by_walking() -> void:
	var id := g.client.character_id
	var me := _me()
	var cell := me + Vector2i(1, 0)
	var c := w.chunk("surface", floori(cell.x / 32.0), floori(cell.y / 32.0))
	c.set_cell("structure", posmod(cell.x, 32), posmod(cell.y, 32), "base:bed")
	w._changed(ServerWorld.chunk_key("surface", floori(cell.x / 32.0), floori(cell.y / 32.0)))
	w.needs.set_energy(id, 15.0)
	_frames_until(func() -> bool: return int(g.client.own.get("needs", {}).get("energy", 100)) <= 15)
	check(g.hud.text.contains("устали"), "the screen says one is tired: " + g.hud.text)
	var acts := Actions.of(g.content, g.client, g.view, "", {"kind": "part", "id": "base:bed", "layer": "structure",
		"cell": cell, "location": "surface"}, Vector2i.ZERO)
	eq(Actions.quick(acts).get("id"), "sleep", "E on a bed: to sleep")
	g._do(Actions.quick(acts))
	_frames_until(func() -> bool: return bool(g.client.own.get("asleep", false)))
	check(w.needs.asleep(id), "asleep on the server")
	_frames(3)
	var doll: CharacterSprite = g.view._characters[id]
	check(doll.get_node_or_null("Blanket") != null, "seen in bed, under the blanket")
	g._opts["walk"] = "-1,0"
	_frames_until(func() -> bool: return not w.needs.asleep(id))
	g._opts.erase("walk")
	check(not w.needs.asleep(id), "a step gets one up")
	_frames_until(func() -> bool: return not bool(g.client.own.get("asleep", false)))
	_frames(3)
	check(doll.get_node_or_null("Blanket") == null or doll.get_node("Blanket").is_queued_for_deletion(), "standing again")


func test_the_weather_on_the_screen_follows_the_sky() -> void:
	var seed := g.client.weather_seed
	var t := -1.0
	for h in 24 * 60:
		var at := (h + 0.5) * Daylight.HOUR_MS
		if Weather.rain(seed, at) == 0.0 and Weather.snow(seed, at) == 0.0 and Weather.fog(seed, at) == 0.0:
			t = at
			break
	w.world_time = int(t)
	_frames(30)
	eq(g.weather.rain, 0.0, "no rain on the screen when it does not rain")
	eq(g.weather.snow, 0.0)
	check(g.hud.text.begins_with("Весна, день"), "the season in the clock line: " + g.hud.text)
