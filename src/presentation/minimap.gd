class_name Minimap
extends Control
## The minimap in the corner (ADR-0020): what the character has seen around
## it, from one to four screens round (- and = change it), north up, the
## player in the middle, other people seen as dots.

const SIZE := 72
## Half a screen across, in cells: one "screen" of radius.
const SCREEN_RADIUS := 15
var painter: MapPainter
var client: GameClient
## 1..4 screens round the player.
var screens := 2
var _ask_wait := 0.0


func setup(map_painter: MapPainter, game_client: GameClient) -> void:
	painter = map_painter
	client = game_client
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func zoom(by: int) -> void:
	screens = clampi(screens + by, 1, 4)
	queue_redraw()


func radius() -> int:
	return screens * SCREEN_RADIUS


func _process(delta: float) -> void:
	if client == null or not client.has_position:
		return
	_ask_wait -= delta
	if _ask_wait <= 0.0:
		_ask_wait = 1.0
		painter.ask_missing(client.location, Movement.cell_of(client.position), radius())
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.05, 0.07, 0.85))
	if client == null or not client.has_position:
		return
	var me := Vector2(client.position) / Movement.UNIT
	var px := size.x / (2.0 * radius())
	var mid := size / 2.0
	painter.draw(self, client.location, me, mid, px, Rect2(Vector2.ZERO, size))
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") != "character" or int(e.get("z", client.z)) != client.z:
			continue
		var at := mid + (Vector2(int(e["x"]), int(e["y"])) / Movement.UNIT - me) * px
		draw_rect(Rect2(at - Vector2.ONE, Vector2(2, 2)), Color(0.4, 0.8, 1.0))
	draw_rect(Rect2(mid - Vector2(1.5, 1.5), Vector2(3, 3)), Color(1.0, 0.9, 0.3))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.75, 0.68, 0.55, 0.9), false, 1.0)
	draw_string(Art.font(), Vector2(3, size.y - 3), "×%d" % screens, HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
		Color(0.9, 0.85, 0.75))
