class_name MapPainter
extends RefCounted
## Pictures of map tiles (ADR-0020) for the minimap and the world map: each
## content id gets the average colour of its own picture (so new content
## comes onto the map without a list of colours), each tile a 32 x 32 texture
## with a pixel a cell; unseen cells are left clear.

var content: ContentRegistry
var view: WorldView
var client: GameClient
## content id -> Color
var _colors := {}
## "location|cx|cy" -> ImageTexture
var _textures := {}


func setup(registry: ContentRegistry, world_view: WorldView, game_client: GameClient) -> void:
	content = registry
	view = world_view
	client = game_client


## The texture of a seen chunk, or null if its tile has not come yet.
func texture(location: String, at: Vector2i) -> Texture2D:
	var key := "%s|%d|%d" % [location, at.x, at.y]
	var t: ImageTexture = _textures.get(key)
	if t:
		return t
	var tile: Dictionary = client.map_tiles.get(key, {})
	if tile.is_empty():
		return null
	t = ImageTexture.create_from_image(image_of(tile))
	_textures[key] = t
	return t


## Forgets pictures of tiles that changed (the client says which).
func refresh() -> void:
	for key: String in client.map_changed:
		_textures.erase(key)
		_marks.erase(key)
	client.map_changed.clear()


func image_of(tile: Dictionary) -> Image:
	var img := Image.create(Chunk.SIZE, Chunk.SIZE, false, Image.FORMAT_RGBA8)
	var palette: PackedStringArray = tile["palette"]
	var colors: Array[Color] = []
	for id in palette:
		colors.append(color_of(id))
	var cells: PackedByteArray = tile["cells"]
	for i in Chunk.CELLS:
		img.set_pixel(i % Chunk.SIZE, i / Chunk.SIZE, colors[cells[i]])
	return img


## Ways up and down in a seen chunk (stairs, shafts, cave mouths and
## climbs: parts whose role is "stairs" or "shaft"): [[local cell, up?]].
func marks(location: String, at: Vector2i) -> Array:
	var key := "%s|%d|%d" % [location, at.x, at.y]
	if _marks.has(key) and _textures.has(key):
		return _marks[key]
	var out := []
	var tile: Dictionary = client.map_tiles.get(key, {})
	if not tile.is_empty():
		var palette: PackedStringArray = tile["palette"]
		var ways := {}
		for k in palette.size():
			var d := content.get_def(palette[k])
			if d.get("role") in ["stairs", "shaft"]:
				ways[k] = d.get("role") == "stairs" or String(d.get("leads", "down")) == "up"
		if not ways.is_empty():
			var cells: PackedByteArray = tile["cells"]
			for i in Chunk.CELLS:
				if ways.has(int(cells[i])):
					out.append([Vector2i(i % Chunk.SIZE, i / Chunk.SIZE), ways[int(cells[i])]])
	_marks[key] = out
	return out


## A way on the map: a triangle up or down, the same size at any zoom.
static func draw_way(canvas: CanvasItem, p: Vector2, up: bool) -> void:
	var r := 4.0
	var pts := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, r * 0.8), p + Vector2(-r, r * 0.8)]) if up \
		else PackedVector2Array([p + Vector2(0, r), p + Vector2(r, -r * 0.8), p + Vector2(-r, -r * 0.8)])
	var ring := PackedVector2Array(pts)
	ring.append(pts[0])
	canvas.draw_colored_polygon(pts, WAY_UP if up else WAY_DOWN)
	canvas.draw_polyline(ring, Color(0.05, 0.04, 0.06), 1.0)


const WAY_UP := Color(0.98, 0.9, 0.45)
const WAY_DOWN := Color(0.95, 0.5, 0.3)
## "location|cx|cy" -> [[local cell, up?]] (with the texture: forgotten with it)
var _marks := {}


## A content id's colour on the map: the mean of its picture's opaque pixels.
func color_of(id: String) -> Color:
	if id == "":
		return Color(0, 0, 0, 0)
	if _colors.has(id):
		return _colors[id]
	var c := Color(0.5, 0.5, 0.5)
	var v := content.visual_of(id)
	if not v.is_empty():
		var tex := view.texture(String(v["atlas_path"]))
		var img := tex.get_image() if tex else null
		if img:
			if img.is_compressed():
				img.decompress()
			var r: Array = v["rect"]
			var sum := Vector3.ZERO
			var n := 0
			for y in range(int(r[1]), int(r[1]) + int(r[3]), 2):
				for x in range(int(r[0]), int(r[0]) + int(r[2]), 2):
					if x >= img.get_width() or y >= img.get_height():
						continue
					var p := img.get_pixel(x, y)
					if p.a > 0.5:
						sum += Vector3(p.r, p.g, p.b)
						n += 1
			if n > 0:
				c = Color(sum.x / n, sum.y / n, sum.z / n)
	_colors[id] = c
	return c


## The seen chunks of a location within `radius` cells of `centre` that have
## no tile yet: asked from the server (it sends only seen ones).
func ask_missing(location: String, centre: Vector2i, radius: int) -> void:
	var known: Dictionary = client.map_known.get(location, {})
	if known.is_empty():
		return
	var lo := Vector2i(floori(float(centre.x - radius) / Chunk.SIZE), floori(float(centre.y - radius) / Chunk.SIZE))
	var hi := Vector2i(floori(float(centre.x + radius) / Chunk.SIZE), floori(float(centre.y + radius) / Chunk.SIZE))
	var want := []
	for at: Vector2i in known["chunks"]:
		if at.x >= lo.x and at.x <= hi.x and at.y >= lo.y and at.y <= hi.y \
				and not client.map_tiles.has("%s|%d|%d" % [location, at.x, at.y]):
			want.append(at)
	if not want.is_empty():
		client.request_map(location, want)


## Draws the seen tiles of `location` onto `canvas` (a Control's _draw):
## the cell `centre` at `origin`, `scale` pixels a cell, within `rect`.
func draw(canvas: CanvasItem, location: String, centre: Vector2, origin: Vector2, scale: float, rect: Rect2) -> void:
	var known: Dictionary = client.map_known.get(location, {})
	if known.is_empty():
		return
	var half := rect.size / 2.0 / scale
	var lo := Vector2i(floori((centre.x - half.x) / Chunk.SIZE) - 1, floori((centre.y - half.y) / Chunk.SIZE) - 1)
	var hi := Vector2i(floori((centre.x + half.x) / Chunk.SIZE) + 1, floori((centre.y + half.y) / Chunk.SIZE) + 1)
	var chunks: Dictionary = known["chunks"]
	var ways := []
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			if not chunks.has(Vector2i(cx, cy)):
				continue
			var t := texture(location, Vector2i(cx, cy))
			if t == null:
				continue
			var at := origin + (Vector2(cx * Chunk.SIZE, cy * Chunk.SIZE) - centre) * scale
			canvas.draw_texture_rect(t, Rect2(at, Vector2.ONE * Chunk.SIZE * scale), false)
			for m: Array in marks(location, Vector2i(cx, cy)):
				var p: Vector2 = at + (Vector2(m[0]) + Vector2(0.5, 0.5)) * scale
				if rect.has_point(p):
					ways.append([p, bool(m[1])])
	for w: Array in ways:  # over every tile, not under the next one
		draw_way(canvas, w[0], w[1])
