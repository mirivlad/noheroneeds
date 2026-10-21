class_name WorldMap
extends Control
## The map of everything the character has seen (ADR-0020), over the whole
## screen (M): the surface and each depth below, a page each (PgUp/PgDn or
## Q/E), moved by dragging or WASD, scaled with the wheel.

var painter: MapPainter
var client: GameClient
## Locations with a page: the surface, then the depths, deepest last.
var pages: Array[String] = []
var page := 0
## The cell in the middle of the screen, and pixels a cell.
var centre := Vector2.ZERO
var zoom := 1.0
var _dragging := false
## Settlements near ({"name", "x", "y"} of their fires), as the server told:
## named on the surface's page where the character has seen them.
var places: Array = []
var _ask_wait := 0.0


func setup(map_painter: MapPainter, game_client: GameClient) -> void:
	painter = map_painter
	client = game_client
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


## Opens on the player's own place.
func open() -> void:
	_pages()
	page = maxi(0, pages.find(client.location))
	centre = Vector2(client.position) / Movement.UNIT if client.has_position else Vector2.ZERO
	zoom = 1.0
	visible = true
	_ask_wait = 0.0


func close() -> void:
	visible = false


func _pages() -> void:
	pages.clear()
	var depths: Array = []
	for loc: String in client.map_known:
		if loc == Levels.SURFACE:
			pages.append(loc)
		elif Levels.is_depth(loc):
			depths.append(loc)
	if not pages.has(Levels.SURFACE):
		pages.append(Levels.SURFACE)
	depths.sort_custom(func(a: String, b: String) -> bool:
		return int(client.map_known[a]["z"]) > int(client.map_known[b]["z"]))
	pages.append_array(depths)


func location() -> String:
	return pages[page] if page < pages.size() else Levels.SURFACE


static func title_of(location: String, z: int) -> String:
	if location == Levels.SURFACE:
		return "Поверхность"
	return "Глубина −%d" % -z if z < 0 else "Этаж +%d" % z


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_WHEEL_UP and b.pressed:
			zoom = minf(zoom * 1.25, 6.0)
		elif b.button_index == MOUSE_BUTTON_WHEEL_DOWN and b.pressed:
			zoom = maxf(zoom / 1.25, 0.1)
		elif b.button_index == MOUSE_BUTTON_LEFT:
			_dragging = b.pressed
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		centre -= (event as InputEventMouseMotion).relative / zoom
		accept_event()


## Keys while open (GameScreen passes them): pages, moving; true if used.
func key(k: int) -> bool:
	match k:
		KEY_PAGEUP, KEY_Q:
			page = maxi(0, page - 1)
		KEY_PAGEDOWN, KEY_E:
			page = mini(pages.size() - 1, page + 1)
		KEY_W, KEY_UP:
			centre.y -= 40.0 / zoom
		KEY_S, KEY_DOWN:
			centre.y += 40.0 / zoom
		KEY_A, KEY_LEFT:
			centre.x -= 40.0 / zoom
		KEY_D, KEY_RIGHT:
			centre.x += 40.0 / zoom
		KEY_EQUAL, KEY_KP_ADD:
			zoom = minf(zoom * 1.25, 6.0)
		KEY_MINUS, KEY_KP_SUBTRACT:
			zoom = maxf(zoom / 1.25, 0.1)
		_:
			return false
	return true


func _process(delta: float) -> void:
	if not visible:
		return
	_ask_wait -= delta
	if _ask_wait <= 0.0:
		_ask_wait = 0.5
		var r := int(maxf(size.x, size.y) / zoom)
		painter.ask_missing(location(), Vector2i(centre), r)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.045, 0.06, 0.96))
	var loc := location()
	painter.draw(self, loc, centre, size / 2.0, zoom, Rect2(Vector2.ZERO, size))
	if client.has_position and loc == client.location:
		var me := size / 2.0 + (Vector2(client.position) / Movement.UNIT - centre) * zoom
		draw_rect(Rect2(me - Vector2(2, 2), Vector2(4, 4)), Color(1.0, 0.9, 0.3))
	if loc == Levels.SURFACE:
		var seen: Dictionary = client.map_known.get(loc, {}).get("chunks", {})
		for p: Dictionary in places:
			var cell := Vector2i(int(p["x"]), int(p["y"]))
			if not seen.has(Vector2i(cell.x >> 5, cell.y >> 5)):
				continue
			var at := (size / 2.0 + (Vector2(cell) - centre) * zoom).round()
			draw_rect(Rect2(at - Vector2(3, 3), Vector2(6, 6)), Art.INK)
			draw_rect(Rect2(at - Vector2(2, 2), Vector2(4, 4)), Color(0.95, 0.6, 0.25))
			var name := String(p["name"])
			var pos := at + Vector2(-Art.font().get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x / 2.0, -6).round()
			draw_string_outline(Art.font(), pos, name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Art.INK)
			draw_string(Art.font(), pos, name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Art.TEXT_HOT)
	var z := int(client.map_known.get(loc, {}).get("z", 0))
	var head := "%s   (%d/%d)" % [title_of(loc, z), page + 1, pages.size()]
	draw_string(Art.font(), Vector2(8, 16), head, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Art.TEXT)
	draw_string(Art.font(), Vector2(8, size.y - 6),
		"PgUp/PgDn или Q/E — уровень   колесо, −/= — масштаб   мышь, WASD — двигать   M — закрыть",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Art.TEXT_DIM)
