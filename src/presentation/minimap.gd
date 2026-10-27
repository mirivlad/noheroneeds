class_name Minimap
extends Control
## The minimap in the corner (ADR-0020): what the character has seen around
## it, from one to four screens round (- and = change it), the player in the
## middle, other people seen as dots. It turns with the 3D camera (what is up on
## the screen is up on the map; north up in 2D), and the four sides of the world
## are marked round its edge (the author, 27.10.2026).

const SIZE := 72
## Half a screen across, in cells: one "screen" of radius.
const SCREEN_RADIUS := 15
var painter: MapPainter
var client: GameClient
## 1..4 screens round the player.
var screens := 2
## The camera's turn (WorldView3D.yaw; 0: north up).
var yaw := 0.0
var _ask_wait := 0.0
## The sides of the world: where each points (world axes) and its letter; north in red.
const SIDES := [[Vector2.UP, "С"], [Vector2.RIGHT, "В"], [Vector2.DOWN, "Ю"], [Vector2.LEFT, "З"]]


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
	# Turned round the player as the camera is: a world offset w shows at w.rotated(-yaw).
	draw_set_transform(mid, -yaw)
	painter.draw(self, client.location, me, Vector2.ZERO, px, Rect2(-size * 0.75, size * 1.5))
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") != "character" or int(e.get("z", client.z)) != client.z:
			continue
		var at := (Vector2(int(e["x"]), int(e["y"])) / Movement.UNIT - me) * px
		draw_rect(Rect2(at - Vector2.ONE, Vector2(2, 2)), Color(0.4, 0.8, 1.0))
	draw_set_transform(Vector2.ZERO)
	draw_rect(Rect2(mid - Vector2(1.5, 1.5), Vector2(3, 3)), Color(1.0, 0.9, 0.3))
	for side: Array in SIDES:
		var at := mid + (side[0] as Vector2).rotated(-yaw) * (size.x / 2.0 - 6.0)
		var c := Color(1.0, 0.35, 0.3) if side[1] == "С" else Color(0.9, 0.85, 0.75)
		draw_string_outline(Art.font(), at + Vector2(-3, 3), side[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 8, 3, Color(0.05, 0.04, 0.06))
		draw_string(Art.font(), at + Vector2(-3, 3), side[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 8, c)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.75, 0.68, 0.55, 0.9), false, 1.0)
	draw_string(Art.font(), Vector2(3, size.y - 3), "×%d" % screens, HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
		Color(0.9, 0.85, 0.75))
