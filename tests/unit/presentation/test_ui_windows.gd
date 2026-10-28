extends TestCase
## The windows' rules (UI 2.0): one work window at a time, a window at a
## thing closes the work ones, Esc's order, all on the screen.

var root: Control
var things: Control
var crafts: Control
var chest: Control
var menu: Control
var w: UiWindows


func before_each() -> void:
	root = Control.new()
	w = UiWindows.new()
	things = _window(Vector2(300, 200))
	crafts = _window(Vector2(500, 600))
	chest = _window(Vector2(200, 100))
	menu = _window(Vector2(80, 40))
	w.add(things, UiWindows.WORK)
	w.add(crafts, UiWindows.WORK)
	w.add(chest, UiWindows.AT_THING)
	w.add(menu, UiWindows.POPUP)


func after_each() -> void:
	root.free()


func _window(least: Vector2) -> Control:
	var c := Control.new()
	c.custom_minimum_size = least
	c.visible = false
	root.add_child(c)
	return c


func test_one_work_window_at_a_time() -> void:
	w.toggle(things, things.show)
	check(things.visible, "opened by its key")
	w.toggle(crafts, crafts.show)
	check(crafts.visible and not things.visible, "another work window replaces it")
	w.toggle(crafts, crafts.show)
	check(not crafts.visible, "its key again closes it")
	w.toggle(things, things.show)
	w.opening(chest)
	chest.show()
	check(chest.visible and not things.visible, "a window at a thing closes the work window")
	menu.show()
	w.opening(menu)
	check(chest.visible, "a popup closes nothing")


func test_escape_closes_in_order() -> void:
	things.show()
	chest.show()
	menu.show()
	check(w.close_top() and not menu.visible and chest.visible, "the popup first")
	check(w.close_top() and not chest.visible and things.visible, "then the window at a thing")
	check(w.close_top() and not things.visible, "then the work window")
	check(not w.close_top() and not w.any_open(), "then nothing: the game's menu may open")


func test_windows_stand_on_the_screen() -> void:
	w.top = 40
	w.bottom = 60
	var area := Vector2(960, 540)
	things.show()
	w.place(area)
	eq(things.position, Vector2(330, 40 + floorf((540 - 100 - 200) / 2.0)), "in the middle of the room between")
	things.hide()
	crafts.show()
	w.place(area)
	check(Rect2(Vector2.ZERO, area).encloses(Rect2(crafts.position, crafts.size)) or crafts.position.y == 0.0,
		"taller than the room: as high as it can stand, %s" % crafts.position)
	check(crafts.position.x >= 0.0 and crafts.position.x + crafts.size.x <= area.x, "never off the sides")
