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
	_frames(10)
	check(g.chest_panel.visible, "the chest opens: %s / %s" % [g._note, Actions.quick(g.actions)])
	var total := int(g.client.inventory().get("base:arrow", 0))
	g.chest_panel.move.emit("base:arrow", 1, true)
	_frames(10)
	eq(g.chest_panel.contents, {"base:arrow": 1}, "one")
	var half := (total - 1) / 2
	g.chest_panel.move.emit("base:arrow", half, true)
	_frames(10)
	eq(g.chest_panel.contents, {"base:arrow": 1 + half}, "half of what was left")
	g.chest_panel.move.emit("base:arrow", total - 1 - half, true)
	_frames(10)
	eq(g.chest_panel.contents, {"base:arrow": total}, "all")
	eq(int(g.client.inventory().get("base:arrow", 0)), 0)
	g.chest_panel.move.emit("base:arrow", total, false)
	_frames(10)
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
