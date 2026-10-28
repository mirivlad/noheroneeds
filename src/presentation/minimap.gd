class_name Minimap
extends Control
## The minimap in the corner (ADR-0020): what the character has seen around
## it, from one to four screens round (- and = change it), the player in the
## middle, other people seen as dots. It turns with the 3D camera (what is up on
## the screen is up on the map). Round, in a bronze ring, the four sides of the
## world as badges outside the ring, north red (the author, 27–28.10.2026).

## The control's size: the round map (MAP across) and the ring of the sides
## of the world round it (RIM wide each side).
const MAP := 88
const RIM := 16
const SIZE := MAP + 2 * RIM
## Half a screen across, in cells: one "screen" of radius.
const SCREEN_RADIUS := 15
var painter: MapPainter
var client: GameClient
## 1..4 screens round the player.
var screens := 2
## The camera's turn (WorldView3D.yaw; 0: north up).
var yaw := 0.0
var _ask_wait := 0.0
## The sides of the world: where each points (world axes) and its letter; north stands out.
const SIDES := [[Vector2.UP, "С"], [Vector2.RIGHT, "В"], [Vector2.DOWN, "Ю"], [Vector2.LEFT, "З"]]
const RING := Color("8a6a45")
const RING_HOT := Color("c8a060")
const NORTH := Color("c8503c")
## The round mask the map is drawn through, the map in it, and the ring over both.
var _disc := Control.new()
var _map := Control.new()
var _rim := Control.new()


func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Only what lies inside the disc is drawn of the map (the disc itself is not).
	_disc.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_disc.position = Vector2(RIM, RIM)
	_disc.size = Vector2(MAP, MAP)
	_map.size = Vector2(MAP, MAP)
	_rim.size = Vector2(SIZE, SIZE)
	for c: Control in [_disc, _map, _rim]:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disc.draw.connect(func() -> void: _disc.draw_circle(Vector2(MAP, MAP) / 2.0, MAP / 2.0, Color.WHITE))
	_map.draw.connect(_draw_map)
	_rim.draw.connect(_draw_rim)
	_disc.add_child(_map)
	add_child(_disc)
	add_child(_rim)


func setup(map_painter: MapPainter, game_client: GameClient) -> void:
	painter = map_painter
	client = game_client


func zoom(by: int) -> void:
	screens = clampi(screens + by, 1, 4)
	_map.queue_redraw()
	_rim.queue_redraw()


func radius() -> int:
	return screens * SCREEN_RADIUS


func _process(delta: float) -> void:
	if client == null or not client.has_position:
		return
	_ask_wait -= delta
	if _ask_wait <= 0.0:
		_ask_wait = 1.0
		painter.ask_missing(client.location, Movement.cell_of(client.position), radius())
	_map.queue_redraw()
	_rim.queue_redraw()


## The seen land round the player, turned as the camera is, people as dots.
func _draw_map() -> void:
	var c := _map
	var d := Vector2(MAP, MAP)
	c.draw_rect(Rect2(Vector2.ZERO, d), Color(0.06, 0.05, 0.07, 0.9))
	if client == null or not client.has_position:
		return
	var me := Vector2(client.position) / Movement.UNIT
	var px := MAP / (2.0 * radius())
	var mid := d / 2.0
	# Turned round the player as the camera is: a world offset w shows at w.rotated(-yaw).
	c.draw_set_transform(mid, -yaw)
	painter.draw(c, client.location, me, Vector2.ZERO, px, Rect2(-d * 0.75, d * 1.5))
	for id: String in client.entities:
		var e: Dictionary = client.entities[id]
		if e.get("kind") != "character" or int(e.get("z", client.z)) != client.z:
			continue
		var at := (Vector2(int(e["x"]), int(e["y"])) / Movement.UNIT - me) * px
		c.draw_rect(Rect2(at - Vector2.ONE, Vector2(2, 2)), Color(0.4, 0.8, 1.0))
	c.draw_set_transform(Vector2.ZERO)
	c.draw_rect(Rect2(mid - Vector2(1.5, 1.5), Vector2(3, 3)), Color(1.0, 0.9, 0.3))


## The ring round the map, a notch at each side between, and the sides of the
## world on the ring's outer side: a small bronze badge each, north red with
## a point toward the edge. "×N" (how far it shows) at the lower left.
func _draw_rim() -> void:
	var c := _rim
	var mid := Vector2(SIZE, SIZE) / 2.0
	var r := MAP / 2.0
	c.draw_arc(mid, r + 1.0, 0.0, TAU, 64, Art.INK, 3.0)
	c.draw_arc(mid, r + 1.0, 0.0, TAU, 64, RING, 1.0)
	for i in 4:  # notches between the sides
		var dir := Vector2.UP.rotated(-yaw + PI / 4.0 + i * PI / 2.0)
		c.draw_line(mid + dir * (r - 1.0), mid + dir * (r + 3.0), RING, 1.0)
	for side: Array in SIDES:
		var dir := (side[0] as Vector2).rotated(-yaw)
		var north: bool = side[1] == "С"
		var at := (mid + dir * (r + 8.0)).round()
		if north:  # a point from the badge toward the edge
			var tip := mid + dir * (r + 1.0)
			var across := dir.orthogonal() * 3.0
			c.draw_colored_polygon(PackedVector2Array([tip, at - dir * 2.0 + across, at - dir * 2.0 - across]), NORTH)
		c.draw_circle(at, 7.0, Art.INK)
		c.draw_circle(at, 6.0, NORTH if north else Color("2c2230"))
		c.draw_arc(at, 6.5, 0.0, TAU, 16, RING_HOT if north else RING, 1.0)
		var letter := String(side[1])
		var w := Art.font().get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		c.draw_string(Art.font(), at + Vector2(-floorf(w / 2.0), 4), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
			Color("fff2d0") if north else Art.TEXT)
	c.draw_string_outline(Art.font(), Vector2(1, SIZE - 2), "×%d" % screens, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 3, Art.INK)
	c.draw_string(Art.font(), Vector2(1, SIZE - 2), "×%d" % screens, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Art.TEXT_DIM)
